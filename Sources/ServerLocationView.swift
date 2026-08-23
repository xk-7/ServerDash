import Darwin
import Foundation
import MapKit
import SwiftUI

struct ServerLocation: Hashable, Sendable {
    let ip: String
    let city: String
    let region: String
    let country: String
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var displayName: String {
        [city, region, country]
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, value in
                if !result.contains(value) {
                    result.append(value)
                }
            }
            .joined(separator: " · ")
    }
}

enum ServerLocationError: LocalizedError {
    case cannotResolveHost
    case invalidResponse
    case lookupFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotResolveHost:
            "无法解析服务器公网地址。"
        case .invalidResponse:
            "位置服务返回了无效数据。"
        case .lookupFailed(let message):
            message.isEmpty ? "暂时无法获取服务器位置。" : message
        }
    }
}

private struct IPLocationResponse: Decodable {
    let success: Bool
    let message: String?
    let ip: String?
    let city: String?
    let region: String?
    let country: String?
    let latitude: Double?
    let longitude: Double?

    var location: ServerLocation? {
        guard success,
              let ip,
              let latitude,
              let longitude else {
            return nil
        }
        return ServerLocation(
            ip: ip,
            city: city ?? "",
            region: region ?? "",
            country: country ?? "",
            latitude: latitude,
            longitude: longitude
        )
    }
}

actor ServerLocationService {
    static let shared = ServerLocationService()

    private var cache: [String: ServerLocation] = [:]

    func location(for host: String) async throws -> ServerLocation {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let cached = cache[normalizedHost] {
            return cached
        }

        let ip = try await resolveIPAddress(for: normalizedHost)
        var components = URLComponents(string: "https://ipwho.is")
        components?.path = "/\(ip)"
        guard let url = components?.url else {
            throw ServerLocationError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("ServerDash/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw ServerLocationError.invalidResponse
        }

        let payload = try JSONDecoder().decode(IPLocationResponse.self, from: data)
        guard let location = payload.location else {
            throw ServerLocationError.lookupFailed(payload.message ?? "")
        }
        cache[normalizedHost] = location
        return location
    }

    private func resolveIPAddress(for host: String) async throws -> String {
        try await Task.detached(priority: .utility) {
            var hints = addrinfo()
            hints.ai_flags = AI_ADDRCONFIG
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM

            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0,
                  let firstResult = result else {
                throw ServerLocationError.cannotResolveHost
            }
            defer { freeaddrinfo(firstResult) }

            var cursor: UnsafeMutablePointer<addrinfo>? = firstResult
            var fallbackAddress: String?
            while let current = cursor {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let status = getnameinfo(
                    current.pointee.ai_addr,
                    current.pointee.ai_addrlen,
                    &buffer,
                    socklen_t(buffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if status == 0 {
                    let address = String(cString: buffer)
                    if current.pointee.ai_family == AF_INET {
                        return address
                    }
                    fallbackAddress = fallbackAddress ?? address
                }
                cursor = current.pointee.ai_next
            }

            guard let fallbackAddress else {
                throw ServerLocationError.cannotResolveHost
            }
            return fallbackAddress
        }.value
    }
}

struct ServerLocationMapView: View {
    let server: ServerRecord

    @State private var location: ServerLocation?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var reloadID = UUID()

    var body: some View {
        Group {
            if let location {
                Map(position: $mapPosition, interactionModes: [.pan, .zoom]) {
                    Marker(
                        server.name,
                        systemImage: "server.rack",
                        coordinate: location.coordinate
                    )
                    .tint(Color.appAccent)
                }
                .mapStyle(.standard(elevation: .realistic))
                .overlay(alignment: .topLeading) {
                    locationBadge(location)
                        .padding(AppleDesign.Spacing.md)
                }
                .overlay(alignment: .bottomTrailing) {
                    Text("公网 IP 大致位置 · ipwho.is")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, AppleDesign.Spacing.xs)
                        .padding(.vertical, AppleDesign.Spacing.xxs)
                        .background(AppleChromeBackground())
                        .clipShape(Capsule())
                        .padding(AppleDesign.Spacing.sm)
                }
                .accessibilityLabel("\(server.name) 的服务器位置")
                .accessibilityValue(location.displayName)
            } else if isLoading {
                ZStack {
                    Color.appSurface
                    VStack(spacing: AppleDesign.Spacing.sm) {
                        ProgressView()
                        Text("正在定位 \(server.name)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("无法显示服务器位置", systemImage: "map")
                } description: {
                    Text(errorMessage ?? "此地址可能属于内网，或位置服务暂时不可用。")
                } actions: {
                    Button("重试", systemImage: "arrow.clockwise") {
                        reloadID = UUID()
                    }
                }
                .background(Color.appSurface)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220, maxHeight: 280)
        .clipShape(RoundedRectangle(cornerRadius: AppleDesign.Radius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppleDesign.Radius.panel, style: .continuous)
                .stroke(Color.appHairline.opacity(0.5))
        }
        .task(id: reloadID) {
            await loadLocation()
        }
    }

    private func locationBadge(_ location: ServerLocation) -> some View {
        HStack(spacing: AppleDesign.Spacing.sm) {
            Image(systemName: "mappin.and.ellipse")
                .foregroundStyle(Color.appAccent)
            VStack(alignment: .leading, spacing: AppleDesign.Spacing.xxs) {
                Text(location.displayName.isEmpty ? "服务器位置" : location.displayName)
                    .font(.headline)
                Text(location.ip)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, AppleDesign.Spacing.md)
        .padding(.vertical, AppleDesign.Spacing.sm)
        .background(AppleChromeBackground())
        .clipShape(RoundedRectangle(cornerRadius: AppleDesign.Radius.thumbnail, style: .continuous))
    }

    @MainActor
    private func loadLocation() async {
        isLoading = true
        errorMessage = nil
        do {
            let resolvedLocation = try await ServerLocationService.shared.location(for: server.host)
            location = resolvedLocation
            mapPosition = .region(
                MKCoordinateRegion(
                    center: resolvedLocation.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 8, longitudeDelta: 8)
                )
            )
        } catch {
            location = nil
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
