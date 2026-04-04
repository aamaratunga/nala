# Design System — Nala macOS

## Product Context
- **What this is:** A native macOS app for orchestrating multiple AI coding agents (Claude, Gemini) running in parallel git worktrees with embedded terminals
- **Who it's for:** Software engineers managing multiple AI coding sessions simultaneously
- **Space/industry:** Developer tools, AI orchestration, terminal emulators
- **Project type:** macOS native desktop app (SwiftUI + AppKit)

## Aesthetic Direction
- **Direction:** Industrial/Utilitarian meets Refined — mission control for AI agents
- **Decoration level:** Intentional — subtle vibrancy materials, glow effects for active states, gradient accents. No gratuitous ornamentation.
- **Mood:** Powerful, alive, warm. Like piloting something. Dense where information matters (sidebar), spacious where you watch (terminal). The app should feel active when agents are working and calm when they're idle.
- **Reference sites:** Linear (layout discipline), Raycast (glassmorphism, premium feel), Warp (terminal aesthetics), Ghostty (platform-native respect)

## Typography
- **Display/Hero:** SF Pro Display (system) — macOS native, don't fight the platform
- **Body/UI:** SF Pro Text (system) — `.headline` for session names, `.callout` for status, `.caption` for metadata
- **Data/Tables:** SF Pro with tabular-nums for counts, metrics
- **Code/Terminal:** JetBrains Mono (preferred) -> MesloLGS Nerd Font Mono (Nerd Font icon glyphs) -> system monospace, via SwiftTerm — consider offering as user preference
- **Loading:** System fonts, zero load time (native advantage)
- **Scale:** Follow Apple HIG dynamic type sizes. Key mappings:
  - `.largeTitle` (34pt) — Loading screen app name
  - `.title3` (20pt) — Section headers (In Progress, Done)
  - `.headline` (17pt semibold) — Session names
  - `.callout` (16pt) — Status text, descriptions
  - `.caption` (12pt) — Metadata, timestamps, branch labels
  - `.caption2` (11pt) — Badge text, tertiary info

## Color

### Philosophy
Warm coral accent on deep blue-black. Every developer tool defaults to cold blue. The primary accent uses a gradient for energy.

### Palette

#### Coral Accent (Primary)
- **Coral Primary:** `#FF6B52` — main accent, buttons, selected states, working indicators
- **Coral Light:** `#FF8F7A` — hover states, lighter accent
- **Coral Hot:** `#FF5038` — gradient start, emphasis
- **Coral Warm:** `#FF9E6D` — gradient end
- **Coral Gradient:** `linear-gradient(135deg, #FF6B52, #FF9E6D)` — primary gradient for buttons, dividers, accent bars
- **Coral Gradient Deep:** `linear-gradient(135deg, #FF5038, #FF6B52, #FFA07A)` — hero/display gradient
- **Coral Glow:** `rgba(255, 107, 82, 0.12)` — background tint for coral-associated elements
- **Coral Glow Strong:** `rgba(255, 107, 82, 0.25)` — stronger glow for selected/active states

#### Blue Accent (Secondary)
- **Blue:** `#58A6FF` — informational, links, branch labels, terminal cursor
- **Blue Muted:** `rgba(88, 166, 255, 0.12)` — background tint for blue elements

#### Backgrounds
- **Base:** `#090B10` — deepest background, terminal area
- **Surface:** `#0F1218` — sidebar, cards, elevated surfaces
- **Surface Raised:** `#151A22` — modals, popovers, raised panels
- **Sidebar:** `rgba(15, 18, 24, 0.75)` + `blur(30px) saturate(1.3)` — vibrancy material
- **Header:** `rgba(15, 18, 24, 0.65)` + `blur(16px)` — translucent header bar

#### Text
- **Primary:** `#F0F4F8` — main body text, session names
- **Secondary:** `#8B949E` — status text, descriptions, captions
- **Tertiary:** `#484F58` — timestamps, minimal UI, placeholders

#### Semantic / Status
- **Green (Done):** `#7EE787` / glow: `rgba(126, 231, 135, 0.15)`
- **Amber (Waiting):** `#FFB347` / glow: `rgba(255, 179, 71, 0.12)`
- **Red (Stuck):** `#FF6B6B` / glow: `rgba(255, 107, 107, 0.12)`
- **Teal (Terminal):** `#56D4DD` / badge bg: `rgba(86, 212, 221, 0.12)`
- **Magenta (Gemini):** `#D2A8FF` / badge bg: `rgba(210, 168, 255, 0.12)`

