import Foundation
import SwiftUI

enum MonitorCardKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case cpu
    case load
    case memory
    case processes
    case network
    case storage
    case gpu
    case location
    case docker

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU 使用率"
        case .load: "CPU 负载"
        case .memory: "内存使用"
        case .processes: "进程"
        case .network: "网络使用"
        case .storage: "存储"
        case .gpu: "GPU 使用率"
        case .location: "IP 位置"
        case .docker: "Docker"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .load: "chart.xyaxis.line"
        case .memory: "memorychip"
        case .processes: "list.bullet.rectangle"
        case .network: "arrow.up.arrow.down.circle"
        case .storage: "internaldrive"
        case .gpu: "display"
        case .location: "mappin.and.ellipse"
        case .docker: "shippingbox"
        }
    }

    var supportsDetail: Bool {
        true
    }

    static let defaultOrder: [MonitorCardKind] = [
        .cpu, .load, .memory, .network, .storage,
        .processes, .location, .gpu, .docker
    ]

    func isAvailable(
        in snapshot: ServerSnapshot,
        hideIPInformation: Bool,
        disableLocationLookup: Bool = false
    ) -> Bool {
        switch self {
        case .gpu:
            !snapshot.gpus.isEmpty
        case .docker:
            snapshot.dockerAvailable
        case .location:
            !hideIPInformation && !disableLocationLookup
        default:
            true
        }
    }
}

struct MonitorLayoutConfiguration: Codable, Equatable {
    var order: [String]
    var hidden: [String]

    static let `default` = MonitorLayoutConfiguration(
        order: MonitorCardKind.defaultOrder.map(\.rawValue),
        hidden: []
    )
}

@MainActor
final class MonitorLayoutStore: ObservableObject {
    @Published private var revision = 0

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func orderedCards(for serverID: UUID) -> [MonitorCardKind] {
        _ = revision
        let configuration = configuration(for: serverID)
        var result = configuration.order.compactMap(MonitorCardKind.init(rawValue:))
        for card in MonitorCardKind.defaultOrder where !result.contains(card) {
            result.append(card)
        }
        return result
    }

    func visibleCards(
        for serverID: UUID,
        snapshot: ServerSnapshot,
        hideIPInformation: Bool,
        disableLocationLookup: Bool = false
    ) -> [MonitorCardKind] {
        let hidden = Set(configuration(for: serverID).hidden)
        return orderedCards(for: serverID).filter {
            !hidden.contains($0.rawValue) &&
            $0.isAvailable(
                in: snapshot,
                hideIPInformation: hideIPInformation,
                disableLocationLookup: disableLocationLookup
            )
        }
    }

    func isHidden(_ card: MonitorCardKind, for serverID: UUID) -> Bool {
        _ = revision
        return configuration(for: serverID).hidden.contains(card.rawValue)
    }

    func setHidden(_ hidden: Bool, card: MonitorCardKind, for serverID: UUID) {
        var configuration = configuration(for: serverID)
        var hiddenCards = Set(configuration.hidden)
        if hidden {
            hiddenCards.insert(card.rawValue)
        } else {
            hiddenCards.remove(card.rawValue)
        }
        configuration.hidden = MonitorCardKind.defaultOrder
            .filter { hiddenCards.contains($0.rawValue) }
            .map(\.rawValue)
        save(configuration, for: serverID)
    }

    func setOrder(_ cards: [MonitorCardKind], for serverID: UUID) {
        var configuration = configuration(for: serverID)
        configuration.order = cards.map(\.rawValue)
        save(configuration, for: serverID)
    }

    func reset(serverID: UUID) {
        defaults.removeObject(forKey: key(for: serverID))
        revision += 1
    }

    private func configuration(for serverID: UUID) -> MonitorLayoutConfiguration {
        guard let data = defaults.data(forKey: key(for: serverID)),
              let configuration = try? JSONDecoder().decode(
                MonitorLayoutConfiguration.self,
                from: data
              ) else {
            return .default
        }
        return configuration
    }

    private func save(_ configuration: MonitorLayoutConfiguration, for serverID: UUID) {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: key(for: serverID))
        revision += 1
    }

    private func key(for serverID: UUID) -> String {
        "monitorLayout.\(serverID.uuidString)"
    }
}
