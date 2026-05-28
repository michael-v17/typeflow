# TypeFlow

> Native macOS text intelligence — autocorrect, predictive typing, grammar, Writing Tools — when you write prompts to **Claude Code in Warp**.

Terminal emulators don't use `NSTextView`, so they bypass Apple's writing stack. TypeFlow fixes that by giving you a small floating composer with the full Apple text experience, then writing your prompt directly into the target `claude` session's PTY. No copy/paste. No focus juggling. No clipboard hijack.

See [`docs/vision.md`](docs/vision.md) for the long-form rationale and [`CLAUDE.md`](CLAUDE.md) for the architecture decision and scope.

---

## Requirements

- macOS 14 or newer (tested on macOS 26)
- Swift 5.9 toolchain (ships with current Xcode / Command Line Tools)
- Warp (or any terminal that exposes a `/dev/ttysNNN`) with `claude` running in at least one session

No special entitlements or permissions needed — TypeFlow writes to the target PTY using standard POSIX `open` + `write`, which any process can do.

---

## Quick start

### 1. Build

```bash
git clone https://github.com/michael-v17/typeflow.git
cd typeflow
swift build
```

### 2. Run

```bash
swift run TypeFlow
```

Or, after building once, launch the binary directly:

```bash
.build/debug/TypeFlow &
```

You should see a **keyboard** icon in the menu bar.

### 3. Use it

| Action | Shortcut |
|---|---|
| Open / close composer | **⌥Space** (Option + Space) |
| Send prompt to `claude` | **⌘↵** (Cmd + Return) |
| Add a new line in the composer | **↵** (Return) |
| Close without sending | **⎋** (Escape) |

The footer shows which `claude` session the composer is targeting, e.g.:

```
→ claude (pid 47281 · ttys003)         ⌘↵ send   ⎋ close
```

If no `claude` process is running, the footer says `→ no Claude Code session` and ⌘↵ does nothing (beeps).

### 4. Stop

Three ways, easiest first:

```bash
# 1. From the menu bar: click the keyboard icon → "Quit TypeFlow"

# 2. From the terminal:
pkill -f TypeFlow

# 3. If you launched with `swift run`, foreground it and Ctrl-C
```

---

## How it works

```
┌─ NSPanel (borderless, translucent, .hudWindow vibrancy) ──┐
│  NSTextView                                               │
│    - continuous spellcheck                                │
│    - auto-correction + auto-replacement                   │
│    - predictive completion                                │
│    - grammar checking                                     │
│    - Writing Tools (macOS 15+)                            │
└───────────────────────────────────────────────────────────┘
                         │
                         │  ⌘↵
                         ▼
   ProcessWatcher  ──→ finds running `claude` processes via libproc
                       picks most recently started (v1 heuristic)
                         │
                         ▼
   PTYWriter       ──→ open("/dev/ttysNNN", O_WRONLY | O_NOCTTY)
                       write(fd, text + "\n")
                         │
                         ▼
              Warp shows the prompt appear as if typed
```

### Source layout

| File | Responsibility |
|---|---|
| `Sources/TypeFlow/App.swift` | App entry, menu bar item, lifecycle |
| `Sources/TypeFlow/ComposerWindow.swift` | The translucent floating composer (`NSPanel` + `NSTextView`) |
| `Sources/TypeFlow/HotKey.swift` | Global ⌥Space registration via Carbon |
| `Sources/TypeFlow/ProcessWatcher.swift` | Polls `libproc` for live `claude` processes |
| `Sources/TypeFlow/PTYWriter.swift` | POSIX write to the target tty |

---

## Status

Spike — works end-to-end on macOS 26.

### What works
- ⌥Space global hotkey, no permission prompts
- Native translucent composer with all Apple text intelligence enabled
- Live detection of `claude` processes
- Direct PTY write into the target session

### Known limits (tracked in [`CLAUDE.md`](CLAUDE.md))
- **Multi-session routing** uses "most recently started" — not yet the frontmost-Warp-window. Fine for most cases; AX-based mapping is a planned follow-up.
- **No `.app` bundle yet** — runs as a plain SPM executable. Wrap later for login-launch / signing.
- **Claude Code only.** Codex, Hermes, Aider, etc. are out of scope for v1 (the architecture generalizes — just a process-name allowlist).

---

## Why this exists

If you spend hours a day writing prose-heavy prompts to Claude Code, doing it in a terminal that bypasses Apple autocorrect is friction you stop noticing but never stop paying. Safari, Notes, Mail, even the ChatGPT app give you the full Apple writing stack. Your terminal — where you do the most language-dense work in your day — gives you nothing.

TypeFlow gives you that stack back, scoped strictly to the moments you're talking to an AI agent.

---

## License

TBD.
