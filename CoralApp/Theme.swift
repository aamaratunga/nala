import SwiftUI
import SwiftTerm

enum CoralTheme {
    // Terminal background (SwiftUI)
    static let terminalBackground = SwiftUI.Color(red: 0.031, green: 0.043, blue: 0.063)

    // Terminal colors (AppKit)
    static let terminalNSBackground = NSColor(red: 0.051, green: 0.067, blue: 0.090, alpha: 1.0)
    static let terminalNSForeground = NSColor(red: 0.902, green: 0.929, blue: 0.953, alpha: 1.0)
    static let terminalNSCaret = NSColor(red: 0.345, green: 0.651, blue: 1.0, alpha: 1.0)
    static let terminalNSSelection = NSColor(red: 0.345, green: 0.651, blue: 1.0, alpha: 0.3)

    // Accent gradient used in header dividers
    static func accentGradient(_ color: SwiftUI.Color) -> LinearGradient {
        LinearGradient(
            colors: [color.opacity(0.6), color.opacity(0)],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    // MARK: - ANSI Palette

    /// Convert a 0-255 byte to SwiftTerm's UInt16 color component (0-65535).
    private static func c(_ byte: UInt16) -> UInt16 { byte * 257 }

    /// GitHub-dark-inspired ANSI palette (16 colors).
    static let ansiPalette: [SwiftTerm.Color] = [
        // Normal colors
        /* 0 black   */ SwiftTerm.Color(red: c(0x48), green: c(0x4f), blue: c(0x58)),
        /* 1 red     */ SwiftTerm.Color(red: c(0xff), green: c(0x7b), blue: c(0x72)),
        /* 2 green   */ SwiftTerm.Color(red: c(0x7e), green: c(0xe7), blue: c(0x87)),
        /* 3 yellow  */ SwiftTerm.Color(red: c(0xd2), green: c(0x99), blue: c(0x22)),
        /* 4 blue    */ SwiftTerm.Color(red: c(0x58), green: c(0xa6), blue: c(0xff)),
        /* 5 magenta */ SwiftTerm.Color(red: c(0xd2), green: c(0xa8), blue: c(0xff)),
        /* 6 cyan    */ SwiftTerm.Color(red: c(0x79), green: c(0xc0), blue: c(0xff)),
        /* 7 white   */ SwiftTerm.Color(red: c(0xb1), green: c(0xba), blue: c(0xc4)),
        // Bright colors
        /* 8  brBlack   */ SwiftTerm.Color(red: c(0x6e), green: c(0x76), blue: c(0x81)),
        /* 9  brRed     */ SwiftTerm.Color(red: c(0xff), green: c(0xa1), blue: c(0x98)),
        /* 10 brGreen   */ SwiftTerm.Color(red: c(0xaf), green: c(0xf5), blue: c(0xb4)),
        /* 11 brYellow  */ SwiftTerm.Color(red: c(0xe3), green: c(0xb3), blue: c(0x41)),
        /* 12 brBlue    */ SwiftTerm.Color(red: c(0x79), green: c(0xc0), blue: c(0xff)),
        /* 13 brMagenta */ SwiftTerm.Color(red: c(0xd2), green: c(0xa8), blue: c(0xff)),
        /* 14 brCyan    */ SwiftTerm.Color(red: c(0xa5), green: c(0xd6), blue: c(0xff)),
        /* 15 brWhite   */ SwiftTerm.Color(red: c(0xf0), green: c(0xf6), blue: c(0xfc)),
    ]
}
