#!/opt/asp/portal-venv/bin/python3
"""Idle watchdog — pauses (hibernates) idle terminals to stop compute spend.

Runs on the control plane every 5 minutes (systemd timer). Tenant defaults
live in SSM /asp/idle/config (admin page editable); per-terminal overrides are
instance tags (IdlePolicy=keep-awake, IdleMinutes=N).

A terminal is ACTIVE only when one of these says so (#55 — each was correct in
every field case; everything that merely says "the machine is warm" is not
evidence):
  - a DCV client is connected (someone is looking at it)
  - an unexpired `asp-hold` lease (a long-running monitor, TTL-capped)
  - claude reports a session BUSY *and* that session's transcript gained an
    entry recently — two agreeing signals, so a wedged REPL cannot fake it
  - dpkg mid-transaction, or 1-min load from something substantial

It hibernates once no viewer has connected for `no_conn_minutes` (60 by
default, matching DCV's own client idle-timeout: DCV drops an untouched client
after 60 min, so "no connection" already means "nobody has touched it for an
hour").

CPU ticks decide nothing any more. An idle Claude REPL burns 0.4-0.9% CPU for
ever (its MCP servers), so two open REPLs cleared the old 300-tick bar
permanently — terminal A stayed awake 45h and build box B 188h with nobody
connected. The tick path survives only as a fallback for a box still running
the v1 probe, so a half-rolled fleet keeps working.
Safety: never touches a machine inside the boot grace period (hibernate right
after boot wedges) or tagged IdlePolicy=keep-awake.
State survives restarts in /var/lib/asp/idle-state.json.
"""

import calendar
import json
import os
import pathlib
import re
import time

import boto3

def _unquote(v: str) -> str:
    """Tolerate a shell-quoted value ('x' / "x") — the control-plane env is
    written quoted so it is safe to source (#12); desktops may follow."""
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
        v = v[1:-1]
    return v


ENV = {
    k.strip(): _unquote(v)
    for k, v in (
        line.strip().split("=", 1)
        for line in open("/etc/asp-terminal.env")
        if "=" in line and not line.startswith("#")
    )
}
REGION = ENV["ASP_REGION"]
CUSTOMER = ENV["ASP_CUSTOMER"]
BUCKET = ENV["ASP_BUCKET"]

DEFAULTS = {
    "enabled": True,
    "idle_minutes": 30,
    "claude_active_ticks": 300,  # 3 CPU-sec per check window
    # 1-min load that counts as "something substantial is running" (a build, a
    # test run) on a box with no viewer. NOT 0.25: on the standard 2-vCPU
    # m5a.large that is 12% of one core, which an idle box reaches on its own —
    # measured 0.26-0.56 from nothing but Claude's MCP servers, the plugin
    # observers and this probe. The first live cycle of #55 held a terminal
    # awake on exactly that, with every other signal correctly saying idle.
    # Real work on 2 vCPUs drives load past 1.0; idle noise never does.
    "load_active": 1.0,
    "min_uptime_secs": 900,
    # No viewer for this long => hibernate. 60 min is not a guess: it is DCV's
    # own client idle-timeout, so a connection cannot outlive a human by more
    # than an hour (observed firing 24 times across two boxes).
    "no_conn_minutes": 60,
    # A BUSY session only counts as work while its transcript keeps moving.
    # Entries flush at turn boundaries, so the gap equals the length of the
    # single tool call in flight: an hour is deliberately generous, because
    # being wrong here hibernates a box mid-run, while being slow here only
    # delays a wedged session's box by an hour (and the implausibility net
    # below catches it regardless).
    "busy_entry_max_age_s": 3600,
    # Safety net: held awake this long with NO viewer connection in the window
    # means the activity signal is wrong (today's CPU measure was). Humans do
    # not work for 12 hours without ever connecting. An explicit lease still
    # wins; everything else gets hibernated and loudly logged.
    "implausible_hours": 12,
    # Cap on a single `asp-hold` lease, so a forgotten hold cannot run for ever.
    "max_hold_hours": 12,
    # After this many hours paused: wake briefly, then power off cleanly.
    # Same cost either way, but a 2-day-old session is stale anyway and this
    # sidesteps EC2's 60-day hibernation cap. 0 = never convert.
    "pause_to_off_hours": 48,
}

