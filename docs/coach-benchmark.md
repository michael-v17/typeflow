# ⌘K coach — provider benchmark

Which model should run the ⌘K English coach? Measured 2026-10-07, the day Claude Haiku 5.5 shipped.
Rerun when a new model ships or a provider changes its CLI.

> [!NOTE]
> The drafts are withheld: the inputs (`sentences.json`, `translate.json`) and the raw outputs
> (`results-*.json`) hold real practice text, so they aren't in this repo, and the draft fragments
> quoted below are paraphrased. To rerun, put your own drafts in `scripts/coach-bench/sentences.json`
> (and `translate.json` for `--set translate`) as a JSON array of strings.

**Decision: keep `gpt-6-luna` (Codex, ChatGPT plan) as the default and `gpt-6-sol` as ⌘K-again.**
No Apple provider. **Update 2026-10-08:** a Claude fallback was added for when the Codex budget
runs low — the composer's `⌘K` picker → a Claude account (or Antigravity · Gemini 3.8 Flash, spot-checked: 10–25 s, same miss on the broken question). The owner picked Haiku 5.5 at medium for the quick
check (Sonnet 5.5 low for ⌘K again); Luna stays the default.

## 2026-10-26 — GPT-6.1 Terra

**Decision: add `gpt-6.1-terra` at medium effort as a second Codex row in the ⌘K picker; Luna stays the default.**
Terra is the better pick when you write mostly in Spanish. ⌥⌘T stays on Apple Translation.

Same `codex exec` flags as Luna (effort low). Runs: the 4 English drafts × 3, and 5 real Spanish drafts
from `corpus/typeflow/` (`translate.json`) × 2. Luna and Terra ran at the same time. Raw output:
`results-2026-10-26-{luna-terra,terra-medium}.json`, `results-2026-10-26-translate-{luna-terra,terra-medium}.json`. Rerun:
`python3 -I scripts/coach-bench/bench.py luna terra terra-medium` and `… --set translate luna terra terra-medium`.

| | Median s | Tokens in (cached) / out (thinking) | API $/check | Avg score |
|---|---|---|---|---|
| Luna, English | 6.2 | 5.2k (0) / 0.27k (0) | 0.0005 | 81 |
| Terra low, English | 6.4 | 5.2k (4.9k) / 0.28k (0) | 0.0033 | 76 |
| Terra medium, English | 6.5 | 5.2k (2.4k) / 0.41k (43) | 0.0049 | 76 |
| Luna, Spanish | 5.1 | 5.2k (0) / 0.13k (0) | 0.0005 | — |
| Terra low, Spanish | 5.5 | 5.2k (4.9k) / 0.14k (0) | 0.0031 | — |
| Terra medium, Spanish | 5.3 | 5.2k (4.9k) / 0.20k (49) | 0.0029 | — |

- **Cost.** API list prices per 1M tokens: Luna $0.10 in / $0.01 cached / $0.50 out; Terra
  $1 / $0.05 / $5 (Terra launched 2026-10-26). So a Terra check costs about 6–10× a Luna check,
  still well under a cent. Medium adds only ~60 output tokens; how much of the input is cached
  changes the cost more. On the ChatGPT plan there's no bill, only allowance. How the plan counts
  each model wasn't checked; assume it tracks the API price.
- One Luna run and one Terra low run each stalled at ~100 s at the same moment (none at medium), so
  that was the network or service, not the model.
- **Medium vs low:** about the same speed. Medium thinks only ~45 tokens. English: no better
  (1 of 4 drafts improved: a plainer modal verb). Spanish: it got names right that low
  mangled (a loosely written model name → "GPT-6 Luna", 2/2), and it kept low's meaning wins. Medium is the
  setting used.

