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
    case invalidResponse
    case lookupFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "服务器端位置服务返回了无效数据。"
        case .lookupFailed(let message):
            message.isEmpty
                ? "服务器无法访问 ipinfo.io，请检查服务器的出站网络。"
                : message
        }
    }
}

private struct IPInfoLocationResponse: Decodable {
    let ip: String?
    let city: String?
    let region: String?
    let country: String?
    let loc: String?

    var location: ServerLocation? {
        let coordinates = loc?
            .split(separator: ",", omittingEmptySubsequences: false)
            .compactMap { Double($0) }
        guard let ip,
              let coordinates,
              coordinates.count == 2 else {
            return nil
        }
        return ServerLocation(
            ip: ip,
            city: city ?? "",
            region: region ?? "",
            country: country ?? "",
            latitude: coordinates[0],
            longitude: coordinates[1]
        )
    }
}

actor ServerLocationService {
    static let shared = ServerLocationService()

    private static let remoteCommand = #"""
    sh -lc '
    if command -v curl >/dev/null 2>&1; then
      exec curl -fsS --max-time 8 -H "User-Agent: ServerDash/0.1" https://ipinfo.io/json
    fi
    if command -v wget >/dev/null 2>&1; then
      exec wget -qO- --timeout=8 --user-agent="ServerDash/0.1" https://ipinfo.io/json
    fi
    exit 127
    '
    """#

    private var cache: [UUID: ServerLocation] = [:]

    func clearCache() {
        cache.removeAll()
    }

    func location(for config: ServerConnectionConfig) async throws -> ServerLocation {
        if PrivacySettings.disableLocationLookup {
            throw ServerLocationError.lookupFailed("已停止位置采集。")
        }
        if let cached = cache[config.id] {
            return cached
        }

        let data = try await requestFromServer(config)
        let payload = try JSONDecoder().decode(IPInfoLocationResponse.self, from: data)
        guard let location = payload.location else {
            throw ServerLocationError.invalidResponse
        }
        cache[config.id] = location
        return location
    }

    private func requestFromServer(_ config: ServerConnectionConfig) async throws -> Data {
        let plan = try SystemOpenSSHConnectionProvider().launchPlan(
            for: config,
            purpose: .remoteCommand(Self.remoteCommand)
        )

        do {
            let result = try await ConnectionProcessController.shared.run(
                ProcessRunRequest(
                    executable: plan.executable,
                    arguments: plan.arguments,
                    environment: plan.environment,
                    connectTimeout: config.connectTimeout,
                    totalTimeout: max(16, config.connectTimeout + 8),
                    maxOutputBytes: 1_048_576,
                    serverID: config.id,
                    module: .monitoring,
                    host: config.host,
                    port: config.port
                )
            )
            let output = Data(result.output.utf8)
            guard !output.isEmpty else {
                throw ServerLocationError.invalidResponse
            }
            return output
        } catch let error as ConnectionError {
            throw ServerLocationError.lookupFailed(error.localizedDescription)
        }
    }
}

private extension ServerLocation {
    init?(geoLocation: ServerGeoLocation) {
        guard let latitude = geoLocation.latitude,
              let longitude = geoLocation.longitude else {
            return nil
        }
        self.init(
            ip: geoLocation.publicIP,
            city: geoLocation.city,
            region: geoLocation.region,
            country: geoLocation.country,
            latitude: latitude,
            longitude: longitude
        )
    }
}

struct ServerLocationMapView: View {
    @EnvironmentObject private var appState: AppState

    let server: ServerRecord
    let initialLocation: ServerGeoLocation?
    let allowsInteraction: Bool

    @State private var location: ServerLocation?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var reloadID = UUID()

    init(
        server: ServerRecord,
        initialLocation: ServerGeoLocation? = nil,
        allowsInteraction: Bool = true
    ) {
        self.server = server
        self.initialLocation = initialLocation
        self.allowsInteraction = allowsInteraction
    }

    private var requestID: String {
        "\(reloadID.uuidString)-\(initialLocation?.publicIP ?? "")"
    }

    var body: some View {
        Group {
            if let location {
                Map(
                    position: $mapPosition,
                    interactionModes: allowsInteraction ? [.pan, .zoom] : []
                ) {
                    Marker(
                        server.name,
                        systemImage: "server.rack",
                        coordinate: location.coordinate
                    )
                    .tint(Color.appAccent)
                }
                .mapStyle(.standard(elevation: .realistic))
                .allowsHitTesting(allowsInteraction)
                .overlay(alignment: .topLeading) {
                    locationBadge(location)
                        .padding(AppleDesign.Spacing.md)
                }
                .overlay(alignment: .bottomTrailing) {
                    Text("服务器公网出口大致位置 · ipinfo.io")
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
                        Text("正在通过服务器获取公网位置")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("无法显示服务器位置", systemImage: "map")
                } description: {
                    Text(errorMessage ?? "服务器无法访问位置服务。")
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
        .task(id: requestID) {
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
                Text(PrivacySettings.hideIPInformation ? "[IP]" : location.ip)
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
        if PrivacySettings.disableLocationLookup {
            location = nil
            errorMessage = "已停止位置采集。"
            isLoading = false
            return
        }
        do {
            let resolvedLocation: ServerLocation
            if let initialLocation,
               let snapshotLocation = ServerLocation(geoLocation: initialLocation) {
                resolvedLocation = snapshotLocation
            } else {
                resolvedLocation = try await ServerLocationService.shared.location(
                    for: appState.connectionConfig(for: server)
                )
            }
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
