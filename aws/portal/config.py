"""Portal configuration — read once from /etc/asp-portal.env (KEY=VALUE lines)."""

import os

ENV_FILE = os.environ.get("ASP_PORTAL_ENV", "/etc/asp-portal.env")


def _load() -> dict:
    cfg = {}
    if os.path.exists(ENV_FILE):
        with open(ENV_FILE) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    cfg[k.strip()] = v.strip()
    cfg.update(os.environ)
    return cfg


_c = _load()

TENANT_ID = _c["ENTRA_TENANT_ID"]
CLIENT_ID = _c["ENTRA_CLIENT_ID"]
CLIENT_SECRET = _c["ENTRA_CLIENT_SECRET"]
AUTHORITY = f"https://login.microsoftonline.com/{TENANT_ID}"

PORTAL_HOST = _c["ASP_PORTAL_HOST"]          # portal.terminals.<your-zone>
GATEWAY_HOST = _c["ASP_GW_HOST"]             # gw.terminals.<your-zone>
GATEWAY_PORT = int(_c.get("ASP_GW_PORT", "8443"))
REGION = _c.get("ASP_REGION", "us-east-2")
CUSTOMER = _c.get("ASP_CUSTOMER", "customer")

BROKER_URL = _c.get("BROKER_URL", "https://localhost:8446")
BROKER_CLIENT_ID = _c["BROKER_CLIENT_ID"]
BROKER_CLIENT_SECRET = _c["BROKER_CLIENT_SECRET"]
BROKER_VERIFY_TLS = _c.get("BROKER_VERIFY_TLS", "false").lower() == "true"

# Entra security-group object IDs (group claims arrive as IDs)
GROUP_DESKTOP_USERS = _c["GROUP_DESKTOP_USERS"]
GROUP_VIEWERS = _c.get("GROUP_VIEWERS", "")
GROUP_ADMINS = _c.get("GROUP_ADMINS", "")

SESSION_SECRET = _c["SESSION_SECRET"]

# provisioning (admin add/remove user) — from Terraform outputs via SSM config
LAUNCH_TEMPLATE_ID = _c.get("LAUNCH_TEMPLATE_ID", "")
SUBNET_IDS = [s for s in _c.get("SUBNET_IDS", "").split(",") if s]
CLIENT_CODE = _c.get("CLIENT_CODE", "cct")
ARTIFACTS_BUCKET = _c.get("ASP_BUCKET", "")
BROKER_SHORT_HOST = _c.get("ASP_BROKER_SHORT", "")

# DCV native client download links (fallback page)
CLIENT_DOWNLOADS = {
    "windows": "https://d1uj6qtbmh3dt5.cloudfront.net/nice-dcv-client-Release.msi",
    "mac": "https://www.amazondcv.com/",
    "linux": "https://www.amazondcv.com/",
}


VERSION = "dev"
try:
    with open(os.path.join(os.path.dirname(__file__), "VERSION")) as _vf:
        VERSION = _vf.read().strip()
except OSError:
    pass


def local_user(upn: str) -> str:
    """Map an Entra UPN to the desktop's local Linux user (PoC: mailbox part)."""
    return upn.split("@")[0].lower()
