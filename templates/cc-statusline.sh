#!/usr/bin/env bash
# Claude Code statusline: <project> · <model> · context N%  (wrap-up nudge ≥80%)
#
# Claude Code invokes this on every update with session JSON on stdin —
# including transcript_path. Context fill is computed from the latest turn's
# token usage in the transcript (input + cache read + cache creation ≈ what
# the next request must carry) against the model window. This is the always-
# visible teaching tool for session hygiene: when the bar warns, have Claude
# write durable state into the project docs and start a fresh session.
#
# The window is NOT hardcoded: Claude Code reports the running model's real one
# as context_window.context_window_size, along with a pre-computed
# used_percentage. Tunables (env): CC_CONTEXT_WINDOW (override, else whatever
# Claude Code reports), CC_CTX_NUDGE (default 80).
#
# NOTE: the python code is passed via -c, NOT a heredoc — a heredoc would
# replace stdin and eat the JSON Claude Code pipes in.
PYCODE=$(cat <<'PY'
import json, os, sys

try:
    d = json.load(sys.stdin)
except Exception:
    # Claude Code redraws the statusline constantly; a throw here would spray a
    # traceback through every session. A statusline that cannot read its input
    # says nothing.
    sys.exit(0)
model_obj = d.get("model") or {}
model = model_obj.get("display_name") or ""
model_id = model_obj.get("id") or ""
cwd = os.path.basename((d.get("workspace") or {}).get("current_dir") or "")
tp = d.get("transcript_path") or ""

# Claude Code hands us the live window and a pre-computed fill for the model
# actually running -- context_window.context_window_size / used_percentage.
# NEVER hardcode a window here: it was 200k, the Claude 5 family is 1M, and the
# statusline read ~5x high and pinned at its cap on every real session
# (field-hit 2026-09-02). This value is correct for whatever ships next, 2M
# included, without a table to maintain.
cw = d.get("context_window") or {}
win = cw.get("context_window_size")

# Teach the launcher what we learned. It reads transcripts, which record the
# model id and usage but no window, so it cannot know this on its own.
CACHE = os.path.expanduser("~/.local/state/cc-launcher/model-windows.json")
if win and model_id:
    try:
        try:
            known = json.load(open(CACHE))
        except Exception:
            known = {}
        if known.get(model_id) != win:          # only write on change
            known[model_id] = win
            os.makedirs(os.path.dirname(CACHE), exist_ok=True)
            tmp = CACHE + ".new"
            with open(tmp, "w") as f:
                json.dump(known, f)
            os.replace(tmp, CACHE)
    except Exception:
        pass                                     # a cache miss is not worth a broken statusline

last = None
try:
    size = os.path.getsize(tp)
    with open(tp) as f:
        if size > 262144:            # long transcript: only the tail matters
            f.seek(size - 262144)
            f.readline()             # discard the partial line
        for line in f:
            try:
                e = json.loads(line)
            except Exception:
                continue
            u = (e.get("message") or {}).get("usage")
            if isinstance(u, dict) and u.get("input_tokens") is not None:
                last = u
except Exception:
    pass

seg = [s for s in (cwd, model) if s]

# An explicit override always wins; otherwise use the window Claude Code
# reported, and only fall back to its documented 200k default for a model it
# did not tell us about.
env_win = os.environ.get("CC_CONTEXT_WINDOW")
win = int(env_win) if env_win else (win or 200_000)

pct = None if env_win else cw.get("used_percentage")   # trust Claude Code's own figure
if pct is None:
    total = cw.get("total_input_tokens")
    if not total and last:
        # null before the first API call and again after /compact, so fall back
        # to the transcript's latest turn: what the next request must carry
        total = ((last.get("input_tokens") or 0)
                 + (last.get("cache_read_input_tokens") or 0)
                 + (last.get("cache_creation_input_tokens") or 0))
    if total:
        pct = total * 100 // win

if pct is not None:
    pct = max(0, min(100, int(pct)))
    if pct >= int(os.environ.get("CC_CTX_NUDGE", "80")):
        seg.append(f"⚠ context {pct}% — wrap up: have Claude document state, then start fresh")
    else:
        seg.append(f"context {pct}%")
print(" · ".join(seg))
PY
)
exec python3 -c "$PYCODE"
