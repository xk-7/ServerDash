import Darwin
import Foundation

struct HTTPProxyRequest: Equatable {
    var host: String
    var port: Int
    var tunnel: Bool
    var forwardedHeader: Data
    static func parse(_ data: Data) throws -> Self {
        guard data.count <= 32768, let text = String(data: data, encoding: .utf8), text.hasSuffix("\r\n\r\n") else {
            throw WorkbenchConnectionError.unavailable("HTTP 代理请求头无效。")
        }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        guard first.count == 3, first[2] == "HTTP/1.1" || first[2] == "HTTP/1.0",
              !lines[0].unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              first[0].allSatisfy({ $0.isASCII && $0.isLetter }) else { throw WorkbenchConnectionError.unavailable("HTTP 代理请求行无效。") }
        let tunnel = first[0] == "CONNECT"
        guard let parts = URLComponents(string: tunnel ? "http://\(first[1])" : String(first[1])),
              let rawHost = parts.host, !rawHost.isEmpty, parts.user == nil, parts.password == nil,
              parts.fragment == nil, parts.scheme == "http",
              !tunnel || (parts.path.isEmpty && parts.query == nil && parts.port != nil) else {
            throw WorkbenchConnectionError.unavailable("HTTP 代理仅接受 HTTP 绝对地址或 CONNECT 主机端口。")
        }
        let host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]") ? String(rawHost.dropFirst().dropLast()) : rawHost
        let port = parts.port ?? 80
        guard (1...65535).contains(port), host.utf8.count <= 253,
              !host.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespaces.contains($0) }) else {
            throw WorkbenchConnectionError.invalidHost
        }
        if tunnel { return .init(host: host, port: port, tunnel: true, forwardedHeader: Data()) }
        let path = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
        let target = path + (parts.percentEncodedQuery.map { "?\($0)" } ?? "")
        var headers: [String] = ["\(first[0]) \(target) \(first[2])"]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t"),
                  !line.contains("\r"), !line.contains("\n") else { throw WorkbenchConnectionError.unavailable("不支持折叠 HTTP 请求头。") }
            let key = line[..<colon].lowercased()
            guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "!#$%&'*+-.^_`|~".contains($0)) }) else {
                throw WorkbenchConnectionError.unavailable("HTTP 请求头名称无效。")
            }
            if key != "proxy-authorization", key != "proxy-connection", key != "connection", key != "host" { headers.append(line) }
        }
        let authority = (host.contains(":") ? "[\(host)]" : host) + (port == 80 ? "" : ":\(port)")
        headers.append("Host: \(authority)")
        // A plain HTTP connection serves one origin, preventing cross-origin absolute-URI reuse.
        headers.append("Connection: close")
        return .init(host: host, port: port, tunnel: false, forwardedHeader: Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8))
    }
}

