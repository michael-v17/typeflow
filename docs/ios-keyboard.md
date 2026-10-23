# TypeFlow on iPhone — iOS keyboard (parked)

**Status:** parked 2026-10-22; the owner may pick it up later. Research only; nothing built.

**Question:** how hard is a first TypeFlow for iPhone as a keyboard, using the iPhone's own model and/or an external service?

**Answer:** about 1–2 weeks to a usable personal v1, as long as it doesn't try to replace Apple's typing. A full typing keyboard (own autocorrect, swipe, predictions) is months, and not worth it.

## Why not a full typing keyboard

A custom keyboard replaces Apple's keyboard entirely: Apple's autocorrect, predictions, swipe typing and dictation are gone. No app extension can use the microphone, so dictation is impossible inside a custom keyboard. Same trade-off as the macOS input-method route we rejected (see `CLAUDE.md` → decisions).

## Recommended v1: an "action keyboard"

- Type with Apple's keyboard as usual, tap 🌐 to switch to TypeFlow: it shows only buttons — **Fix** (like ⌥⌘K), **Translate** (EN↔ES), **Undo**, and 🌐 to switch back.
- Read: the keyboard's `textDocumentProxy` gives the selected text (`selectedText`) or the text around the cursor (`documentContextBeforeInput`). How much text an app exposes varies; a chat message is fine.
- Replace: delete that text (`deleteBackward()`) and insert the correction (`insertText`). With a selection, inserting replaces it.
- Translate: Apple Translation runs on iPhone too (same as `Translator.swift`).
- Apple already offers Writing Tools → Proofread on selected text. TypeFlow's edge: one tap, the coach prompt (natural US English, Spanish → English in place), translation.

## Model options

| | iPhone's own model (Foundation Models, on-device) | External service (Claude / OpenAI API) |
|---|---|---|
| Cost | Free, offline | Pay per check. Haiku 5.5 ≈ $0.001/check (`docs/coach-benchmark.md`). The Codex/Claude plan logins (CLIs) don't exist on iPhone → API key |
| Needs | iPhone 15 Pro or newer, Apple Intelligence on, a supported device language | "Allow Full Access" (network); iOS warns the keyboard can send what you type |
| Quality | `docs/coach-benchmark.md` (2026-10-07) disqualified it for coaching: slang rewrites, 95/100 on broken drafts, changed meaning. WWDC26 says the system model was rebuilt (better instruction following) → re-run the bench before trusting it | Same as the Mac coach |
| Unknown | Whether it runs inside a keyboard extension at all — no confirmation found | — |

Also from WWDC26 (session 339): Foundation Models now reaches Apple's Private Cloud Compute model (reasoning, 32K context), and Anthropic and Google said they'll ship packages so Claude and Gemini use the same API. Could make on-device ↔ external a one-line switch. Availability and pricing not checked.

## Keyboard-extension limits

- ~60 MB memory ceiling; over it, iOS kills the keyboard silently (no crash log) and switches back to the previous keyboard. Fine for buttons + a network call; rules out a local model (MLX) inside the keyboard.
- Network, shared container with the app, etc. only with Full Access (`RequestsOpenAccess` in the keyboard's Info.plist + the user's switch in Settings).
- Password fields and phone pads always use Apple's keyboard.

## Path when we pick it up

1. **Spike (1–2 days):** keyboard target with one Fix button → coach prompt over the network → replace text in Notes, WhatsApp, Safari. Day 1: check whether `SystemLanguageModel` works inside the keyboard extension.
2. **v1 (1–2 weeks):** Fix, Translate, Undo, EN/ES; a small settings app (API key in a shared Keychain, provider choice, Full Access onboarding).
3. **Cheaper alternative (~half a day):** a Shortcut / App Intent "Fix clipboard" on Back Tap (double-tap the back of the iPhone): copy → tap → paste. The Mac clipboard flow, no keyboard at all.

Open: which iPhone the owner has (on-device needs a 15 Pro or newer); whether checks should reach wingman-english's log from the phone.

## Sources (accessed 2026-10-22)

- Apple — Configuring open access for a custom keyboard: https://developer.apple.com/documentation/uikit/configuring-open-access-for-a-custom-keyboard
- Apple — Foundation Models: https://developer.apple.com/documentation/foundationmodels
- WWDC26 session 339, "Bring an LLM provider to the Foundation Models framework": https://developer.apple.com/videos/play/wwdc2026/339
- Apple Developer Forums — model availability depends on Apple Intelligence and device language: https://developer.apple.com/forums/thread/805378
- "The three hard constraints of an iOS keyboard extension" (~60 MB, measured): https://dev.to/tbds_2dadf2b626f315902eae/the-three-hard-constraints-of-an-ios-keyboard-extension-46af
- MacStories — no microphone in keyboard extensions (2016; its "no selected text" point is outdated, `selectedText` came in iOS 11): https://www.macstories.net/notes/on-the-limitations-of-ios-custom-keyboards
- HackerNoon — device requirement (A17 Pro / iPhone 15 Pro and newer): https://hackernoon.com/a-developers-guide-to-apples-foundation-models-framework-in-ios-26