### SwiftUI Color Definitions
```swift
// In NalaTheme:
static let coralPrimary = Color(red: 1.0, green: 0.42, blue: 0.32)     // #FF6B52
static let coralLight = Color(red: 1.0, green: 0.56, blue: 0.48)       // #FF8F7A
static let coralHot = Color(red: 1.0, green: 0.31, blue: 0.22)         // #FF5038
static let coralWarm = Color(red: 1.0, green: 0.62, blue: 0.43)        // #FF9E6D

static let blueAccent = Color(red: 0.345, green: 0.651, blue: 1.0)     // #58A6FF
static let amber = Color(red: 1.0, green: 0.70, blue: 0.28)            // #FFB347
static let green = Color(red: 0.494, green: 0.906, blue: 0.529)        // #7EE787
static let red = Color(red: 1.0, green: 0.42, blue: 0.42)              // #FF6B6B
static let teal = Color(red: 0.337, green: 0.831, blue: 0.867)         // #56D4DD
static let magenta = Color(red: 0.824, green: 0.659, blue: 1.0)        // #D2A8FF

static let bgBase = Color(red: 0.035, green: 0.043, blue: 0.063)       // #090B10
static let bgSurface = Color(red: 0.059, green: 0.071, blue: 0.094)    // #0F1218

static let textPrimary = Color(red: 0.941, green: 0.957, blue: 0.973)  // #F0F4F8
static let textSecondary = Color(red: 0.545, green: 0.580, blue: 0.620)// #8B949E
static let textTertiary = Color(red: 0.282, green: 0.310, blue: 0.345) // #484F58
```

### Glow Effects
Status dots and accent bars should have colored shadow halos:
```swift
// Working status dot glow
.shadow(color: coralPrimary.opacity(0.4), radius: 6)
.shadow(color: coralPrimary.opacity(0.15), radius: 16)

// Waiting status dot glow
.shadow(color: amber.opacity(0.2), radius: 4)

// Done status dot glow
.shadow(color: green.opacity(0.2), radius: 4)

// Selected session accent bar glow
.shadow(color: coralPrimary.opacity(0.4), radius: 4)
```

### Ambient Sidebar Glow
When agents are actively working, the sidebar should have a subtle, breathing coral radial gradient behind the content. This creates the "alive" feeling.
```swift
// Subtle ambient glow overlay on sidebar, pulsing with easeInOut
RadialGradient(
    colors: [coralPrimary.opacity(0.06), .clear],
    center: .init(x: 0.7, y: 0.3),
    startRadius: 0,
    endRadius: 200
)
.animation(.easeInOut(duration: 4).repeatForever(autoreverses: true), value: hasActiveAgents)
```

## Spacing
- **Base unit:** 4px
- **Density:** Comfortable — tight in sidebar (information density), spacious in detail pane
- **Scale:** 2xs(2) xs(4) sm(8) md(16) lg(24) xl(32) 2xl(48) 3xl(64)
- **Sidebar row vertical padding:** 8pt (bumped from 3pt for more breathing room)
- **Sidebar row horizontal padding:** 14pt
- **Detail header padding:** 10pt vertical, 16pt horizontal
- **Terminal frame padding:** 6pt (outer), 14pt (inner content)

## Layout
- **Approach:** macOS NavigationSplitView — platform-native sidebar/detail
- **Sidebar width:** min 220, ideal 280, max 400
- **Grid:** Not applicable (native layout system)
- **Max content width:** Window-driven (min 900px window width)
- **Border radius:**
  - sm: 8px — sidebar rows, badges, inputs, terminal frame
  - md: 12px — cards, component containers, popovers
  - lg: 16px — modals, sheets
  - full: 9999px — capsule badges, pills

## Motion
- **Approach:** Intentional — the app should feel alive when agents are working and quiet when idle
- **Spring animations:** `response: 0.25, dampingFraction: 0.85` (folder expand/collapse, list changes)
- **Easing:** enter(easeOut) exit(easeIn) move(easeInOut)
- **Duration:** micro(50-100ms) short(150-250ms) medium(250-400ms) long(400-700ms)
- **Key animations:**
  - Status dot: teal glow pulse (2s easeInOut infinite) for working state
  - Sidebar ambient glow: breathing (4s easeInOut infinite)
  - Accent divider: static gradient (no animation — the divider itself is the accent)
  - Terminal cursor: coral-colored blink (1.2s step-end)
  - Folder chevron: rotation (0.2s easeInOut)

## Key Design Elements