STATE_FILE = pathlib.Path("/var/lib/asp/idle-state.json")

ec2 = boto3.client("ec2", region_name=REGION)
ssm = boto3.client("ssm", region_name=REGION)


def log(msg: str) -> None:
    print(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}", flush=True)


def load_config() -> dict:
    """Tenant settings from SSM (/asp/idle/config), admin-editable in the portal."""
    cfg = dict(DEFAULTS)
    try:
        raw = ssm.get_parameter(Name="/asp/idle/config")["Parameter"]["Value"]
        stored = json.loads(raw)
        cfg.update({k: stored[k] for k in stored if k in DEFAULTS})
    except Exception:
        pass
    return cfg


def running_desktops() -> list[dict]:
    resp = ec2.describe_instances(Filters=[
        {"Name": "tag:Role", "Values": ["desktop"]},
        {"Name": "tag:Customer", "Values": [CUSTOMER]},
        {"Name": "instance-state-name", "Values": ["running"]},
    ])
    out = []
    for res in resp["Reservations"]:
        for inst in res["Instances"]:
            tags = {t["Key"]: t["Value"] for t in inst.get("Tags", [])}
            out.append({"id": inst["InstanceId"],
                        "name": tags.get("Name", inst["InstanceId"]),
                        "policy": tags.get("IdlePolicy", ""),
                        "idle_minutes_tag": tags.get("IdleMinutes", ""),
                        "convert": tags.get("AspConvert", "")})
    return out


def paused_desktops() -> list[dict]:
    """Hibernated terminals + when they were paused (StateTransitionReason)."""
    resp = ec2.describe_instances(Filters=[
        {"Name": "tag:Role", "Values": ["desktop"]},
        {"Name": "tag:Customer", "Values": [CUSTOMER]},
        {"Name": "instance-state-name", "Values": ["stopped"]},
    ])
    out = []
    for res in resp["Reservations"]:
        for inst in res["Instances"]:
            if (inst.get("StateReason") or {}).get("Code") != "Client.UserInitiatedHibernate":
                continue
            tags = {t["Key"]: t["Value"] for t in inst.get("Tags", [])}
            m = re.search(r"\((\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) GMT\)",
                          inst.get("StateTransitionReason", ""))
            paused_at = (calendar.timegm(time.strptime(m.group(1), "%Y-%m-%d %H:%M:%S"))
                         if m else None)
            out.append({"id": inst["InstanceId"],
                        "name": tags.get("Name", inst["InstanceId"]),
                        "paused_at": paused_at})
    return out


def probe(instance_id: str) -> dict | None:
    try:
        cmd = ssm.send_command(
            InstanceIds=[instance_id],
            DocumentName="AWS-RunShellScript",
            Parameters={"commands": [
                f"aws s3 cp s3://{BUCKET}/scripts/idle-probe.sh /opt/asp/idle-probe.sh --quiet"
                " && bash /opt/asp/idle-probe.sh"
            ]},
        )["Command"]["CommandId"]
    except Exception as e:  # noqa: BLE001
        # A box that is EC2-"running" but whose SSM agent has not registered yet
        # — every resume from hibernate spends minutes in that state — answers
        # SendCommand with InvalidInstanceId. Unhandled, that exception left
        # main() and aborted the whole cycle, so every box after it in the list
        # went unexamined until the next tick (found by the #55 dry run, where a
        # waking build box killed the run right after two verdicts).
        log(f"{instance_id}: probe could not be sent ({type(e).__name__}) — skipping this round")
        return None
    for _ in range(12):
        time.sleep(5)
        try:
            inv = ssm.get_command_invocation(CommandId=cmd, InstanceId=instance_id)
        except ssm.exceptions.InvocationDoesNotExist:
            continue
        if inv["Status"] in ("Success", "Failed", "TimedOut", "Cancelled"):
            if inv["Status"] != "Success":
                return None
            for line in reversed(inv["StandardOutputContent"].splitlines()):
                line = line.strip()
                if line.startswith("{"):
                    try:
                        return json.loads(line)
                    except json.JSONDecodeError:
                        return None
            return None
    return None