/// A bounded local HTTP/CONNECT listener. Every outbound stream must negotiate through the app's SSH SOCKS listener.
final class HTTPToSOCKSProxy: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.serverdash.http-proxy.accept")
    private var listener: DispatchSourceRead?
    private var stopped = false
    private var clients: [UUID: [Int32]] = [:]
    private let socksPort: Int
    init(socksPort: Int) { self.socksPort = socksPort }

    func start(bindAddress: String, port: Int) throws {
        let fd = try Self.listeningSocket(address: bindAddress, port: port)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setCancelHandler { Darwin.close(fd) }
        source.setEventHandler { [weak self] in self?.acceptClients(fd) }
        lock.lock(); stopped = false; listener = source; lock.unlock(); source.resume()
    }
    func stop() {
        lock.lock(); stopped = true; let source = listener; listener = nil; let sockets = clients.values.flatMap { $0 }
        for fd in sockets { _ = Darwin.shutdown(fd, SHUT_RDWR) }
        lock.unlock(); source?.cancel()
    }
    deinit { stop() }

    static func availableLoopbackPort() throws -> Int {
        let fd = try listeningSocket(address: "127.0.0.1", port: 0); defer { Darwin.close(fd) }
        var address = sockaddr_in(); var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        guard result == 0 else { throw failure() }; return Int(UInt16(bigEndian: address.sin_port))
    }
    private static func listeningSocket(address: String, port: Int) throws -> Int32 {
        var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_flags = AI_PASSIVE | AI_NUMERICHOST
        var info: UnsafeMutablePointer<addrinfo>?
        let host = address == "*" ? "0.0.0.0" : address.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let entry = info else { throw WorkbenchConnectionError.invalidHost }
        defer { freeaddrinfo(entry) }
        let fd = socket(entry.pointee.ai_family, SOCK_STREAM, 0)
        guard fd >= 0 else { throw failure() }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        guard Darwin.bind(fd, entry.pointee.ai_addr, entry.pointee.ai_addrlen) == 0, listen(fd, 32) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { Darwin.close(fd); throw failure() }
        return fd
    }
    private func acceptClients(_ listenerFD: Int32) {
        while true {
            let fd = accept(listenerFD, nil, nil)
            if fd < 0 { return }
            let id = UUID()
            lock.lock(); let allowed = !stopped && clients.count < 32; if allowed { clients[id] = [fd] }; lock.unlock()
            guard allowed else { Darwin.close(fd); continue }
            Self.configure(fd)
            DispatchQueue.global(qos: .utility).async { [self] in serve(id: id, client: fd) }
        }
    }
    private func serve(id: UUID, client: Int32) {
        defer {
            lock.lock(); let sockets = clients.removeValue(forKey: id) ?? [client]; lock.unlock()
            for fd in sockets { Darwin.close(fd) }
        }
        var accepted = false
        do {
            var header = Data(); var trailing = Data(); let end = Data([13, 10, 13, 10])
            while true {
                let bytes = try Self.readSome(client)
                guard !bytes.isEmpty else { return }; header.append(bytes)
                if let range = header.range(of: end) { trailing = header.subdata(in: range.upperBound..<header.count); header = header.subdata(in: 0..<range.upperBound); break }
                guard header.count <= 32768 else { throw WorkbenchConnectionError.unavailable("请求头过长。") }
            }
            let request = try HTTPProxyRequest.parse(header)
            let backend = socket(AF_INET, SOCK_STREAM, 0); guard backend >= 0 else { throw Self.failure() }
            lock.lock(); let active = !stopped && clients[id] != nil
            if active { clients[id]?.append(backend) }; lock.unlock()
            guard active else { Darwin.close(backend); return }
            Self.configure(backend)
            var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(socksPort).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(backend, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard result == 0 else { throw Self.failure() }
            try Self.negotiate(backend, host: request.host, port: request.port)
            if request.tunnel { try Self.writeAll(client, Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)) }
            else { try Self.writeAll(backend, request.forwardedHeader) }
            accepted = true
            if !trailing.isEmpty { try Self.writeAll(backend, trailing) }
            try relay(client: client, backend: backend)
        } catch {
            if !accepted { try? Self.writeAll(client, Data("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8)) }
        }
    }
    private func relay(client: Int32, backend: Int32) throws {
        var descriptors = [pollfd(fd: client, events: Int16(POLLIN), revents: 0), pollfd(fd: backend, events: Int16(POLLIN), revents: 0)]
        while true {
            lock.lock(); let cancelled = stopped; lock.unlock(); if cancelled { return }
            let count = poll(&descriptors, 2, 250)
            if count < 0 { if errno == EINTR { continue }; throw Self.failure() }
            for index in 0..<2 {
                let flags = descriptors[index].revents
                if flags & Int16(POLLIN) != 0 {
                    let bytes = try Self.readSome(descriptors[index].fd); if bytes.isEmpty { return }
                    try Self.writeAll(descriptors[1 - index].fd, bytes)
                } else if flags & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { return }
            }
        }
    }
    private static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, 0)
        var timeout = timeval(tv_sec: 30, tv_usec: 0); var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }
    private static func negotiate(_ fd: Int32, host: String, port: Int) throws {
        try writeAll(fd, Data([5, 1, 0]))
        guard try readExactly(fd, count: 2) == Data([5, 0]) else { throw failure() }
        var request = Data([5, 1, 0]); var address6 = in6_addr()
        if inet_pton(AF_INET6, host, &address6) == 1 { request.append(4); withUnsafeBytes(of: &address6) { request.append(contentsOf: $0) } }
        else { let name = Data(host.utf8); guard name.count <= 255 else { throw failure() }; request.append(3); request.append(UInt8(name.count)); request.append(name) }
        request.append(UInt8(port >> 8)); request.append(UInt8(port & 255)); try writeAll(fd, request)
        let reply = try readExactly(fd, count: 4)
        guard reply[0] == 5, reply[1] == 0 else { throw failure() }
        switch reply[3] {
        case 1: _ = try readExactly(fd, count: 6)
        case 4: _ = try readExactly(fd, count: 18)
        case 3: let length = try readExactly(fd, count: 1)[0]; _ = try readExactly(fd, count: Int(length) + 2)
        default: throw failure()
        }
    }
    private static func readExactly(_ fd: Int32, count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count); var offset = 0
        while offset < count {
            let received = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: offset), count - offset) }
            if received < 0, errno == EINTR { continue }; guard received > 0 else { throw failure() }; offset += received
        }
        return Data(bytes)
    }
    private static func readSome(_ fd: Int32) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }; guard count >= 0 else { throw failure() }; return Data(bytes.prefix(count))
        }
    }
    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count < 0, errno == EINTR { continue }; guard count > 0 else { throw failure() }; offset += count
        }
    }
    private static func failure() -> WorkbenchConnectionError { .unavailable("HTTP 代理连接失败。") }
}
