import AppKit
import Darwin
import Foundation
import IOKit
import IOKit.serial
import SwiftData
import SwiftTerm
import SwiftUI

struct SerialDevice: Identifiable, Equatable {
    let path: String
    let name: String
    var id: String { path }
}

enum SerialDeviceDiscovery {
    static func devices() -> [SerialDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOSerialBSDServiceValue), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [SerialDevice] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let path = IORegistryEntryCreateCFProperty(service, kIOCalloutDeviceKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                result.append(.init(path: path, name: URL(fileURLWithPath: path).lastPathComponent))
            }
            IOObjectRelease(service); service = IOIteratorNext(iterator)
        }
        return result.sorted { $0.path < $1.path }
    }
}

/// All descriptor ownership and nonblocking IO lives on one queue. Closing cancels both IO and queued output.
final class SerialPortTransport: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.serverdash.serial.io", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    private var descriptor: Int32 = -1
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var descriptorLease: SerialDescriptorLease?
    private var pending = Data()
    private var output: (@Sendable (Data) -> Void)?
    private var ended: (@Sendable (String?) -> Void)?
    init() { queue.setSpecific(key: queueKey, value: true) }

    func open(_ configuration: SerialPortConfiguration, output: @escaping @Sendable (Data) -> Void,
              ended: @escaping @Sendable (String?) -> Void) throws {
        try configuration.validate()
        try queue.sync {
            guard descriptor < 0, descriptorLease?.isClosed != false else { throw WorkbenchConnectionError.unavailable("串口已打开或仍在关闭。") }
            let fd = Darwin.open(configuration.devicePath, O_RDWR | O_NOCTTY | O_NONBLOCK)
            guard fd >= 0 else { throw posixError("无法打开串口") }
            var previous = termios()
            guard tcgetattr(fd, &previous) == 0 else { Darwin.close(fd); throw posixError("无法读取串口参数") }
            do {
                guard ioctl(fd, TIOCEXCL) == 0 else { throw posixError("串口正被其他程序使用") }
                var settings = previous
                cfmakeraw(&settings)
                settings.c_cflag &= ~tcflag_t(CSIZE | PARENB | PARODD | CSTOPB | CRTSCTS)
                settings.c_cflag |= tcflag_t(CLOCAL | CREAD)
                switch configuration.dataBits {
                case 5: settings.c_cflag |= tcflag_t(CS5)
                case 6: settings.c_cflag |= tcflag_t(CS6)
                case 7: settings.c_cflag |= tcflag_t(CS7)
                default: settings.c_cflag |= tcflag_t(CS8)
                }
                if configuration.parity != .none { settings.c_cflag |= tcflag_t(PARENB) }
                if configuration.parity == .odd { settings.c_cflag |= tcflag_t(PARODD) }
                if configuration.stopBits == 2 { settings.c_cflag |= tcflag_t(CSTOPB) }
                settings.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
                if configuration.flowControl == .hardware { settings.c_cflag |= tcflag_t(CRTSCTS) }
                if configuration.flowControl == .software { settings.c_iflag |= tcflag_t(IXON | IXOFF) }
                withUnsafeMutableBytes(of: &settings.c_cc) { bytes in bytes[Int(VMIN)] = 1; bytes[Int(VTIME)] = 0 }
                let speed = speed_t(min(configuration.baudRate, 230400))
                cfsetispeed(&settings, speed); cfsetospeed(&settings, speed)
                guard tcsetattr(fd, TCSANOW, &settings) == 0 else { throw posixError("无法设置串口参数") }
                if configuration.baudRate > 230400 {
                    var customSpeed = speed_t(configuration.baudRate)
                    // IOSSIOSPEED is defined by the macOS serial driver ABI (_IOW('T', 2, speed_t)).
                    guard ioctl(fd, UInt(0x80085402), &customSpeed) == 0 else { throw posixError("设备不支持此波特率") }
                }
                descriptor = fd; self.output = output; self.ended = ended
                let lease = SerialDescriptorLease(descriptor: fd, original: previous)
                descriptorLease = lease
                let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                readSource.setEventHandler { [weak self] in self?.readAvailable() }
                readSource.setCancelHandler { lease.releaseSource() }
                reader = readSource; readSource.resume()
            } catch {
                _ = tcsetattr(fd, TCSANOW, &previous); Darwin.close(fd); throw error
            }
        }
    }

    func write(_ data: Data) {
        queue.async { [weak self] in
            guard let self, self.descriptor >= 0 else { return }
            guard self.pending.count + data.count <= 1024 * 1024 else { self.finish("串口发送队列已满。请等待设备接收后重新连接。"); return }
            self.pending.append(data); self.flush()
        }
    }

    func close() {
        if DispatchQueue.getSpecific(key: queueKey) == true { finish(nil); return }
        let lease = queue.sync { finish(nil); return descriptorLease }
        lease?.waitUntilClosed()
    }
    deinit { reader?.cancel(); writer?.cancel() }

    private func readAvailable() {
        guard descriptor >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 16384)
        while descriptor >= 0 {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 { output?(Data(buffer.prefix(count))) }
            else if count == 0 { finish("串口设备已断开。"); return }
            else if errno == EAGAIN || errno == EWOULDBLOCK { return }
            else if errno != EINTR { finish(posixError("串口读取失败").localizedDescription); return }
        }
    }

    private func flush() {
        guard descriptor >= 0 else { return }
        while !pending.isEmpty {
            let count = pending.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if count > 0 { pending.removeFirst(count) }
            else if count < 0, errno == EINTR { continue }
            else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                if writer == nil {
                    guard let lease = descriptorLease else { finish("串口已断开。"); return }
                    lease.retainSource()
                    let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
                    source.setEventHandler { [weak self] in self?.flush() }
                    source.setCancelHandler { lease.releaseSource() }
                    writer = source; source.resume()
                }
                return
            } else { finish(posixError("串口写入失败").localizedDescription); return }
        }
        writer?.cancel(); writer = nil
    }

    private func finish(_ message: String?) {
        guard descriptor >= 0 else { return }
        descriptor = -1; writer?.cancel(); writer = nil; reader?.cancel(); reader = nil
        pending.removeAll(); output = nil; let callback = ended; ended = nil; callback?(message)
    }
    private func posixError(_ prefix: String) -> WorkbenchConnectionError {
        .unavailable("\(prefix)：\(String(cString: strerror(errno)))")
    }
}

