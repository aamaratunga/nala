# TODOS

## macOS App

Items ordered by recommended execution sequence.

---

### Tier 1 — Distribution readiness

#### 1. Developer ID signing + notarization

**What:** Sign the app with an Apple Developer ID certificate and notarize it so macOS Gatekeeper allows installation without right-click workarounds.

**Why:** Ad-hoc signed DMGs trigger Gatekeeper warnings on first install. Developer ID signing + notarization eliminates this friction entirely.

**Context:** Requires an Apple Developer account ($99/yr). Implementation involves:
- Adding `ENABLE_HARDENED_RUNTIME=YES` build setting to `project.yml`
- Configuring `CODE_SIGN_IDENTITY` GitHub Actions secret with the Developer ID Application certificate
- Adding `xcrun notarytool submit` and `xcrun stapler staple` steps to `release.yml` (stubs already present as comments)
- Embedded frameworks (SwiftTerm, Lottie, Sparkle) compile from source with the app's signing identity, so they inherit the Developer ID signature automatically
- May need specific entitlements (e.g., `com.apple.security.cs.disable-library-validation`) if Hardened Runtime causes codesign failures — add only if errors prove they're needed
- Secrets needed: `CODE_SIGN_IDENTITY`, `APPLE_ID`, `APPLE_APP_PASSWORD`, `APPLE_TEAM_ID`

**Effort:** M
**Priority:** P1
**Depends on:** Apple Developer account enrollment

#### 2. Bundle tmux binary for distribution

**What:** Compile a statically-linked universal tmux binary and ship it inside the .app bundle so the app works for users without Homebrew.

**Why:** tmux is not a system binary on macOS. The app currently resolves tmux from Homebrew paths (`/opt/homebrew/bin/tmux`, `/usr/local/bin/tmux`). Users who download the app without Homebrew get a helpful install prompt but can't use the app.

**Context:** tmux is ISC-licensed (permissive). It depends on libevent (not shipped with macOS) and ncurses (shipped with macOS). The build would statically link libevent, produce a universal binary (arm64 + x86_64), and place it in `Contents/MacOS/` (for `Bundle.main.path(forAuxiliaryExecutable:)` compatibility — already added as first entry in `TmuxService.knownTmuxPaths`). Note: if bundled to `Contents/Helpers/` instead, update the bundle path lookup in `TmuxService.swift`.

**Effort:** M
**Priority:** P2

---

### Tier 2 — Maintainability

#### 3. Extract WorktreeManager from SessionStore

**What:** Extract worktree creation/deletion orchestration into a separate `WorktreeManager` class when SessionStore exceeds 2,500 lines.

**Why:** SessionStore.swift is ~1,600 lines and growing. It owns state, services, handlers, persistence, and multi-step async worktree pipelines. The worktree code is self-contained and testable in isolation.

**Context:** The worktree creation pipeline (`performCreateWorktree`, `performDeleteWorktree`) is multi-step async orchestration that talks to GitService and TmuxService but only writes back to SessionStore via `activeCreations`/`activeDeletions` dictionaries. Extraction is clean. The challenge is @Observable: child objects need to signal the parent for SwiftUI updates. Options: (a) make WorktreeManager @Observable and compose, (b) use callbacks, (c) use Combine publishers. Trigger: when SessionStore crosses 2,500 lines or a bug hides in the worktree pipeline complexity.

**Effort:** M
**Priority:** P3

#### 4. Homebrew Cask tap

**What:** Create a Homebrew Cask formula so users can `brew install --cask nala`.

**Why:** Standard macOS distribution channel for developer tools. Enables one-command install and auto-upgrades via `brew upgrade`.

**Context:** Requires stable release cadence on GitHub Releases first. Cask formula points to the DMG URL. Can start with a personal tap (`aamaratunga/homebrew-tap`) before upstreaming to `homebrew-cask`.

**Effort:** S
**Priority:** P3
**Depends on:** Stable release cadence

---

## Completed

- ~~Enable branch protection requiring CI pass~~ — Branch protection on `main` with required `Build & Test` check and squash-only merges
- ~~Prune stale display names from UserDefaults on startup~~ — Expanded: prunes display names, event files, tmp files, and browse paths. Also fixes folderExpansion pruning gap in reconcileOrder.
- ~~Remove Gemini agent support~~ — Removed regex, launch command, UI badge colors, default commands, test fixtures, and doc references
- ~~CI pipeline (xcodebuild)~~ — GitHub Actions workflow: build + test on every push/PR, macos-15 runner
- ~~Create DESIGN.md~~ — Comprehensive 251-line design system documented
- ~~Rewrite SessionStore tests~~ — 905 lines covering all production handlers
- ~~Accessibility audit (VoiceOver)~~ — Labels implemented on StatusDot, SessionRowView, CommandPaletteView, SessionDetailView, and progress views
- ~~Create entitlements file~~ — Empty scaffold at `NalaApp/NalaApp.entitlements`, referenced from `project.yml`. Non-sandboxed app needs no specific entitlements; add in Phase 2 if Hardened Runtime requires them.
- ~~Auto-update mechanism (Sparkle)~~ — SPM dependency, `UpdateManager` service, "Check for Updates..." menu item, appcast generation in release workflow, EdDSA signing
- ~~Dependabot for GitHub Actions~~ — `.github/dependabot.yml` configured for weekly checks
- ~~Version duplication fix~~ — Info.plist uses `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)` build setting variables; `project.yml` is single source of truth
- ~~Release CI workflow~~ — Tag-triggered workflow builds arm64 Release, creates DMG with `create-dmg`, verifies codesign, uploads to GitHub Releases with auto-generated notes
- ~~Tmux-not-found UX~~ — Enhanced overlay with descriptive message and "Copy brew install tmux" button; bundle path added to `TmuxService.knownTmuxPaths` for future bundling
