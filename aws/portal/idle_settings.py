"""Tenant-wide idle/cost settings — shared with the watchdog via SSM."""

import json

import boto3

import config

PARAM = "/asp/idle/config"

DEFAULTS = {
    "enabled": True,
    "idle_minutes": 30,
    "sensitivity": "balanced",
    "claude_active_ticks": 300,  # 3 CPU-seconds per check window
    "load_active": 0.25,
    "min_uptime_secs": 900,
    # After this many hours paused, give up the saved session and power off
    # (identical cost; sidesteps the 60-day hibernation cap). 0 = never.
    "pause_to_off_hours": 48,
}

# Outcome-named presets: "how hard does something have to work to keep the
# machine awake?" Higher thresholds = pauses more eagerly = more savings.
SENSITIVITY_PRESETS = {
    "aggressive":   {"claude_active_ticks": 600, "load_active": 0.60},
    "balanced":     {"claude_active_ticks": 300, "load_active": 0.25},
    "conservative": {"claude_active_ticks": 100, "load_active": 0.10},
}

_ssm = boto3.client("ssm", region_name=config.REGION)


def get_settings() -> dict:
    out = dict(DEFAULTS)
    try:
        raw = _ssm.get_parameter(Name=PARAM)["Parameter"]["Value"]
        stored = json.loads(raw)
        out.update({k: stored[k] for k in stored if k in DEFAULTS})
    except Exception:
        pass
    return out


def put_settings(settings: dict) -> None:
    clean = {k: settings[k] for k in settings if k in DEFAULTS}
    _ssm.put_parameter(Name=PARAM, Type="String", Overwrite=True,
                       Value=json.dumps(clean))