/// The FD closes only after every dispatch source has removed its kernel event registration.
private final class SerialDescriptorLease: @unchecked Sendable {
    private let lock = NSLock()
    private let completion = DispatchGroup()
    private let descriptor: Int32
    private var original: termios
    private var references = 1
    private var closed = false
    init(descriptor: Int32, original: termios) {
        self.descriptor = descriptor; self.original = original; completion.enter()
    }
    var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
    func retainSource() { lock.lock(); references += 1; lock.unlock() }
    func releaseSource() {
        lock.lock(); references -= 1
        guard references == 0, !closed else { lock.unlock(); return }
        _ = tcsetattr(descriptor, TCSANOW, &original)
        _ = ioctl(descriptor, TIOCNXCL)
        Darwin.close(descriptor); closed = true; lock.unlock(); completion.leave()
    }
    func waitUntilClosed() { completion.wait() }
}

struct LocalShellConfiguration: Equatable, Sendable {
    var executable: String
    var arguments: [String] = ["-l"]
    var environment: [String: String]
    var workingDirectory: String
    static func current(defaults: UserDefaults = .standard) -> Self {
        let inherited = ProcessInfo.processInfo.environment
        let storedPath = defaults.string(forKey: "workbench.localShellPath")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let loginShell = getpwuid(getuid()).flatMap { entry in
            entry.pointee.pw_shell.map { String(cString: $0) }
        }.flatMap { $0.isEmpty ? nil : $0 }
        let path = storedPath.isEmpty ? (loginShell ?? inherited["SHELL"] ?? "/bin/zsh") : storedPath
        let clean = defaults.string(forKey: "workbench.localShellEnvironment") == "clean"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var environment = clean ? ["HOME": home, "USER": NSUserName(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"] : inherited
        environment["SHELL"] = path
        environment["TERM"] = "xterm-256color"; environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        let arguments: [String]
        if clean {
            switch URL(fileURLWithPath: path).lastPathComponent {
            case "zsh": arguments = ["-f"]
            case "bash": arguments = ["--noprofile", "--norc"]
            case "fish": arguments = ["--no-config"]
            default: arguments = []
            }
        } else { arguments = ["-l"] }
        return .init(executable: path, arguments: arguments, environment: environment, workingDirectory: home)
    }
    func validate() throws {
        guard executable.hasPrefix("/"), !executable.contains("\0"),
              FileManager.default.isExecutableFile(atPath: executable) else { throw WorkbenchConnectionError.invalidShell }
    }
}

private final class WorkbenchTerminalView: LocalProcessTerminalView {
    var serialSend: ((Data) -> Void)?
    var ended: ((Int32?) -> Void)?
    override func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        if let serialSend { serialSend(Data(data)) } else { super.send(source: source, data: data) }
    }
    override func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        guard source === process else { return }; super.processTerminated(source, exitCode: exitCode); ended?(exitCode)
    }
}

