import Foundation

enum DisplayFormat {
    static func integer(
        _ value: Int,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        value.formatted(
            .number
                .grouping(.automatic)
                .locale(locale)
        )
    }

    static func decimal(
        _ value: Double,
        fractionLength: Int,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        value.formatted(
            .number
                .grouping(.automatic)
                .precision(.fractionLength(fractionLength))
                .locale(locale)
        )
    }

    static func percent(_ value: Double) -> String {
        "\(integer(Int(value.rounded())))%"
    }

    static func bytes(_ value: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.countStyle = .binary
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(max(0, value)))
    }

    static func speed(_ value: Double) -> String {
        "\(bytes(value))/s"
    }

    static func shortDate(_ date: Date?) -> String {
        guard let date else { return "尚未连接" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