### Accent Gradient Divider
The header divider is a signature element. Gradient from coral primary to transparent, left to right, with a subtle glow bloom above it:
```swift
// Gradient line
LinearGradient(
    colors: [coralPrimary, coralLight.opacity(0.3), .clear],
    startPoint: .leading,
    endPoint: .trailing
)
.frame(height: 1)

// Optional: glow bloom above (subtle)
LinearGradient(
    colors: [coralPrimary.opacity(0.15), .clear],
    startPoint: .leading,
    endPoint: .trailing
)
.frame(height: 4)
.blur(radius: 2)
```

### Sidebar Row Visual Hierarchy
Status backgrounds are reserved for actionable states. Non-actionable states stay quiet.

**Actionable states** (full gradient background + left accent bar):
- **Waiting for input** (amber 0.18->0.04): user must act
- **Stuck** (red 0.18->0.04): user must act
- **Done** (green 0.18->0.04): user should review

**Non-actionable states** (no background, dot only):
- **Working**: teal status dot with pulsing glow is sufficient. No background gradient, no accent bar.
- **Idle**: gray dot, no background.

**Selected row** (coral outline, independent of status):
Selection uses a border/outline instead of a background fill. This keeps selection and status as independent visual channels — you can always tell both what state a session is in AND which one is selected.
```swift
// Selection outline — layers over any status background
RoundedRectangle(cornerRadius: 8)
    .strokeBorder(coralPrimary.opacity(0.5), lineWidth: 1.5)
```

**Left accent bar** — only shown for actionable states:
```swift
// Accent bar with glow (amber, red, or green)
statusColor.gradient
    .frame(width: 3)
    .shadow(color: statusColor.opacity(0.4), radius: 4)
```

### Primary Buttons
Gradient fill with glow shadow:
```swift
Text("Launch Agent")
    .background(coralGradient)
    .shadow(color: coralPrimary.opacity(0.2), radius: 6)
```

### Terminal Cursor
Coral-colored instead of default blue, with subtle glow:
```swift
static let terminalNSCaret = NSColor(red: 1.0, green: 0.42, blue: 0.32, alpha: 1.0) // Coral
```

## Decisions Log
| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-03-28 | Initial design system created | Created by /design-consultation based on competitive research (Warp, Linear, Raycast, Ghostty) and product context |
| 2026-03-28 | Warm coral accent over system blue | Immediate differentiation. Every dev tool uses blue. |
| 2026-03-28 | Bold variant chosen over Refined | User preferred more dramatic direction: gradients, glow effects, ambient sidebar glow, deeper blacks |
| 2026-03-28 | Gradient primary accent over flat | Coral gradient (#FF5038 > #FF6B52 > #FFA07A) adds energy and dynamism vs flat #E8705A |
| 2026-03-28 | Amber (#FFB347) replaces dull orange (#D29922) | Warmer, more cohesive with coral accent family |
| 2026-03-28 | Deeper blacks (#090B10 base) | More contrast against glowing elements, more dramatic overall |
| 2026-03-28 | SF Pro for all UI chrome | Platform-native, zero-cost, right decision for macOS. Don't fight the platform. |
| 2026-03-28 | Vibrancy materials for sidebar | `.ultraThinMaterial` with blur(30px) creates depth, says "native macOS app" not "web wrapper" |
| 2026-03-28 | Glowing status dots | Colored shadows on status dots make agent state visible at peripheral vision distance |
| 2026-03-28 | Ambient sidebar glow | Breathing coral gradient when agents are active — the app feels alive |
| 2026-03-28 | Quiet working rows, outline selection | Working state gets no background (dot is enough). Selection uses coral outline instead of background fill — independent visual channels for status vs navigation. Only actionable states (waiting/stuck/done) get colored backgrounds + accent bars. |
| 2026-03-28 | Sidebar vibrancy material added | Sidebar background changed from opaque bgSurface to semi-transparent (0.75) + .ultraThinMaterial. Matches DESIGN.md spec for native macOS depth. |
| 2026-03-28 | Terminal font fallback chain fixed | JetBrains Mono (preferred) -> MesloLGS Nerd Font Mono -> system monospace. Matches DESIGN.md spec while keeping Nerd Font icon support. |
| 2026-03-28 | Detail header padding corrected | Changed from 12h/8v to 16h/10v per DESIGN.md spec. |
| 2026-03-28 | Removed stale working row animation from Motion section | Motion section referenced a working row background pulse that was explicitly removed in the sidebar design decisions. Cleaned up the contradiction. |
| 2026-04-04 | Renamed from Coral to Nala | Extracted macOS app to standalone repo. Color names (coralPrimary etc.) retained as they describe the hue, not the product. |
