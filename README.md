# Nala (Not Another LLM App)

Native macOS app for orchestrating AI coding agents in parallel git worktrees.

## What it does

Nala gives you a mission control interface for managing multiple AI coding agents (Claude) running simultaneously across git worktrees. Each agent runs in its own tmux session with an embedded terminal, and Nala tracks their state in real time.

- Embedded terminals via SwiftTerm — no external terminal needed
- Real-time agent state tracking (working, waiting for input, done, stuck)
- Git worktree management — create, delete, and monitor worktrees
- Command palette for launching agents, terminals, and worktrees
- Session naming via Claude CLI (auto-names from activity)
- System notifications when agents need input or finish

## Requirements

- macOS 15.0+
- [tmux](https://github.com/tmux/tmux) (`brew install tmux`)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) for AI agents
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) for building from source

## Building from source

```bash
git clone https://github.com/aamaratunga/nala.git
cd nala
xcodegen generate
xcodebuild build -project NalaApp.xcodeproj -scheme NalaApp -destination 'platform=macOS'
```

## Running tests

```bash
xcodebuild test -project NalaApp.xcodeproj -scheme NalaApp -destination 'platform=macOS'
```

## How it works

Nala is fully local with zero network dependencies:

1. **Tmux polling** — discovers and monitors agent sessions via `tmux list-sessions`
2. **Event file watching** — Claude Code hooks write JSONL events to `~/.nala/events/`; Nala watches these files for state changes
3. **Git polling** — tracks branch names and dirty file counts per worktree
4. **Pulse parsing** — reads `||PULSE:STATUS||` and `||PULSE:SUMMARY||` markers from agent output

## License

Apache 2.0
