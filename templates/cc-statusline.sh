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
# Tunables (env): CC_CONTEXT_WINDOW (default 200000), CC_CTX_NUDGE (default 80).
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
model = (d.get("model") or {}).get("display_name") or ""
cwd = os.path.basename((d.get("workspace") or {}).get("current_dir") or "")
tp = d.get("transcript_path") or ""

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
if last:
    used = ((last.get("input_tokens") or 0)
            + (last.get("cache_read_input_tokens") or 0)
            + (last.get("cache_creation_input_tokens") or 0))
    win = int(os.environ.get("CC_CONTEXT_WINDOW", "200000"))
    pct = min(99, used * 100 // win)
    if pct >= int(os.environ.get("CC_CTX_NUDGE", "80")):
        seg.append(f"⚠ context {pct}% — wrap up: have Claude document state, then start fresh")
    else:
        seg.append(f"context {pct}%")
print(" · ".join(seg))
PY
)
exec python3 -c "$PYCODE"