@MainActor final class WorkbenchSessionController: ObservableObject, Identifiable {
    let id = UUID()
    let recordID: UUID
    let name: String
    let kind: WorkspaceTabKind
    let hostView: NSView
    @Published private(set) var status: TerminalConnectionStatus = .disconnected
    @Published private(set) var lastError: String?
    private let terminal: WorkbenchTerminalView
    private let serialConfigurationProvider: (() throws -> SerialPortConfiguration)?
    private let localConfiguration: LocalShellConfiguration?
    private var transport: SerialPortTransport?
    private var generation = UUID()
    init(record: SerialConnectionRecord) {
        recordID = record.id; name = record.displayName; kind = .serial
        let container = record.modelContext?.container
        let machineID = record.id
        let initialConfiguration = record.configuration
        serialConfigurationProvider = {
            guard let container else { return initialConfiguration }
            let reader = ModelContext(container)
            guard let latest = try reader.fetch(FetchDescriptor<SerialConnectionRecord>(predicate: #Predicate { $0.id == machineID })).first else {
                throw WorkbenchConnectionError.unavailable("串口配置已删除，无法重新连接。")
            }
            return latest.configuration
        }
        localConfiguration = nil
        terminal = WorkbenchTerminalView(frame: .zero); hostView = terminal; configureAppearance()
    }
    init(local: LocalShellConfiguration = .current()) {
        recordID = UUID(); name = "本地终端"; kind = .local
        serialConfigurationProvider = nil; localConfiguration = local
        terminal = WorkbenchTerminalView(frame: .zero); hostView = terminal; configureAppearance()
    }
    func reconnect() {
        close(); status = .connecting; lastError = nil; let current = UUID(); generation = current
        do {
            if let serialConfigurationProvider {
                let configuration = try serialConfigurationProvider()
                let port = SerialPortTransport()
                terminal.serialSend = { [weak port] in port?.write($0) }
                try port.open(configuration, output: { [weak self] bytes in
                    Task { @MainActor in guard let self, self.generation == current else { return }; self.terminal.feed(byteArray: Array(bytes)[...]) }
                }, ended: { [weak self] error in
                    Task { @MainActor in guard let self, self.generation == current else { return }; self.lastError = error; self.status = error == nil ? .disconnected : .failed }
                })
                transport = port
            } else if let local = localConfiguration {
                try local.validate()
                terminal.ended = { [weak self] code in
                    guard let self, self.generation == current else { return }
                    self.status = code == 0 ? .disconnected : .failed
                    self.lastError = code == 0 ? nil : "本地 Shell 已结束（\(code ?? -1)）。"
                }
                terminal.startProcess(executable: local.executable, args: local.arguments,
                    environment: local.environment.map { "\($0.key)=\($0.value)" }, execName: URL(fileURLWithPath: local.executable).lastPathComponent,
                    currentDirectory: local.workingDirectory)
                guard terminal.process.running else { throw WorkbenchConnectionError.unavailable("本地 Shell 未能启动。") }
            }
            status = .connected
        } catch { lastError = error.localizedDescription; status = .failed }
    }
    func close() {
        generation = UUID(); transport?.close(); transport = nil; terminal.serialSend = nil
        if terminal.process.running { terminal.replaceProcess() }
        status = .disconnected
    }
    func focus() { guard let window = terminal.window, window.isKeyWindow, window.attachedSheet == nil else { return }; window.makeFirstResponder(terminal) }
    private func configureAppearance() {
        let profile = TerminalAppearanceStore.shared.profile.validated()
        terminal.font = TerminalFontCatalog.font(name: profile.fontPostScriptName, size: profile.fontSize)
        terminal.lineHeightMultiplier = profile.lineHeight; terminal.characterSpacing = profile.letterSpacing
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let theme = TerminalAppearanceStore.shared.theme(dark: dark)
        terminal.nativeBackgroundColor = theme.background.nsColor; terminal.nativeForegroundColor = theme.foreground.nsColor
        terminal.caretColor = theme.cursor.nsColor
    }
}

@MainActor final class WorkbenchSessionRegistry: ObservableObject {
    @Published private(set) var controllers: [UUID: WorkbenchSessionController] = [:]
    func controller(for id: UUID) -> WorkbenchSessionController? { controllers[id] }
    func open(_ controller: WorkbenchSessionController, workspace: TerminalWorkspace) {
        controllers[controller.id] = controller
        workspace.add(sessionID: controller.id, serverID: controller.recordID, title: controller.name, kind: controller.kind)
        controller.reconnect()
    }
    func close(_ id: UUID) { controllers.removeValue(forKey: id)?.close() }
    func closeAll() { controllers.values.forEach { $0.close() }; controllers.removeAll() }
}

@MainActor enum WorkbenchConnectionLauncher {
    static func openVNC(_ record: VNCConnectionRecord) async throws {
        let url = try record.connectionURL()
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ScreenSharing") else { throw WorkbenchConnectionError.unavailable("未找到系统屏幕共享应用。") }
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init())
        record.lastLaunchedAt = .now
        try record.modelContext?.save()
    }
    static func openSerial(_ record: SerialConnectionRecord, appState: AppState, reconnect: Bool = false) throws {
        try record.configuration.validate()
        if let tab = appState.terminalRegistry.workspace.tabs.reversed().first(where: { $0.kind == .serial && $0.serverID == record.id }),
           let existing = appState.workbenchSessions.controller(for: tab.activePane) {
            if reconnect || existing.status != .connected {
                existing.reconnect()
                if existing.status == .connected { record.lastConnectedAt = .now; try record.modelContext?.save() }
            }
            appState.terminalRegistry.workspace.select(pane: existing.id); appState.route = .section(.terminal); return
        }
        let controller = WorkbenchSessionController(record: record)
        appState.workbenchSessions.open(controller, workspace: appState.terminalRegistry.workspace)
        appState.route = .section(.terminal)
        if controller.status == .connected { record.lastConnectedAt = .now; try record.modelContext?.save() }
    }
    static func openLocal(appState: AppState) throws {
        let config = LocalShellConfiguration.current(); try config.validate()
        appState.workbenchSessions.open(.init(local: config), workspace: appState.terminalRegistry.workspace)
        appState.route = .section(.terminal)
    }
}

struct WorkbenchSessionPane: View {
    @ObservedObject var controller: WorkbenchSessionController
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(controller.name, systemImage: controller.kind.icon)
                Spacer(); Text(controller.status.title).foregroundStyle(.secondary)
                if controller.status != .connected { Button("重新连接") { controller.reconnect() } }
            }.padding(10).background(.bar)
            if let error = controller.lastError { Text(error).foregroundStyle(.red).font(.caption).padding(8) }
            WorkbenchTerminalRepresentable(controller: controller)
        }
    }
}
private struct WorkbenchTerminalRepresentable: NSViewRepresentable {
    let controller: WorkbenchSessionController
    func makeNSView(context: Context) -> NSView { controller.hostView }
    func updateNSView(_ nsView: NSView, context: Context) { DispatchQueue.main.async { controller.focus() } }
}
