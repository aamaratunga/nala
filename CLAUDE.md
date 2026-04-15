# CLAUDE.md — Nala

## Project Overview
**Nala** is a native macOS app for orchestrating AI coding agents (Claude) running in parallel git worktrees using tmux. It provides embedded terminals, real-time agent state tracking via file-based events, git state polling, session management, and a command palette for launching agents and worktrees.

## Project Structure
- `NalaApp/` — Main app source
  - `NalaApp.swift` — App entry point, migration logic
  - `Theme.swift` — Design system colors and gradients (`NalaTheme`)
  - `Models/` — Data models (Session, RepoConfig, launch/restart/creation states)
  - `Services/` — Core services (TmuxService, EventFileWatcher, GitService, NotificationManager, TerminalLauncher, AutoNamer)
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
/usr/bin/log stream --predicate 'subsystem == "com.nala.app"' --debug --info

# Filter by category (SessionStore, TmuxService, GitService, EventFileWatcher, etc.)
/usr/bin/log stream --predicate 'subsystem == "com.nala.app" AND category == "SessionStore"' --debug --info
```

### Reading historical logs

```bash
# Last 5 minutes
/usr/bin/log show --predicate 'subsystem == "com.nala.app"' --last 5m --debug --info

# Last 1 hour
/usr/bin/log show --predicate 'subsystem == "com.nala.app"' --last 1h --debug --info
```

### Console.app

Open `/Applications/Utilities/Console.app`, type `com.nala.app` in the search bar, and select "Subsystem" from the filter dropdown.

### Performance instrumentation

`SessionStore` emits `os_signpost` intervals on the Points of Interest log for `handleTmuxUpdate` and `reconcileOrder`. These are visible in Instruments.app (use the "Points of Interest" instrument). Timing warnings (>100ms for handleTmuxUpdate, >50ms for groupingPath) are logged at warning level automatically.

### Main-thread hang detection

`MainThreadWatchdog` (DEBUG builds only) pings the main thread every 2 seconds. If the main thread is unresponsive for >3 seconds, it logs an error under the `Watchdog` category.

**Important:** Critical events are written to `~/.nala/hang.log` via `PersistentLog`. This file survives force-quit — `os.Logger` entries are often lost because macOS unified logging is asynchronous and in-flight entries aren't flushed when a process is killed.

**What's in hang.log:**
- **Watchdog events** — hang detection, heartbeats (DEBUG only)
- **Operational breadcrumbs** — session launches, tmux session creation, launch failures, slow handleTmuxUpdate, slow terminal flushes (all builds)

The watchdog detects two classes of hang:
1. **Full block** (`MAIN THREAD HANG DETECTED`) — main thread completely unresponsive for >3s
2. **Busy-hung** (`MAIN THREAD OVERLOADED`) — main thread responds to pings but with >200ms dispatch latency, indicating run loop saturation that starves user events

**When a user reports a hang**, check the persistent hang log first:

```bash
cat ~/.nala/hang.log
```

Then check os.Logger (may be incomplete if force-quit):

```bash
/usr/bin/log show --predicate 'subsystem == "com.nala.app" AND category == "Watchdog"' --last 30m --debug --info
```

Look for:
- `MAIN THREAD HANG DETECTED` — main thread fully blocked, with duration
- `MAIN THREAD OVERLOADED` — main thread saturated (dispatch latency + streak count)
- `MAIN THREAD STILL HUNG` — ongoing full block with total duration
- `Main thread hang resolved after Xs` — how long a full block lasted
- `SESSION_LAUNCH` / `LAUNCH_TMUX_CREATED` / `LAUNCH_FAILED` — session lifecycle
- `LAUNCH_MAINACTOR_WAIT` — MainActor contention during launch
- `TMUX_UPDATE_SLOW` — handleTmuxUpdate exceeded 100ms
- `FLUSH_SLOW` — terminal data flush exceeded 50ms
- `APP_STARTED` — app startup marker

Then check os.Logger for additional detail (may be incomplete if force-quit):

```bash
# All Nala logs around the hang time (adjust --start/--end as needed)
/usr/bin/log show --predicate 'subsystem == "com.nala.app"' --last 30m --debug --info
```

Look for timing warnings from `handleTmuxUpdate`, `reconcileOrder`, `startWatching`, `performLaunch`, `groupingPath` — these fire when operations exceed their thresholds. The hang is caused by whatever was running on the main thread at the time.

**Prior hang root causes (all fixed):**
- `watcherQueue.sync` called from main thread (deadlock) — fixed in 4d24a26
- `NSAlert.runModal()` blocking main run loop — fixed in 4d24a26
- Reading entire multi-MB event files on main thread — fixed in 8aa2136
- PulseParser CPU saturation on multi-MB tmux logs — fixed in 3d9062e
- Hidden terminals causing expensive draw cycles — fixed in 3d9062e; **structurally eliminated** by single-view architecture (only one terminal view exists at a time, destroyed on session switch)
- EventFileWatcher.startWatching file I/O on main thread — moved to background queue
- Unbounded `pendingBytes` in NalaTerminalView — **structurally eliminated** by single-view architecture (no hidden terminals accumulate data; view is destroyed on session switch, `tmux attach` replays ~4-8KB on reconnect)
- `performStartupCleanup` directory listing + file deletion on main thread — moved to background Task
- Large `flushPendingData` buffers (100-250KB) blocking main thread for 500-800ms — fixed by chunked drain (16KB per run-loop iteration)
- `performWorktreeDeletion`/`performWorktreeCreation` mutating `@Observable` state from background tasks without MainActor — data race crash (not a hang; watchdog won't fire). Fixed by wrapping all state mutations in `await MainActor.run { }`.

**Pattern:** Prior hangs were synchronous I/O or blocking calls on the main thread ("full block" — watchdog detects these). A new pattern was identified: "busy-hung" where the main thread is saturated with run-loop work items (e.g., terminal data drain chunks) — the watchdog semaphore ping gets serviced between items, but user events are starved, causing an unresponsive UI that the old watchdog missed. Dispatch latency detection (`MAIN THREAD OVERLOADED`) now catches this pattern.

Prior crashes were `@Observable` data races (background task mutations without MainActor). If a new issue appears, check for both hang patterns (full block and busy-hung) and data races. When adding new async pipelines, follow the `performRestart`/`performLaunch` pattern: keep process execution on background tasks, dispatch all `@Observable` mutations to `MainActor.run`.

### Log categories

Each service logs under its own category:
- `SessionStore` — session lifecycle, polling, errors, performance warnings
- `TmuxService` — tmux process execution, session creation/deletion
- `GitService` — git commands, worktree operations
- `EventFileWatcher` — JSONL event file watching
- `Terminal` — PTY data flushing, flush timing
- `TerminalLauncher` — external terminal attachment
- `AutoNamer` — AI-based session naming
- `Watchdog` — main-thread hang detection (DEBUG only); also writes to `~/.nala/hang.log`

### Log levels

- **debug** — verbose (only visible with `--debug` flag)
- **info** — normal operations (session created, watcher started)
- **warning** — performance issues, non-fatal problems
- **error** — failures (launch errors, alert triggers)

Debug and info are ephemeral (macOS may discard quickly). Warning and error persist longer.

## Conventions
- Bundle ID: `com.nala.app`
- Logger subsystem: `"com.nala.app"`
- UserDefaults keys: `nala.*` prefix
- Events directory: `~/.nala/events/`
- Color properties (`coralPrimary`, `coralLight`, etc.) describe the hue #FF6B52, not the old product name
