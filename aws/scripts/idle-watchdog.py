#!/opt/asp/portal-venv/bin/python3
"""Idle watchdog — pauses (hibernates) idle terminals to stop compute spend.

Runs on the control plane every 5 minutes (systemd timer). Tenant defaults
live in SSM /asp/idle/config (admin page editable); per-terminal overrides are
instance tags (IdlePolicy=keep-awake, IdleMinutes=N). Hibernate after the
configured idle minutes. A terminal is ACTIVE when any of:
  - a DCV client is connected (someone is looking at it)
  - claude consumed CPU this window (an agent run in flight; an idle REPL
    doesn't tick — and hibernate preserves it anyway)
  - 1-min load says something substantial is running (builds, tests, ...)
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

ENV = dict(
    line.strip().split("=", 1)
    for line in open("/etc/asp-terminal.env")
    if "=" in line and not line.startswith("#")
)
REGION = ENV["ASP_REGION"]
CUSTOMER = ENV["ASP_CUSTOMER"]
BUCKET = ENV["ASP_BUCKET"]

DEFAULTS = {
    "enabled": True,
    "idle_minutes": 30,
    "claude_active_ticks": 300,  # 3 CPU-sec per check window
    "load_active": 0.25,
    "min_uptime_secs": 900,
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
    cmd = ssm.send_command(
        InstanceIds=[instance_id],
        DocumentName="AWS-RunShellScript",
        Parameters={"commands": [
            f"aws s3 cp s3://{BUCKET}/scripts/idle-probe.sh /opt/asp/idle-probe.sh --quiet"
            " && bash /opt/asp/idle-probe.sh"
        ]},
    )["Command"]["CommandId"]
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
        prev_cpu = st.get("claude_cpu")
        cpu_delta = None if prev_cpu is None else p["claude_cpu"] - prev_cpu

        reasons = []
        if p["conns"] > 0:
            reasons.append(f"viewer connected ({p['conns']})")
        # negative delta = claude restarted this window; treat as activity
        if cpu_delta is not None and (cpu_delta >= cfg["claude_active_ticks"] or cpu_delta < 0):
            reasons.append(f"claude working (Δ{cpu_delta} ticks)")
        if float(p["load1"]) >= cfg["load_active"]:
            reasons.append(f"system load {p['load1']}")

        last_active = st.get("last_active", now)
        if reasons or "last_active" not in st:
            last_active = now

        idle_min = (now - last_active) / 60
        state[iid] = {"last_active": last_active, "claude_cpu": p["claude_cpu"]}

        limit = cfg["idle_minutes"]
        if m["idle_minutes_tag"].isdigit():
            limit = int(m["idle_minutes_tag"])  # per-terminal override

        if reasons:
            log(f"{name}: ACTIVE ({'; '.join(reasons)})")
        elif p["uptime"] < cfg["min_uptime_secs"]:
            log(f"{name}: idle {idle_min:.0f}m but up only {p['uptime']}s — grace period")
        elif idle_min >= limit:
            log(f"{name}: idle {idle_min:.0f}m ≥ {limit}m — PAUSING (hibernate)")
            try:
                ec2.stop_instances(InstanceIds=[iid], Hibernate=True)
                state.pop(iid, None)
            except Exception as e:  # noqa: BLE001 — log and retry next round
                log(f"{name}: hibernate failed: {e}")
        else:
            log(f"{name}: idle {idle_min:.0f}m / {limit}m")

    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state))


if __name__ == "__main__":
    main()
