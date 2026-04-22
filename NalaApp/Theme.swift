import SwiftUI
import SwiftTerm

enum NalaTheme {
    // MARK: - Coral Accent (Primary)

    static let coralPrimary = Color(red: 1.0, green: 0.42, blue: 0.32)     // #FF6B52
    static let coralLight = Color(red: 1.0, green: 0.56, blue: 0.48)       // #FF8F7A
    static let coralHot = Color(red: 1.0, green: 0.31, blue: 0.22)         // #FF5038
    static let coralWarm = Color(red: 1.0, green: 0.62, blue: 0.43)        // #FF9E6D

    // MARK: - Blue Accent (Secondary)

    static let blueAccent = Color(red: 0.345, green: 0.651, blue: 1.0)     // #58A6FF

    // MARK: - Semantic / Status

    static let amber = Color(red: 1.0, green: 0.70, blue: 0.28)            // #FFB347
    static let green = Color(red: 0.494, green: 0.906, blue: 0.529)        // #7EE787
    static let red = Color(red: 1.0, green: 0.42, blue: 0.42)              // #FF6B6B
    static let teal = Color(red: 0.337, green: 0.831, blue: 0.867)         // #56D4DD
    static let magenta = Color(red: 0.824, green: 0.659, blue: 1.0)        // #D2A8FF
    static let openaiGreen = Color(red: 0.063, green: 0.639, blue: 0.498)  // #10A37F

    // MARK: - Backgrounds

    static let bgBase = Color(red: 0.035, green: 0.043, blue: 0.063)       // #090B10
    static let bgSurface = Color(red: 0.059, green: 0.071, blue: 0.094)    // #0F1218
    static let bgSurfaceRaised = Color(red: 0.082, green: 0.102, blue: 0.133) // #151A22

    // MARK: - Text

    static let textPrimary = Color(red: 0.941, green: 0.957, blue: 0.973)  // #F0F4F8
    static let textSecondary = Color(red: 0.545, green: 0.580, blue: 0.620)// #8B949E
    static let textTertiary = Color(red: 0.282, green: 0.310, blue: 0.345) // #484F58

    // MARK: - Gradients

    static let coralGradient = LinearGradient(
        colors: [coralPrimary, coralWarm],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let coralGradientDeep = LinearGradient(
        colors: [coralHot, coralPrimary, Color(red: 1.0, green: 0.627, blue: 0.478)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - Accent Divider

    static var accentDivider: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [coralPrimary.opacity(0.15), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 4)
            .blur(radius: 2)

            LinearGradient(
                colors: [coralPrimary, coralLight.opacity(0.3), .clear],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 1)
        }
    }

    // MARK: - Terminal Background (SwiftUI) — must match terminalNSBackground exactly

    static let terminalBackground = Color(red: 0.035, green: 0.043, blue: 0.063)

    // MARK: - Terminal Colors (AppKit)

    static let terminalNSBackground = NSColor(red: 0.035, green: 0.043, blue: 0.063, alpha: 1.0)
    static let terminalNSForeground = NSColor(red: 0.902, green: 0.929, blue: 0.953, alpha: 1.0)
    static let terminalNSCaret = NSColor(red: 1.0, green: 0.42, blue: 0.32, alpha: 1.0)
    static let terminalNSSelection = NSColor(red: 1.0, green: 0.42, blue: 0.32, alpha: 0.3)

    // MARK: - NSColor Equivalents (AppKit contexts)

    static let coralPrimaryNS = NSColor(red: 1.0, green: 0.42, blue: 0.32, alpha: 1.0)
    static let bgBaseNS = NSColor(red: 0.035, green: 0.043, blue: 0.063, alpha: 1.0)
    static let bgSurfaceNS = NSColor(red: 0.059, green: 0.071, blue: 0.094, alpha: 1.0)

    // Accent gradient used in header dividers (kept for ProgressHeader per-context accent colors)
    static func accentGradient(_ color: SwiftUI.Color = coralPrimary) -> LinearGradient {
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
        /* 3 yellow  */ SwiftTerm.Color(red: c(0xff), green: c(0xb3), blue: c(0x47)),
        /* 4 blue    */ SwiftTerm.Color(red: c(0x58), green: c(0xa6), blue: c(0xff)),
        /* 5 magenta */ SwiftTerm.Color(red: c(0xd2), green: c(0xa8), blue: c(0xff)),
        /* 6 cyan    */ SwiftTerm.Color(red: c(0x79), green: c(0xc0), blue: c(0xff)),
        /* 7 white   */ SwiftTerm.Color(red: c(0xb1), green: c(0xba), blue: c(0xc4)),
        // Bright colors
        /* 8  brBlack   */ SwiftTerm.Color(red: c(0x6e), green: c(0x76), blue: c(0x81)),
        /* 9  brRed     */ SwiftTerm.Color(red: c(0xff), green: c(0xa1), blue: c(0x98)),
        /* 10 brGreen   */ SwiftTerm.Color(red: c(0xaf), green: c(0xf5), blue: c(0xb4)),
        /* 11 brYellow  */ SwiftTerm.Color(red: c(0xff), green: c(0xc8), blue: c(0x6b)),
        /* 12 brBlue    */ SwiftTerm.Color(red: c(0x79), green: c(0xc0), blue: c(0xff)),
        /* 13 brMagenta */ SwiftTerm.Color(red: c(0xd2), green: c(0xa8), blue: c(0xff)),
        /* 14 brCyan    */ SwiftTerm.Color(red: c(0xa5), green: c(0xd6), blue: c(0xff)),
        /* 15 brWhite   */ SwiftTerm.Color(red: c(0xf0), green: c(0xf6), blue: c(0xfc)),
    ]
}
