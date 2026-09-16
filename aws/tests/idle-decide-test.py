#!/usr/bin/env python3
"""Table test for idle-watchdog.decide() — the hold/hibernate core (#55).

Every case below is either a state measured in the field on 2026-09-16 or an
edge case that would cost real money (a box that never sleeps) or real work (a
box hibernated mid agent run). Run it before touching the decision logic:

    python3 aws/tests/idle-decide-test.py      # exit 0 = all pass
"""
import importlib.util
import os
import pathlib
import sys
import types

HERE = pathlib.Path(__file__).resolve().parent
WATCHDOG = HERE.parent / "scripts" / "idle-watchdog.py"

# idle-watchdog.py reads /etc/asp-terminal.env and builds AWS clients at import
# time; stub both so the pure function can be imported anywhere.
os.environ.setdefault("ASP_REGION", "us-east-2")
sys.modules["boto3"] = types.SimpleNamespace(client=lambda *a, **k: None)
_env = HERE / "_fake-asp-terminal.env"
_env.write_text("ASP_REGION=us-east-2\nASP_CUSTOMER=test\nASP_BUCKET=test-bucket\n")
src = WATCHDOG.read_text().replace('open("/etc/asp-terminal.env")', f'open("{_env}")')
mod = types.ModuleType("watchdog")
mod.__file__ = str(WATCHDOG)
exec(compile(src, str(WATCHDOG), "exec"), mod.__dict__)  # noqa: S102
_env.unlink()
decide = mod.decide

CFG = dict(mod.DEFAULTS)
NOW = 1_800_000_000.0
HOUR = 3600


def probe(**kw):
    """A v2 probe reading: quiet box, nothing happening, unless overridden."""
    base = {"conns": 0, "claude_procs": 0, "claude_cpu": 0, "load1": "0.02",
            "uptime": 100_000, "apt": 0, "probe_version": 2,
            "claude_busy": 0, "claude_idle": 0, "busy_entry_age_s": -1,
            "newest_entry_age_s": -1, "last_conn_age_s": -1,
            "hold_until": 0, "hold_why": ""}
    base.update(kw)
    return base


CASES = [
    # name, probe, state, expect_hold, must_appear_in_output
    ("viewer connected wins over everything",
     probe(conns=1, claude_idle=3, last_conn_age_s=0), {}, True, "viewer connected"),

    # THE BUG: terminal A as measured — 2 idle REPLs burning 470 ticks/window
    ("field: terminal A, two idle REPLs, no viewer 19h",
     probe(claude_idle=2, claude_cpu=245_398, newest_entry_age_s=146_160,
           last_conn_age_s=19 * HOUR), {"claude_cpu": 244_928}, False, "idle claude session"),

    # build box B as measured — awake 7.9 days
    ("field: build box B, two idle REPLs, no viewer 9h",
     probe(claude_idle=2, claude_cpu=580_610, newest_entry_age_s=55_000,
           last_conn_age_s=9 * HOUR), {"claude_cpu": 580_130}, False, "idle claude session"),

    ("genuine agent run, no viewer: BUSY + fresh transcript holds",
     probe(claude_busy=1, busy_entry_age_s=45, last_conn_age_s=3 * HOUR), {}, True, "claude busy"),

    ("long tool call: busy, transcript 20m old, still holds",
     probe(claude_busy=1, busy_entry_age_s=1200, last_conn_age_s=3 * HOUR), {}, True, "claude busy"),

    ("wedged session: busy but transcript 3h old does NOT hold",
     probe(claude_busy=1, busy_entry_age_s=3 * HOUR, last_conn_age_s=5 * HOUR), {}, False, "not counted"),

    ("busy with no transcript found does NOT hold",
     probe(claude_busy=1, busy_entry_age_s=-1, last_conn_age_s=5 * HOUR), {}, False, "not counted"),

    ("lease holds a box with nothing else running",
     probe(hold_until=NOW + 2 * HOUR, hold_why="nightly monitor",
           last_conn_age_s=8 * HOUR), {}, True, "hold lease"),

    ("expired lease does not hold",
     probe(hold_until=NOW - 60, hold_why="stale", last_conn_age_s=8 * HOUR), {}, False, None),

    ("dpkg mid-transaction always holds",
     probe(apt=1, last_conn_age_s=20 * HOUR), {}, True, "dpkg"),

    ("build running: load holds",
     probe(load1="2.40", last_conn_age_s=4 * HOUR), {}, True, "system load"),

    # the safety net
    ("IMPLAUSIBLE: 13h held, no viewer 13h, busy claims work -> hibernate anyway",
     probe(claude_busy=1, busy_entry_age_s=60, last_conn_age_s=13 * HOUR),
     {"active_since": NOW - 13 * HOUR}, False, "IMPLAUSIBLE"),

    ("net does NOT fire while a viewer is connected",
     probe(conns=1, claude_busy=1, busy_entry_age_s=60, last_conn_age_s=0),
     {"active_since": NOW - 30 * HOUR}, True, "viewer connected"),

    ("net does NOT override an explicit lease",
     probe(hold_until=NOW + HOUR, hold_why="soak test", last_conn_age_s=30 * HOUR),
     {"active_since": NOW - 30 * HOUR}, True, "hold lease"),

    ("net does not fire before the streak is long enough",
     probe(claude_busy=1, busy_entry_age_s=60, last_conn_age_s=13 * HOUR),
     {"active_since": NOW - 2 * HOUR}, True, "claude busy"),

    # backwards compatibility with a box still running the v1 probe
    ("v1 probe: big CPU delta still holds (old behaviour)",
     {"conns": 0, "claude_cpu": 1000, "load1": "0.02", "uptime": 99_999, "apt": 0},
     {"claude_cpu": 600}, True, "v1 probe"),

    ("v1 probe: small CPU delta does not hold",
     {"conns": 0, "claude_cpu": 700, "load1": "0.02", "uptime": 99_999, "apt": 0},
     {"claude_cpu": 600}, False, "v1 probe"),

    ("probe error payload never looks busy",
     probe(hold_why="probe-error", last_conn_age_s=2 * HOUR), {}, False, None),
]


def main() -> int:
    failed = 0
    for name, p, st, want_hold, needle in CASES:
        holds, notes = decide(p, st, CFG, NOW)
        got_hold = bool(holds)
        blob = " | ".join(holds + notes)
        ok = got_hold == want_hold and (needle is None or needle in blob)
        print(f"{'PASS' if ok else 'FAIL'}  {name}")
        if not ok:
            failed += 1
            print(f"        want hold={want_hold} got={got_hold}"
                  f"{'' if needle is None else f'; wanted {needle!r} in output'}")
            print(f"        holds={holds}\n        notes={notes}")
    print(f"\n{len(CASES) - failed}/{len(CASES)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