- **English coaching: Luna is still better.** Terra makes smaller edits and leaves Spanish-shaped phrasing in place: a calqued opener, a hedged
  modal, a word-for-word question, an intensifier that doesn't fit. Luna rewrote each one
  idiomatically, the rewrites the coach is meant to teach. Terra did add one fix Luna missed (a
  product name's capitalization).
- **Spanish → English: Terra keeps the meaning better; Luna sounds more natural.** (Terra medium does both.)
  - A draft that agrees to a plan and gives the reason: Terra kept it as agreement plus reason both
    times. Luna turned it into a conditional ("if you build it…") both times, the same wrong reading
    as the one already in the corpus.
  - Messy dictated text: Terra kept the meaning. One Luna run changed what the sentence was about.
  - Luna knows names and English words better: a loosely written model name → "GPT-6 Luna" (Terra:
    "GPT Luna 6"), and the Spanish word for "spell checker" translated (Terra kept the Spanish word).
- **Apple Translation (⌥⌘T), same 5 drafts** (`apple-translate.swift`): word-for-word and wrong
  twice: a short git instruction came out word-for-word, and a one-letter typo in a Spanish verb
  became an unrelated English noun. Still, it takes ~1 s (the first call was cold and run alongside
  Codex), it's free, it works offline, and it goes both ways (EN ↔ ES). The coach only goes into English.
  Picking Terra already gives an LLM translation without new code: ⌥⌘K (quick fix) on Spanish
  text translates it with the selected model.
- Small sample (5 Spanish drafts, 2 runs each). Rerun with more drafts before making Terra the
  default for anything.

## Method

- 4 real drafts from `corpus/typeflow/` (`scripts/coach-bench/sentences.json`): two typed with
  Spanish-shaped phrasing, one broken question, one dictated paragraph. 3 runs each.
- Every provider got the same `coach.md` prompt and `schema.json` (from
  `~/Library/Application Support/TypeFlow/coach/`), called the way TypeFlow would call it:
  - **Codex**: `EnglishCoach.swift`'s exact `codex exec` flags (lean, `model_reasoning_effort=low`), `--json` for usage.
  - **Claude**: `claude -p --model … --system-prompt coach.md --json-schema schema.json --tools ""
    --strict-mcp-config --settings '{"disableAllHooks":true}' --disable-slash-commands
    --no-session-persistence --output-format json`. Subscription (OAuth) auth, no API key.
    Hooks off so wingman-english's capture never stores the test drafts.
  - **Apple**: `FoundationModels` on-device, `coach.md` as instructions, `@Generable` output (`apple.swift`).
- Like-for-like tiers: Haiku 5.5 ↔ Luna (fast), Sonnet 5.5 ↔ Sol (deep).
- All 7 setups ran concurrently (inflates latency a little for everyone). Raw outputs:
  `scripts/coach-bench/results-2026-10-07.json`. Rerun: `python3 -I scripts/coach-bench/bench.py`.

## Results

| Setup | Median s | Tokens in / out (thinking) | Avg score | Score spread |
|---|---|---|---|---|
| **Luna** | **5.7** | 5.2k / 0.3k (0) | 80 | ±1.7 |
| Haiku 5.5 low | 8.2 | 2.3k / 1.7k (1.0k) | 68 | ±3.9 |
| Haiku 5.5 medium | 10.9 | 2.7k / 2.5k (1.7k) | 67 | ±4.6 |
| Haiku 5.5 default | 12.3 | 2.3k / 2.5k (1.8k) | 67 | ±3.3 |
| Sonnet 5.5 low | 5.2 | 2.3k / 0.7k (0) | 68 | ±1.1 |
| Sol | 11.5 | 5.2k / 0.4k (0) | 72 | ±4.0 |
| Apple on-device | 10.4 | — (free, offline) | 92 | ±2.2 |

Haiku 5.5 run alone (not concurrent): 6.6–8.3 s. It still thinks ~1k tokens at `--effort low`, and
`MAX_THINKING_TOKENS=0` / `alwaysThinkingEnabled:false` don't turn that off through `claude -p`.
An earlier solo pair of runs (same day) took 3.4–5.1 s — launch-day load may be a factor.

## Quality (every output read)

- **Luna — best.** Made the key fixes every run: a calqued verb phrase became "expand", an awkward size
  phrase became "way too few", and a broken yes/no question became a clean one.
- **Haiku 5.5 — clearly worse than Luna, at every effort.** Kept the broken question in 8/9 runs; sometimes kept the awkward size phrase; flipped who
  asks for the prompt once. More effort = slower, not better.
- **Sonnet 5.5 low** — as fast as Luna, most consistent, but the same miss on the broken question.
- **Sol** — close to Luna, twice as slow. Fine as the opt-in deeper check.
- **Apple — disqualified.** Slang rewrites ("we gotta beef up this list", "help me level up"), 95/100
  on broken drafts, changed meaning ("I could ping you with a prompt"). Keep it for live underlines only.

## Cost

- On the owner's plans none of these adds a bill — each check spends plan allowance.
- API list price, as reported by `claude -p`: Haiku 5.5 ≈ $0.001/check (~$1 per 1,000),
  Sonnet 5.5 ≈ $0.01/check. Luna's API price wasn't verified; on the ChatGPT plan it uses ~5k input
  (about half cached) and ~0.3k output tokens per check.
- At this volume cost doesn't decide it; quality does.

## Notes for the next run

- `claude --bare` is the leanest mode but only accepts `ANTHROPIC_API_KEY` — not subscription auth.
- `claude -p` was available in Claude Code 2.1.293 with subscription auth.
- Picking one of the two Claude accounts = set `CLAUDE_CONFIG_DIR` for the subprocess.
- Judge the outputs, not the self-reported `score` — Apple's 92 average was the worst quality.
