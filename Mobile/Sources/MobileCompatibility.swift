import Foundation

enum TerminalConnectionStatus: String, Sendable {
    case connecting
    case connected
    case disconnected
    case failed
    case interrupted

    var title: String {
        switch self {
        case .connecting: "连接中"
        case .connected: "已连接"
        case .disconnected: "已断开"
        case .failed: "连接失败"
        case .interrupted: "已因进入后台中断"
        }
    }
}
