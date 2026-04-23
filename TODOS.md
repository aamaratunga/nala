# TODOS

## macOS App

Items ordered by recommended execution sequence.

---

### Tier 1 — Coworker beta

#### 1. App icon

**What:** Design and add an app icon (AppIcon asset catalog) so the app has a proper identity in the Dock, Finder, and DMG.

**Why:** The app currently shows the default blank icon. First impression for anyone receiving the DMG.

**Effort:** S
**Priority:** P1

#### 2. Show saved repos in agent / terminal launch lists

**What:** Pre-populate the "New Agent" and "New Terminal" sheets with repos the user has already added in Settings, so they can launch with one click instead of selecting "Other" and browsing.

**Why:** Every new-agent launch currently requires navigating through the file browser even for repos the user works in daily. This is the highest-friction step in the core workflow.

**Effort:** S
**Priority:** P1

#### 3. Bundle tmux binary for distribution

**What:** Compile a statically-linked universal tmux binary and ship it inside the .app bundle so the app works for users without Homebrew.

**Why:** tmux is not a system binary on macOS. The app currently resolves tmux from Homebrew paths (`/opt/homebrew/bin/tmux`, `/usr/local/bin/tmux`). Users who download the app without Homebrew get a helpful install prompt but can't use the app.

**Context:** tmux is ISC-licensed (permissive). It depends on libevent (not shipped with macOS) and ncurses (shipped with macOS). The build would statically link libevent, produce a universal binary (arm64 + x86_64), and place it in `Contents/MacOS/` (for `Bundle.main.path(forAuxiliaryExecutable:)` compatibility — already added as first entry in `TmuxService.knownTmuxPaths`). Note: if bundled to `Contents/Helpers/` instead, update the bundle path lookup in `TmuxService.swift`.

**Effort:** M
**Priority:** P1

---

### Tier 2 — Coworker beta polish

#### 4. Repo-specific sidebar icons

**What:** Add distinct icons or color badges per repo in the session sidebar so users can visually distinguish which repo each session belongs to at a glance.

**Why:** When running agents across multiple repos, the sidebar rows look identical aside from the text label. A visual differentiator (colored dot, emoji, or auto-assigned icon) makes scanning much faster.

**Effort:** S
**Priority:** P2

#### 5. State updates for long-running terminal commands

**What:** Surface progress or activity indicators for terminal sessions running long-lived commands (builds, test suites, installs, etc.) so users can tell at a glance whether a session is actively working, idle, or stuck.

**Why:** During long-running commands the terminal tab looks static — there's no indication in the sidebar or session detail that work is progressing. Users end up switching to the terminal to check, breaking their flow.

**Context:** Possible approaches: (a) parse tmux pane output for activity (bytes-since-last-check), (b) detect running foreground process via `tmux display -p '#{pane_current_command}'`, (c) use shell integration / prompt markers to distinguish "command running" from "shell idle." Option (b) is lowest effort and already compatible with the tmux polling architecture. Could surface state as a subtle activity indicator on the sidebar row (e.g., spinner or pulsing dot while a command is running, checkmark or dash when idle).

**Effort:** M
**Priority:** P2

#### 6. Auto-paste comments to agent terminal

**What:** Add a "Send to agent" button alongside "Copy all to prompt" in the diff viewer's CommentBarView. Injects formatted comments directly into the tmux session via `TmuxService` (`tmux send-keys`).

**Why:** Eliminates the copy → switch to Terminal tab → paste step in the review workflow. The formatted comment text is already produced by `copyAllToPrompt()`.

**Context:** TmuxService already supports `send-keys`. Main concern is timing — what if the agent is mid-response? May need to check agent state (idle/working) before injecting. Could also auto-switch to Terminal tab after sending.

**Effort:** S
**Priority:** P2
**Depends on:** Diff Viewer V1 (PR4: comment system)

---

### Tier 3 — Wider distribution

#### 7. Developer ID signing + notarization

**What:** Sign the app with an Apple Developer ID certificate and notarize it so macOS Gatekeeper allows installation without right-click workarounds.

