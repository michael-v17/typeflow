#!/usr/bin/env python3
"""TypeFlow coach benchmark: same prompt + schema, each provider called the way TypeFlow would."""
import json, subprocess, sys, time, os, tempfile
# Usage: python3 -I scripts/coach-bench/bench.py [config ...]   (default: all configs)
# Apple runner: swiftc -O scripts/coach-bench/apple.swift -o /tmp/tf-bench-apple
# Writes results-<configs>.json next to this file. Hooks are off for claude -p, so
# wingman-english never stores the test drafts as the learner's writing.
from concurrent.futures import ThreadPoolExecutor

COACH = os.path.expanduser("~/Library/Application Support/TypeFlow/coach")
PROMPT = open(f"{COACH}/coach.md").read()
SCHEMA = open(f"{COACH}/schema.json").read()
HERE = os.path.dirname(os.path.abspath(__file__))
SENTS = json.load(open(f"{HERE}/sentences.json"))
RUNS = 3

def codex_disable():
    out = subprocess.run(["codex", "features", "list"], capture_output=True, text=True).stdout
    args = []
    for line in out.splitlines():
        c = line.split()
        if c and c[-1] == "true" and c[0] != "code_mode_host":
            args += ["--disable", c[0]]
    return args
DIS = codex_disable()

def run_codex(model, text):
    with tempfile.TemporaryDirectory() as d:
        out = f"{d}/o.json"
        args = ["codex", "exec", "--ephemeral", "--skip-git-repo-check", "--ignore-rules",
                "--ignore-user-config", "-s", "read-only", "-m", model,
                "-c", "model_reasoning_effort=low", "-c", "web_search=disabled",
                "-c", f"model_instructions_file={COACH}/coach.md",
                "--output-schema", f"{COACH}/schema.json", "-o", out, "--json"] + DIS
        t0 = time.time()
        p = subprocess.run(args, input=text, capture_output=True, text=True, cwd=d)
        dt = time.time() - t0
        usage = {}
        for line in p.stdout.splitlines():
            try:
                e = json.loads(line)
            except Exception:
                continue
            if e.get("type") == "turn.completed":
                usage = e.get("usage", {})
        try:
            res = json.load(open(out))
        except Exception:
            res = None
        return dict(secs=dt, ok=res is not None, result=res,
                    tin=usage.get("input_tokens"), tcached=usage.get("cached_input_tokens"),
                    tout=usage.get("output_tokens"), tthink=usage.get("reasoning_output_tokens"),
                    err=None if res else p.stderr[-300:])

def run_claude(model, effort, text):
    args = ["claude", "-p", "--model", model, "--system-prompt", PROMPT, "--json-schema", SCHEMA,
            "--tools", "", "--strict-mcp-config", "--settings", '{"disableAllHooks":true}',
            "--disable-slash-commands", "--no-session-persistence", "--output-format", "json"]
    if effort:
        args += ["--effort", effort]
    with tempfile.TemporaryDirectory() as d:
        t0 = time.time()
        p = subprocess.run(args, input=text, capture_output=True, text=True, cwd=d)
        dt = time.time() - t0
    try:
        j = json.loads(p.stdout)
        u = j["usage"]
        return dict(secs=dt, ok=not j.get("is_error"), result=j.get("structured_output"),
                    tin=u["input_tokens"] + u["cache_creation_input_tokens"] + u["cache_read_input_tokens"],
                    tcached=u["cache_read_input_tokens"], tout=u["output_tokens"],
                    tthink=u.get("output_tokens_details", {}).get("thinking_tokens"),
                    usd=j.get("total_cost_usd"), err=None)
    except Exception:
        return dict(secs=dt, ok=False, result=None, err=(p.stdout + p.stderr)[-300:])

def run_apple(text):
    t0 = time.time()
    p = subprocess.run(["/tmp/tf-bench-apple"], input=text, capture_output=True, text=True)
    dt = time.time() - t0
    raw = p.stdout.strip()
    res = None
    try:
        s = raw[raw.index("{"): raw.rindex("}") + 1]
        res = json.loads(s)
    except Exception:
        pass
    return dict(secs=dt, ok=res is not None, result=res, raw=raw[-400:] if not res else None,
                err=p.stderr[-300:] if not res else None)

CONFIGS = {
    "luna":         lambda t: run_codex("gpt-6-luna", t),
    "sol":          lambda t: run_codex("gpt-6-sol", t),
    "haiku-low":    lambda t: run_claude("claude-haiku-5-5", "low", t),
    "haiku-medium": lambda t: run_claude("claude-haiku-5-5", "medium", t),
    "haiku-default":lambda t: run_claude("claude-haiku-5-5", None, t),
    "sonnet-low":   lambda t: run_claude("claude-sonnet-5-5", "low", t),
    "apple":        run_apple,
}

def bench(name):
    fn = CONFIGS[name]
    rows = []
    for i, s in enumerate(SENTS):
        for r in range(RUNS):
            res = fn(s)
            res.update(cfg=name, sent=i, run=r)
            rows.append(res)
            print(f"{name} s{i} r{r} {res['secs']:.1f}s ok={res['ok']}", file=sys.stderr, flush=True)
    return rows

if __name__ == "__main__":
    names = sys.argv[1:] or list(CONFIGS)
    with ThreadPoolExecutor(len(names)) as ex:
        allrows = [r for rows in ex.map(bench, names) for r in rows]
    json.dump(allrows, open(f"{HERE}/results-{'-'.join(names)}.json", "w"), ensure_ascii=False, indent=1)
