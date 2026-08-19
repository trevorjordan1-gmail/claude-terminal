"""A build that FATALs must not read as Ready (#7).

desktop-setup.sh publishes a marker with a "failed" key when a sub-step
(DCV, workbench) died; the portal keeps that marker live past the usual
finished/too-old cut-offs and renders "Build failed" instead of a healthy
"Waking up…" that never resolves.
"""
import io
import json
import time

import app
import aws_ec2


def _s3_marker(monkeypatch, marker: dict):
    class _S3:
        def get_object(self, Bucket, Key):
            assert Key.startswith("status/")
            return {"Body": io.BytesIO(json.dumps(marker).encode())}
    monkeypatch.setattr(aws_ec2, "_s3", _S3())


def test_finished_marker_is_history(monkeypatch):
    _s3_marker(monkeypatch, {"pct": 100, "label": "Ready", "eta_min": 0, "ts": time.time()})
    assert aws_ec2.provision_status("i-1") is None


def test_failed_marker_stays_live_despite_pct_and_age(monkeypatch):
    old = time.time() - 6 * 3600  # far past the 120-minute cut-off
    _s3_marker(monkeypatch, {"pct": 100, "label": "Build failed (DCV)", "eta_min": 0,
                             "ts": old, "failed": "DCV"})
    d = aws_ec2.provision_status("i-1")
    assert d is not None and d["failed"] == "DCV"
    assert d["eta_left"] == 0


def _mk(ip="10.0.0.5"):
    return {"id": "i-x", "name": "acme-cct01", "owner": "a@example.com", "local_user": "a",
            "state": "running", "reason_code": "", "private_ip": ip, "type": "t3.large",
            "idle_policy": "", "idle_minutes": "", "owner_group": "", "build_for": ""}


def _ladder(monkeypatch, *, port_up: bool, in_broker: bool, marker):
    monkeypatch.setattr(app, "_dcv_reachable", lambda ip: port_up)
    monkeypatch.setattr(app, "_broker_available_hosts",
                        lambda: {"ip-10-0-0-5"} if in_broker else set())
    monkeypatch.setattr(aws_ec2, "provision_status", lambda iid: marker)
    m = _mk()
    app._annotate_machines([m])
    return m


def test_failed_build_renders_as_failed(monkeypatch):
    """Port down, broker silent, failed marker -> Build failed (not Waking up…)."""
    m = _ladder(monkeypatch, port_up=False, in_broker=False,
                marker={"pct": 100, "label": "Build failed (DCV)", "failed": "DCV", "eta_left": 0})
    assert (m["label"], m["css"]) == ("Build failed", "failed")
    assert m["progress"]["failed"] == "DCV"
    assert not m.get("waking")


def test_stale_failed_marker_yields_to_a_live_port(monkeypatch):
    """DCV answers -> whatever failed earlier was repaired by hand; the marker
    is history and the ordinary ladder applies (Almost ready…)."""
    m = _ladder(monkeypatch, port_up=True, in_broker=False,
                marker={"pct": 100, "label": "Build failed (DCV)", "failed": "DCV", "eta_left": 0})
    assert (m["label"], m["css"]) == ("Almost ready…", "pending")
    assert m.get("almost")


def test_live_progress_still_getting_ready(monkeypatch):
    m = _ladder(monkeypatch, port_up=False, in_broker=False,
                marker={"pct": 55, "label": "Installing the Claude Code workbench", "eta_left": 9})
    assert (m["label"], m["css"]) == ("Getting ready…", "pending")


def test_no_marker_port_down_is_waking(monkeypatch):
    m = _ladder(monkeypatch, port_up=False, in_broker=False, marker=None)
    assert (m["label"], m["css"]) == ("Waking up…", "pending")
    assert m.get("waking")
