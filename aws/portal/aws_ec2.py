"""EC2 power + lifecycle for this tenant's terminals.

Terminals are portal-managed day-2 resources: provisioned from the Terraform
launch template, terminated on user removal. IAM scopes every mutating call
to Role=desktop + Customer tags.
"""

import re

import boto3

import config

_ec2 = boto3.client("ec2", region_name=config.REGION)
_ssm = boto3.client("ssm", region_name=config.REGION)
_s3 = boto3.client("s3", region_name=config.REGION)

BOOTSTRAP = r"""#!/bin/bash
set -uxo pipefail
export DEBIAN_FRONTEND=noninteractive
until apt-get update -y; do sleep 5; done
apt-get install -y unzip curl
if ! command -v aws >/dev/null; then
  curl -s https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install
fi
mkdir -p /opt/asp
cat > /etc/asp-terminal.env <<ENVEOF
{env}
ENVEOF
TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
IID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id)
cat > /opt/asp/progress.sh <<PROGEOF
prog() {{
  printf '{{"pct": %s, "label": "%s", "eta_min": %s, "ts": %s}}' "\$1" "\$2" "\$3" "\$(date +%s)" > /opt/asp/progress.json
  aws s3 cp /opt/asp/progress.json "s3://{bucket}/status/$IID.json" --quiet || true
}}
PROGEOF
. /opt/asp/progress.sh
prog 5 "Starting up" 24
aws s3 cp "s3://{bucket}/scripts/desktop-setup.sh" /opt/asp/setup.sh
chmod +x /opt/asp/setup.sh
/opt/asp/setup.sh 2>&1 | tee -a /var/log/asp-setup.log
"""


def list_desktops() -> list[dict]:
    resp = _ec2.describe_instances(
        Filters=[
            {"Name": "tag:Role", "Values": ["desktop"]},
            {"Name": "tag:Customer", "Values": [config.CUSTOMER]},
            {"Name": "instance-state-name",
             "Values": ["pending", "running", "stopping", "stopped"]},
        ]
    )
    out = []
    for res in resp["Reservations"]:
        for inst in res["Instances"]:
            tags = {t["Key"]: t["Value"] for t in inst.get("Tags", [])}
            out.append({
                "id": inst["InstanceId"],
                "name": tags.get("Name", inst["InstanceId"]),
                "owner": tags.get("Owner", ""),
                "local_user": tags.get("LocalUser",
                                       config.local_user(tags.get("Owner", "x@x"))),
                "state": inst["State"]["Name"],
                "idle_policy": tags.get("IdlePolicy", ""),
                "idle_minutes": tags.get("IdleMinutes", ""),
                "owner_group": tags.get("OwnerGroup", ""),
                "build_for": tags.get("BuildFor", ""),
                "creator": tags.get("Creator", ""),
                # distinguishes hibernated ("Paused") from powered-off stops
                "reason_code": (inst.get("StateReason") or {}).get("Code", ""),
                "private_ip": inst.get("PrivateIpAddress", ""),
                "type": inst["InstanceType"],
            })
    return sorted(out, key=lambda d: d["name"])


def start(instance_id: str) -> None:
    _ec2.start_instances(InstanceIds=[instance_id])


def hibernate(instance_id: str) -> None:
    _ec2.stop_instances(InstanceIds=[instance_id], Hibernate=True)


def stop(instance_id: str) -> None:
    _ec2.stop_instances(InstanceIds=[instance_id])


def reboot(instance_id: str) -> None:
    _ec2.reboot_instances(InstanceIds=[instance_id])


def terminate(instance_id: str) -> None:
    _ec2.terminate_instances(InstanceIds=[instance_id])


# ---------- provisioning ----------

def valid_local_user(name: str) -> bool:
    return bool(re.fullmatch(r"[a-z][a-z0-9-]{1,30}", name))


def _terminal_env(local_user: str, owner_upn: str) -> str:
    """The /etc/asp-terminal.env every terminal boots with — one place, so the
    tenant profile (medical or standard) reaches every kind of desktop."""
    return "\n".join([
        f"ASP_BROKER_HOST={config.BROKER_SHORT_HOST}",
        f"ASP_LOCAL_USER={local_user}",
        f"ASP_OWNER_UPN={owner_upn}",
        f"ASP_ALL_USERS={local_user}",  # collab guests are added at share time
        f"ASP_CUSTOMER={config.CUSTOMER}",
        f"ASP_REGION={config.REGION}",
        f"ASP_BUCKET={config.ARTIFACTS_BUCKET}",
        f"ASP_PROFILE={config.PROFILE}",
    ])


# ---------- operator build boxes (engagement workbenches) ----------

def valid_build_code(code: str) -> bool:
    return bool(re.fullmatch(r"[a-z][a-z0-9]{1,15}", code))


def next_build_name(build_for: str) -> str:
    highest = 0
    for m in list_desktops():
        match = re.fullmatch(rf"{re.escape(build_for)}-build(\d+)", m["name"])
        if match:
            highest = max(highest, int(match.group(1)))
    return f"{build_for}-build{highest + 1:02d}"