def decide(p: dict, st: dict, cfg: dict, now: float) -> tuple[list[str], list[str]]:
    """Pure decision core: (holds, notes). Non-empty `holds` = stay awake.

    Kept free of AWS and I/O so aws/tests/idle-decide-test.py can drive it
    through every field case and edge case we have actually observed.
    """
    holds: list[str] = []
    notes: list[str] = []

    conns = int(p.get("conns", 0) or 0)
    if conns > 0:
        holds.append(f"viewer connected ({conns})")

    hold_until = int(p.get("hold_until", 0) or 0)
    if hold_until > now:
        why = p.get("hold_why") or "no reason given"
        holds.append(f"hold lease: {why} ({(hold_until - now) / 3600:.1f}h left)")

    if int(p.get("probe_version", 1) or 1) >= 2:
        # "unknown" = a live session publishing no status: every headless run
        # (claude -p, the SDK, plugin observers). Only an interactive REPL
        # writes `status`, so counting these as idle hibernated a box with a
        # real agent run on it. They are working candidates, held to the same
        # transcript-freshness test as a busy one.
        busy = int(p.get("claude_busy", 0) or 0) + int(p.get("claude_unknown", 0) or 0)
        busy_age = int(p.get("busy_entry_age_s", -1))
        if busy > 0:
            if 0 <= busy_age <= int(cfg["busy_entry_max_age_s"]):
                # name the holder: an unexpected one (a plugin's background
                # session, a stuck agent) must be visible in the log, not just
                # "claude busy"
                who = p.get("busy_name") or f"{busy} session(s)"
                holds.append(f"claude busy: {who}, transcript {busy_age // 60}m old")
            else:
                # busy but the transcript stopped moving: a wedged session, or
                # one whose transcript we cannot find. Never a reason to hold.
                notes.append(
                    f"claude busy ({busy}) but transcript "
                    f"{'unknown' if busy_age < 0 else str(busy_age // 60) + 'm'} old — not counted")
        idle_sessions = int(p.get("claude_idle", 0) or 0)
        if idle_sessions:
            notes.append(f"{idle_sessions} idle claude session(s)")
    else:
        # v1 probe still staged on this box: fall back to the old CPU delta so a
        # half-rolled fleet behaves exactly as it did before.
        prev_cpu = st.get("claude_cpu")
        cpu_delta = None if prev_cpu is None else int(p.get("claude_cpu", 0)) - prev_cpu
        if cpu_delta is not None and (cpu_delta >= cfg["claude_active_ticks"] or cpu_delta < 0):
            holds.append(f"claude working (Δ{cpu_delta} ticks, v1 probe)")
        notes.append("v1 probe — roll scripts to get the session-status signal (#55)")

    if int(p.get("apt", 0) or 0) > 0:
        holds.append("dpkg transaction in flight")

    if float(p.get("load1", 0) or 0) >= cfg["load_active"]:
        holds.append(f"system load {p.get('load1')}")

    # ---- safety net: an implausible streak means the signal is wrong --------
    last_conn_age = int(p.get("last_conn_age_s", -1))
    implausible_s = float(cfg["implausible_hours"]) * 3600
    active_since = st.get("active_since")
    held_s = 0 if active_since is None else now - active_since
    if (holds and hold_until <= now and conns == 0
            and last_conn_age >= implausible_s and held_s >= implausible_s):
        notes.append(
            f"IMPLAUSIBLE: held awake {held_s / 3600:.1f}h with no viewer for "
            f"{last_conn_age / 3600:.1f}h — activity signal not trusted, hibernating anyway "
            f"({'; '.join(holds)})")
        holds = []

    return holds, notes


