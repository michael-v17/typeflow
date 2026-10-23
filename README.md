# TypeFlow

> **v0.1** · Native macOS text intelligence — autocorrect, inline word completion, grammar, Writing Tools, dictation — when you write prompts to **Claude Code in Warp**.

Terminal emulators don't use `NSTextView`, so they bypass Apple's writing stack. TypeFlow is a small floating composer that gives you the full Apple text experience, then hands your prompt to **Warp's Rich Input** editor — which pastes and submits it into the focused `claude` session natively. No copy/paste. No clipboard hijack (the pasteboard is saved and restored).

See [`docs/vision.md`](docs/vision.md) for the rationale, [`CLAUDE.md`](CLAUDE.md) for the architecture, and [`docs/status.md`](docs/status.md) for the current state.

---

## Features

- **Apple text intelligence** in the composer — autocorrect, continuous spellcheck, grammar, text replacement, Writing Tools. Smart quotes/dashes are **off** on purpose so `"strings"` and `--flags` in your prompts aren't mangled.
- **Inline word completion** — finishes the word you're typing (`becom` → `become`) as gray ghost text via the system dictionary (instant, local, English + Spanish auto-detected). **Tab** accepts.
- **Contraction autocorrect** — `dont` → `don't`, `im` → `I'm`, lone `i` → `I`, on word boundary. A small curated map, so code tokens aren't touched.
- **Sentence starts capitalized** — `give me` → `Give me`, `done. it works` → `done. It works`, and `i'm` / `i've` / `i'll` / `i'd` → `I'm`…, once the word is typed. Only a plain lowercase word, so `--force`, `readme.md` or `iOS` stay as typed; not after `e.g.`, `etc.`, `...` or `:`; ⌘Z undoes it.
- **Apple dictation** — a mic button (and your system dictation shortcut) dictate straight into the composer.
- **Keep-open mode** (default on) — Enter sends but leaves the composer open and focused for rapid multi-send.
- **Multi-session aware** — a footer picker lists every `claude` session (PascalCase names). The composer **follows the focused Warp tab** and keeps a **separate draft per session**, so switching tabs never loses what you typed.

---

## Requirements

- **macOS 26 (Tahoe) or newer.** The build links Apple's `FoundationModels` framework (for a dormant on-device phrase-completion mode), which pins the deployment target to macOS 26.
- **Warp**, with `claude` running in at least one tab.
- **Accessibility permission** (required) — used to send keystrokes into Warp's Rich Input and to read which tab is focused. Granted on first launch.
- **Microphone permission** (optional) — only if you use dictation. Prompted on first use.
- Swift toolchain from current Xcode / Command Line Tools.

---

## Install

The proper way (a real, signed `/Applications` app you can Spotlight-search and auto-launch):

```bash
git clone https://github.com/michael-v17/typeflow.git
cd typeflow

# 1. one-time: a stable self-signed code-signing identity, so macOS keeps your
#    Accessibility/Microphone grants across rebuilds (click "Always Allow" on
#    the first build's codesign prompt).
./scripts/make-cert.sh

# 2. build the icon + the signed .app, then install it
./scripts/make-icon.sh
./scripts/make-app.sh release
cp -R TypeFlow.app /Applications/
open /Applications/TypeFlow.app
```

On first launch, grant **Accessibility** (System Settings → Privacy & Security → Accessibility → TypeFlow), and **Microphone** the first time you dictate. To launch it automatically, add `/Applications/TypeFlow.app` to **System Settings → General → Login Items**.

**Dev mode** (quick iteration, no bundle):

```bash
swift run TypeFlow
```

Note: as a bare binary this won't have dictation or persistent permissions — use the `.app` for real use.

---

## Use it

| Action | Shortcut |
|---|---|
| Open / close composer | **⌥Space** |
| Send prompt to `claude` | **↵** (Enter) |
| New line | **⇧↵** (Shift + Enter) |
| Accept inline suggestion | **⇥** (Tab) |
| Dismiss suggestion / close composer | **⎋** (Escape) |
| Dictate | the **🎙** button (or your system dictation shortcut) |

The footer shows the targeted session (e.g. `claude · TypeFlow`), the **keep open** toggle, the mic button, and the hotkey hints. Sending always targets Warp's **frontmost** tab — so switch sessions by clicking the Warp tab (the composer follows it).

---

## How it works

```
⌥Space → compose with Apple text intelligence → ↵
                       │
                       ▼
          WarpInjector (needs Accessibility):
            activate Warp
            ⌃G  open Rich Input
            ⌘V  paste the prompt
            ↵   submit  → claude
            pasteboard restored
```

The composer follows the focused Warp tab by reading its window title via the Accessibility API (`WarpInspector`) and matching it to a detected `claude` session.

### Source layout

| File | Responsibility |
|---|---|
| `App.swift` | Lifecycle, ⌥Space hotkey, menu bar, launch-time Accessibility prompt |
| `ComposerWindow.swift` | The floating composer, footer, keyboard handling, Warp tab-follow + per-session drafts |
| `GhostTextView.swift` | Draws the gray inline suggestion (kept out of the text buffer) |
| `WordCompleter.swift` | Current-word completion via `NSSpellChecker` |
| `ContractionCorrector.swift` | Apostrophe fixes (`dont`→`don't`) + `i`→`I`, and sentence starts / `i'm` capitalized |
| `GhostCompleter.swift` | **Dormant** — on-device Foundation Models phrase completion (kept for a future toggle) |
| `WarpInjector.swift` | The send path — keystroke synthesis into Warp's Rich Input |
| `WarpInspector.swift` | Reads Warp's focused-window title for session-following |
| `ProcessWatcher.swift` | `libproc` detection of `claude` sessions (adaptive polling) |
| `HotKey.swift` | Carbon ⌥Space registration |
| `PTYWriter.swift` | **Legacy** — the old PTY-write path, not used |

### Build helpers (`scripts/`)

| Script | Purpose |
|---|---|
| `make-cert.sh` | Create the stable self-signed code-signing identity (run once) |
| `make-icon.sh` | Render the app icon → `Resources/AppIcon.icns` |
| `make-app.sh` | Build + bundle + sign `TypeFlow.app` |
| `render-icon.swift` | The icon drawing code |

---

## Status — v0.1

Works end-to-end on macOS 26: composing with Apple text intelligence, word completion, contraction autocorrect, dictation, per-session drafts with live Warp-tab following, and submission into Warp's Rich Input. Packaged as a signed, installable, login-launchable app.

### Known limits (tracked in [`CLAUDE.md`](CLAUDE.md))

- **Routing is frontmost-tab.** The dropdown swaps the draft but doesn't switch the Warp tab, so to send to a specific session you click its Warp tab. Picker-driven tab switching (AX traversal) is the next step.
- **Foundation Models phrase mode is dormant** — word completion is the active engine; the on-device LLM continuation is wired but not enabled.
- **Claude Code + Warp only.** Other agents/terminals are out of scope (Warp's Rich Input is the integration point — see Warp issue #8579).
- **Self-signed.** The app is locally signed; fine for personal use, not distribution.

---

## Why this exists

If you spend hours a day writing prose-heavy prompts to Claude Code, doing it in a terminal that bypasses Apple autocorrect is friction you stop noticing but never stop paying. Safari, Notes, Mail, the ChatGPT app — all give you the full Apple writing stack. Your terminal, where you do the most language-dense work in your day, gives you nothing. TypeFlow gives that stack back, scoped to the moments you're talking to an AI agent.

---

## License

TBD.
