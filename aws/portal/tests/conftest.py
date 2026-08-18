"""Import the portal with a stub env file — no AWS, no network, no secrets."""
import os
import pathlib
import sys

STUB = """\
ENTRA_TENANT_ID=00000000-0000-0000-0000-000000000000
ENTRA_CLIENT_ID=00000000-0000-0000-0000-000000000001
ENTRA_CLIENT_SECRET=stub
ASP_PORTAL_HOST=portal.terminals.example.com
ASP_GW_HOST=gw.terminals.example.com
BROKER_CLIENT_ID=stub
BROKER_CLIENT_SECRET=stub
GROUP_DESKTOP_USERS=11111111-1111-1111-1111-111111111111
GROUP_ADMINS=22222222-2222-2222-2222-222222222222
SESSION_SECRET=stub-secret-for-tests
CLIENT_CODE=acme
"""


def pytest_configure(config):
    envfile = pathlib.Path(__file__).parent / "stub-portal.env"
    envfile.write_text(STUB)
    os.environ["ASP_PORTAL_ENV"] = str(envfile)
    sys.path.insert(0, str(pathlib.Path(__file__).parent.parent))