**Why:** Ad-hoc signed DMGs trigger Gatekeeper warnings on first install. Developer ID signing + notarization eliminates this friction. Not needed for sharing with coworkers (right-click → Open works), but required for wider distribution.

**Context:** Requires an Apple Developer account ($99/yr). Implementation involves:
- Adding `ENABLE_HARDENED_RUNTIME=YES` build setting to `project.yml`
- Configuring `CODE_SIGN_IDENTITY` GitHub Actions secret with the Developer ID Application certificate
- Adding `xcrun notarytool submit` and `xcrun stapler staple` steps to `release.yml` (stubs already present as comments)
- Embedded frameworks (SwiftTerm, Lottie, Sparkle) compile from source with the app's signing identity, so they inherit the Developer ID signature automatically
- May need specific entitlements (e.g., `com.apple.security.cs.disable-library-validation`) if Hardened Runtime causes codesign failures — add only if errors prove they're needed
- Secrets needed: `CODE_SIGN_IDENTITY`, `APPLE_ID`, `APPLE_APP_PASSWORD`, `APPLE_TEAM_ID`

**Effort:** M
**Priority:** P3
**Depends on:** Apple Developer account enrollment

#### 8. Homebrew Cask tap

**What:** Create a Homebrew Cask formula so users can `brew install --cask nala`.

**Why:** Standard macOS distribution channel for developer tools. Enables one-command install and auto-upgrades via `brew upgrade`.

**Context:** Requires stable release cadence on GitHub Releases first. Cask formula points to the DMG URL. Can start with a personal tap (`aamaratunga/homebrew-tap`) before upstreaming to `homebrew-cask`.

**Effort:** S
**Priority:** P3
**Depends on:** Stable release cadence


---

### Tier 4 — Later power-user and platform work

#### 9. Keyboard-driven comment workflow

**What:** Add keyboard navigation for the diff viewer — arrow keys to navigate lines in the WKWebView, press 'c' to add a comment on the focused line, Escape to cancel.

**Why:** Power users reviewing many files want to stay on the keyboard. The V1 mouse-click workflow requires switching between keyboard (typing comments) and mouse (clicking lines).

**Context:** Requires JS-side focus management in CM6 (track focused line, highlight it, post messages on keypress). WKWebView focus interactions with SwiftUI can be tricky — the WKWebView needs to be first responder for keyboard events, which may conflict with SwiftUI keyboard shortcuts.

**Effort:** M
**Priority:** P3
**Depends on:** Diff Viewer V1 (PR4: comment system)

#### 10. Extract WorktreeManager from SessionStore

**What:** Extract worktree creation/deletion orchestration into a separate `WorktreeManager` class when SessionStore exceeds 2,500 lines.

**Why:** SessionStore.swift is ~1,600 lines and growing. It owns state, services, handlers, persistence, and multi-step async worktree pipelines. The worktree code is self-contained and testable in isolation.

**Context:** The worktree creation pipeline (`performCreateWorktree`, `performDeleteWorktree`) is multi-step async orchestration that talks to GitService and TmuxService but only writes back to SessionStore via `activeCreations`/`activeDeletions` dictionaries. Extraction is clean. The challenge is @Observable: child objects need to signal the parent for SwiftUI updates. Options: (a) make WorktreeManager @Observable and compose, (b) use callbacks, (c) use Combine publishers. Trigger: when SessionStore crosses 2,500 lines or a bug hides in the worktree pipeline complexity.

**Effort:** M
**Priority:** P3

#### 11. Multi-agent orchestration

**What:** Enable multiple agents to work together — either through automated chaining (agent A's output feeds agent B) or through agent teams that communicate with each other via shared context or message passing.

**Why:** Complex tasks benefit from decomposition across agents (e.g., one agent writes code, another reviews, a third writes tests). This is the natural evolution of a multi-worktree agent manager.

**Context:** Two possible directions: (a) orchestrated chains — user defines a pipeline and Nala drives each step sequentially; (b) agent teams — agents run concurrently and coordinate through a shared scratchpad or message bus. Option (a) is simpler to build and reason about. Option (b) is more powerful but needs careful UX to avoid chaos. Could start with (a) and graduate to (b).

**Effort:** L
**Priority:** P3

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