def provision_build_box(build_for: str, creator_upn: str, owner_group: str) -> str:
    """Launch an engagement workbench. Owner = the creating engineer (their 1:1
    view still works); OwnerGroup extends access to the whole team; the local
    session user is the fixed 'build' — group boxes have no single UPN to
    derive one from, and everyone shares the one session by design."""
    name = next_build_name(build_for)
    local = "build"
    env = _terminal_env(local, creator_upn)
    user_data = BOOTSTRAP.format(env=env, bucket=config.ARTIFACTS_BUCKET)
    tags = [
        {"Key": "Name", "Value": name},
        {"Key": "Role", "Value": "desktop"},   # watchdog/rollout treat it normally
        {"Key": "Customer", "Value": config.CUSTOMER},
        {"Key": "Owner", "Value": creator_upn},
        {"Key": "LocalUser", "Value": local},
        {"Key": "OwnerGroup", "Value": owner_group},
        {"Key": "BuildFor", "Value": build_for},
        {"Key": "Creator", "Value": creator_upn},
    ]
    subnet = config.SUBNET_IDS[len(list_desktops()) % len(config.SUBNET_IDS)]
    _ec2.run_instances(
        LaunchTemplate={"LaunchTemplateId": config.LAUNCH_TEMPLATE_ID},
        MinCount=1, MaxCount=1,
        SubnetId=subnet,
        UserData=user_data,
        TagSpecifications=[
            {"ResourceType": "instance", "Tags": tags},
            {"ResourceType": "volume", "Tags": tags},
        ],
    )
    return name


def next_cct_name() -> str:
    highest = 0
    for m in list_desktops():
        match = re.fullmatch(rf"{re.escape(config.CLIENT_CODE)}-cct(\d+)", m["name"])
        if match:
            highest = max(highest, int(match.group(1)))
    return f"{config.CLIENT_CODE}-cct{highest + 1:02d}"


def provision(owner_upn: str, local_user: str) -> str:
    name = next_cct_name()
    env = _terminal_env(local_user, owner_upn)
    user_data = BOOTSTRAP.format(env=env, bucket=config.ARTIFACTS_BUCKET)
    tags = [
        {"Key": "Name", "Value": name},
        {"Key": "Role", "Value": "desktop"},
        {"Key": "Customer", "Value": config.CUSTOMER},
        {"Key": "Owner", "Value": owner_upn},
        {"Key": "LocalUser", "Value": local_user},
    ]
    subnet = config.SUBNET_IDS[len(list_desktops()) % len(config.SUBNET_IDS)]
    _ec2.run_instances(
        LaunchTemplate={"LaunchTemplateId": config.LAUNCH_TEMPLATE_ID},
        MinCount=1, MaxCount=1,
        SubnetId=subnet,
        UserData=user_data,
        TagSpecifications=[
            {"ResourceType": "instance", "Tags": tags},
            {"ResourceType": "volume", "Tags": tags},
        ],
    )
    return name


def set_idle_policy(instance_id: str, policy: str, minutes: int | None) -> None:
    """default: no tags · keep-awake: IdlePolicy tag · custom: IdleMinutes tag."""
    _ec2.delete_tags(Resources=[instance_id],
                     Tags=[{"Key": "IdlePolicy"}, {"Key": "IdleMinutes"}])
    if policy == "keep-awake":
        _ec2.create_tags(Resources=[instance_id],
                         Tags=[{"Key": "IdlePolicy", "Value": "keep-awake"}])
    elif policy == "custom" and minutes:
        _ec2.create_tags(Resources=[instance_id],
                         Tags=[{"Key": "IdleMinutes", "Value": str(minutes)}])


def provision_status(instance_id: str) -> dict | None:
    """Progress marker published by the instance's setup scripts, or None.

    A finished (pct>=100) or old marker is history, not status: auto-update
    re-runs republish markers long after first boot, and showing "Ready 100%"
    next to a "Getting ready…" badge on a later boot reads as a contradiction
    (TJ hit exactly this)."""
    import json as _json
    import time as _time
    try:
        obj = _s3.get_object(Bucket=config.ARTIFACTS_BUCKET,
                             Key=f"status/{instance_id}.json")
        d = _json.loads(obj["Body"].read())
        elapsed_min = max(0.0, (_time.time() - float(d.get("ts", 0))) / 60)
        if float(d.get("pct", 0)) >= 100 or elapsed_min > 120:
            return None
        d["eta_left"] = max(0, round(float(d.get("eta_min", 0)) - elapsed_min))
        return d
    except Exception:
        return None


def force_display_layout(instance_id: str, session_id: str, layout: str = "1920x1080") -> None:
    """Every Connect starts from a clean single 1080p display (Xdcv's default
    is a 4x800x600 mess); the client's auto-resize takes over from there."""
    try:
        _ssm.send_command(
            InstanceIds=[instance_id],
            DocumentName="AWS-RunShellScript",
            Parameters={"commands": [f"dcv set-display-layout --session={session_id} {layout}"]},
        )
    except Exception:
        pass  # cosmetic enforcement; never block a connect on it


def ensure_os_user(instance_id: str, user: str) -> None:
    """Collab guests must exist as OS users on the session's desktop."""
    if not valid_local_user(user):
        raise ValueError("invalid username")
    _ssm.send_command(
        InstanceIds=[instance_id],
        DocumentName="AWS-RunShellScript",
        Parameters={"commands": [
            f"id -u {user} >/dev/null 2>&1 || "
            f"adduser --disabled-password --gecos 'ASP terminal user' {user}"
        ]},
    )
