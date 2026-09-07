import Foundation

/// Data-only display state. No parser, hyperlink payloads, images, or scrollback are serialized.
/// Intended for offline, non-interactive recording renderers, never for resuming a remote process.
public struct TerminalDisplaySnapshot: Codable, Equatable, Sendable {
    public struct Cell: Codable, Equatable, Sendable {
        public var text: String
        public var width: Int
        public var foreground: UInt32
        public var background: UInt32
        public var style: UInt8
        public var underline: UInt32?
    }
    public struct Line: Codable, Equatable, Sendable {
        public var cells: [Cell]
        public var mode: Int
    }
    public var columns: Int
    public var rows: Int
    public var lines: [Line]
    public var cursorColumn: Int
    public var cursorRow: Int
    public var cursorVisible: Bool
    public var cursorStyle: String
    public var foreground: UInt32
    public var background: UInt32
    public var hasImages: Bool
}

extension Terminal {
    /// Copies only the displayed grid, resolving extended graphemes while they still belong
    /// to this terminal. followOutput deliberately excludes browsing old scrollback.
    public func displaySnapshot(followOutput: Bool = false) -> TerminalDisplaySnapshot {
        let source = displayBuffer
        let top = followOutput ? source.yBase : source.yDisp
        func rgb(_ color: Color) -> UInt32 {
            (UInt32(color.red >> 8) << 16) | (UInt32(color.green >> 8) << 8) | UInt32(color.blue >> 8)
        }
        func resolve(_ color: Attribute.Color, foreground: Bool) -> UInt32 {
            switch color {
            case .ansi256(let code): return rgb(ansiColors[Int(code)])
            case .trueColor(let r, let g, let b): return UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
            case .defaultColor: return rgb(foreground ? foregroundColor : backgroundColor)
            case .defaultInvertedColor: return rgb(foreground ? backgroundColor : foregroundColor)
            }
        }
        var lines: [TerminalDisplaySnapshot.Line] = []
        for row in 0..<rows {
            let line = source.lines[top + row]
            let cells = (0..<cols).map { column -> TerminalDisplaySnapshot.Cell in
                let cell = line[column], attr = cell.attribute
                return .init(text: cell.code == 0 ? " " : String(getCharacter(for: cell)),
                             width: Int(cell.width), foreground: resolve(attr.fg, foreground: true),
                             background: resolve(attr.bg, foreground: false), style: attr.style.rawValue,
                             underline: attr.underlineColor.map { resolve($0, foreground: true) })
            }
            let mode: Int
            switch line.renderMode {
            case .single: mode = 0
            case .doubleWidth: mode = 1
            case .doubledTop: mode = 2
            case .doubledDown: mode = 3
            }
            lines.append(.init(cells: cells, mode: mode))
        }
        let cursorRow = source.yBase + source.y - top
        return .init(columns: cols, rows: rows, lines: lines, cursorColumn: source.x,
                     cursorRow: cursorRow, cursorVisible: !cursorHidden && cursorRow >= 0 && cursorRow < rows,
                     cursorStyle: String(describing: options.cursorStyle), foreground: rgb(foregroundColor),
                     background: rgb(backgroundColor), hasImages: source.hasAnyImages)
    }
}
