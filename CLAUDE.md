# CLAUDE.md — Nala

## Project Overview
**Nala** is a native macOS app for orchestrating AI coding agents (Claude) running in parallel git worktrees using tmux. It provides embedded terminals, real-time agent state tracking via file-based events, git state polling, session management, and a command palette for launching agents and worktrees.

## Project Structure
- `NalaApp/` — Main app source
  - `NalaApp.swift` — App entry point, migration logic
  - `Theme.swift` — Design system colors and gradients (`NalaTheme`)
  - `Models/` — Data models (Session, RepoConfig, launch/restart/creation states)
  - `Services/` — Core services (TmuxService, EventFileWatcher, GitService, PulseParser, NotificationManager, TerminalLauncher, AutoNamer)
  - `Stores/` — Observable state (`SessionStore`)
  - `Tools/` — Utilities (PathFinder)
  - `Views/` — SwiftUI views (ContentView, CommandPaletteView, SessionDetailView, SessionListView, SettingsView, etc.)
- `NalaAppTests/` — Unit tests
- `project.yml` — XcodeGen project spec
- `DESIGN.md` — Design system (colors, typography, spacing, motion)

## Key Commands

### Build
```bash
xcodegen generate
xcodebuild build -project NalaApp.xcodeproj -scheme NalaApp -destination 'platform=macOS'
```

### Test
```bash
xcodebuild test -project NalaApp.xcodeproj -scheme NalaApp -destination 'platform=macOS'
```

### Regenerate Xcode Project
```bash
xcodegen generate
```

### Release

To publish a new version:

1. Update `MARKETING_VERSION` in `project.yml` (e.g., `"1.2.0"`)
2. Commit, merge to `main`
3. Tag and push:
   ```bash
   git tag v1.2.0
   git push origin v1.2.0
   ```

The `release.yml` workflow will automatically:
- Build an arm64 Release binary
- Create a DMG with Applications symlink
- Sign the DMG for Sparkle auto-updates (using `SPARKLE_EDDSA_KEY` repo secret)
- Create a GitHub Release with the DMG and appcast.xml

**Version scheme:** `MARKETING_VERSION` (semver from tag) is the user-facing version. `CURRENT_PROJECT_VERSION` (YYYYMMDD, auto-generated in CI) is the build number Sparkle uses to detect upgrades.

**Signing:** Currently ad-hoc. See TODOS.md for Developer ID + notarization plan.

## Architecture
- **No network dependencies** — all state comes from local tmux polling + file watching
- **Event system** — Claude Code hooks write JSONL events to `~/.nala/events/{session-id}.jsonl`; `EventFileWatcher` reads them
- **Tmux integration** — `TmuxService` polls for sessions, launches agents, injects hooks into Claude settings
- **Git state** — `GitService` polls worktree branches and dirty file counts
- **State management** — `SessionStore` is the single source of truth, consumed via SwiftUI `@Environment`

## Design System
Always read DESIGN.md before making any visual or UI decisions.
All font choices, colors, spacing, and aesthetic direction are defined there.
Do not deviate without explicit user approval.

## App Logs

Nala uses macOS Unified Logging (`os.Logger`) with subsystem `"com.nala.app"`. Logs are not written to a file. They go to the system log and can be read with Console.app or the `log` CLI.

### Reading logs in real time

```bash
# All Nala logs
log stream --predicate 'subsystem == "com.nala.app"' --level debug

# Filter by category (SessionStore, TmuxService, GitService, EventFileWatcher, PulseParser, etc.)
log stream --predicate 'subsystem == "com.nala.app" AND category == "SessionStore"' --level debug
```

### Reading historical logs

```bash
# Last 5 minutes
log show --predicate 'subsystem == "com.nala.app"' --last 5m --level debug

# Last 1 hour
log show --predicate 'subsystem == "com.nala.app"' --last 1h --level debug
```

### Console.app

Open `/Applications/Utilities/Console.app`, type `com.nala.app` in the search bar, and select "Subsystem" from the filter dropdown.

### Performance instrumentation

`SessionStore` emits `os_signpost` intervals on the Points of Interest log for `handleTmuxUpdate` and `reconcileOrder`. These are visible in Instruments.app (use the "Points of Interest" instrument). Timing warnings (>100ms for handleTmuxUpdate, >50ms for groupingPath) are logged at warning level automatically.

### Log categories

Each service logs under its own category:
- `SessionStore` — session lifecycle, polling, errors, performance warnings
- `TmuxService` — tmux process execution, session creation/deletion
- `GitService` — git commands, worktree operations
- `EventFileWatcher` — JSONL event file watching
- `PulseParser` — log file pulse parsing
- `TerminalLauncher` — external terminal attachment
- `AutoNamer` — AI-based session naming

### Log levels

- **debug** — verbose (only visible with `--level debug` flag)
- **info** — normal operations (session created, watcher started)
- **warning** — performance issues, non-fatal problems
- **error** — failures (launch errors, alert triggers)

Debug and info are ephemeral (macOS may discard quickly). Warning and error persist longer.

## Conventions
- Bundle ID: `com.nala.app`
- Logger subsystem: `"com.nala.app"`
- UserDefaults keys: `nala.*` prefix
- Events directory: `~/.nala/events/`
- Log paths: `/tmp/nala_{agent}_{folder}.log`
- Color properties (`coralPrimary`, `coralLight`, etc.) describe the hue #FF6B52, not the old product name