def main() -> None:
    cfg = load_config()
    if not cfg["enabled"]:
        log("watchdog disabled in admin settings — nothing to do")
        return
    state = {}
    if STATE_FILE.exists():
        try:
            state = json.loads(STATE_FILE.read_text())
        except json.JSONDecodeError:
            pass
    now = time.time()

    # Pause → power-off conversion, phase 1: a hibernated machine can't drop
    # its RAM image in place — wake it (tagged), phase 2 below shuts it down
    # cleanly once it's settled and idle.
    limit_h = float(cfg.get("pause_to_off_hours") or 0)
    if limit_h > 0:
        for m in paused_desktops():
            if m["paused_at"] is None:
                continue
            age_h = (now - m["paused_at"]) / 3600
            if age_h >= limit_h:
                log(f"{m['name']}: paused {age_h:.1f}h ≥ {limit_h:g}h — converting "
                    "Pause to power-off (brief wake, then clean shutdown)")
                try:
                    ec2.start_instances(InstanceIds=[m["id"]])
                    ec2.create_tags(Resources=[m["id"]],
                                    Tags=[{"Key": "AspConvert", "Value": "off"}])
                except Exception as e:  # noqa: BLE001
                    log(f"{m['name']}: convert start failed: {e}")

    for m in running_desktops():
        iid, name = m["id"], m["name"]
        if m["policy"] == "keep-awake" and not m["convert"]:
            log(f"{name}: keep-awake tag, skipping")
            continue
        p = probe(iid)
        if p is None:
            log(f"{name}: probe failed, skipping this round")
            continue

        # Pause → power-off conversion, phase 2: the user always wins — any
        # connection cancels the conversion and normal idle logic resumes.
        if m["convert"]:
            if p["conns"] > 0:
                log(f"{name}: conversion cancelled — someone connected")
                ec2.delete_tags(Resources=[iid], Tags=[{"Key": "AspConvert"}])
            # no uptime gate: uptime persists across hibernate so it can't
            # measure "time since wake" — the ≥5 min watchdog cycle spacing
            # plus the dpkg-lock check are the real settling guards
            elif int(p.get("apt", 1)) == 0:
                log(f"{name}: converting — powering off cleanly (pause was older than {limit_h:g}h)")
                try:
                    ec2.stop_instances(InstanceIds=[iid])
                    ec2.delete_tags(Resources=[iid], Tags=[{"Key": "AspConvert"}])
                    state.pop(iid, None)
                except Exception as e:  # noqa: BLE001
                    log(f"{name}: convert stop failed: {e}")
                continue
            else:
                log(f"{name}: converting — letting it settle "
                    f"(up {p['uptime']}s, apt={p.get('apt', 0)})")
                continue
        st = state.get(iid, {})
        reasons, notes = decide(p, st, cfg, now)

        last_active = st.get("last_active", now)
        if reasons or "last_active" not in st:
            last_active = now
        # active_since: start of the CURRENT unbroken awake streak, for the
        # implausibility net. Cleared the moment the box stops being held.
        active_since = st.get("active_since") if reasons else None
        if reasons and active_since is None:
            active_since = now

        idle_min = (now - last_active) / 60
        state[iid] = {"last_active": last_active, "claude_cpu": p["claude_cpu"]}
        if active_since is not None:
            state[iid]["active_since"] = active_since

        limit = cfg["idle_minutes"]
        if m["idle_minutes_tag"].isdigit():
            limit = int(m["idle_minutes_tag"])  # per-terminal override

        for n in notes:
            log(f"{name}:   note: {n}")
        # No viewer for no_conn_minutes is its own trigger, independent of the
        # idle timer: DCV has already dropped anyone who stopped typing an hour
        # ago, so there is no one to disturb.
        conn_age_min = int(p.get("last_conn_age_s", -1)) / 60
        no_conn_limit = float(cfg["no_conn_minutes"])
        no_viewer = conn_age_min >= 0 and conn_age_min >= no_conn_limit

        if reasons:
            log(f"{name}: ACTIVE ({'; '.join(reasons)})")
        elif p["uptime"] < cfg["min_uptime_secs"]:
            log(f"{name}: idle {idle_min:.0f}m but up only {p['uptime']}s — grace period")
        elif no_viewer or idle_min >= limit:
            why = (f"no viewer for {conn_age_min:.0f}m ≥ {no_conn_limit:.0f}m"
                   if no_viewer else f"idle {idle_min:.0f}m ≥ {limit}m")
            log(f"{name}: {why} — PAUSING (hibernate)")
            try:
                ec2.stop_instances(InstanceIds=[iid], Hibernate=True)
                state.pop(iid, None)
            except Exception as e:  # noqa: BLE001 — log and retry next round
                log(f"{name}: hibernate failed: {e}")
        else:
            log(f"{name}: idle {idle_min:.0f}m / {limit}m"
                + (f", no viewer {conn_age_min:.0f}m / {no_conn_limit:.0f}m" if conn_age_min >= 0 else ""))

    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state))


if __name__ == "__main__":
    main()
