# ⌘K coach — provider benchmark

Which model should run the ⌘K English coach? Measured 2026-10-07, the day Claude Haiku 5.5 shipped.
Rerun when a new model ships or a provider changes its CLI.

**Decision: keep `gpt-6-luna` (Codex, ChatGPT plan) as the default and `gpt-6-sol` as ⌘K-again.**
No Apple provider. **Update 2026-10-08:** a Claude fallback was added for when the Codex budget
runs low — menu bar → ⌘K Coach → a Claude account. The owner picked Haiku 5.5 at medium for the quick
check (Sonnet 5.5 low for ⌘K again); Luna stays the default.

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
