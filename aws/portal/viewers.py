"""Viewer-only users — may sign in and join sessions shared with them, but
never get a terminal of their own. Managed on the admin page, stored in SSM
(also honored: membership in the ASP-Viewers Entra group)."""

import json
import time

import boto3

import config

PARAM = "/asp/portal/viewers"
_ssm = boto3.client("ssm", region_name=config.REGION)
_cache: dict = {"ts": 0.0, "v": None}


def get_viewers() -> list[str]:
    if _cache["v"] is not None and time.time() - _cache["ts"] < 30:
        return _cache["v"]
    try:
        raw = _ssm.get_parameter(Name=PARAM)["Parameter"]["Value"]
        v = sorted({u.strip().lower() for u in json.loads(raw) if "@" in u})
    except Exception:
        v = []
    _cache.update(ts=time.time(), v=v)
    return v


def _put(viewers: list[str]) -> None:
    _ssm.put_parameter(Name=PARAM, Type="String", Overwrite=True,
                       Value=json.dumps(sorted(set(viewers))))
    _cache.update(ts=0.0, v=None)


def add_viewer(upn: str) -> None:
    _put(get_viewers() + [upn.strip().lower()])


def remove_viewer(upn: str) -> None:
    _put([u for u in get_viewers() if u != upn.strip().lower()])


def is_viewer(upn: str) -> bool:
    return upn.strip().lower() in get_viewers()
