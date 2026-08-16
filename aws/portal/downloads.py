"""Always-latest DCV client download links.

Amazon keeps CDN *root aliases* pointed at the newest client build (verified:
alias bytes == newest versioned object) while latest.json can lag behind.
So: download URLs = root aliases (always newest), version labels = scraped
from www.amazondcv.com with latest.json as fallback. Cached in-process.
"""

import json
import re
import time

import httpx

CDN = "https://d1uj6qtbmh3dt5.cloudfront.net"
SITE = "https://www.amazondcv.com/"
CACHE_TTL = 12 * 3600

# (label, root-alias URL, version regex to look for in site html / manifest)
PLATFORMS = [
    ("Windows installer (.msi)", f"{CDN}/nice-dcv-client-Release.msi",
     r"nice-dcv-client-Release-(\d{4}\.\d+-\d+)\.msi"),
    ("Windows portable (.zip)", f"{CDN}/nice-dcv-client-Release-portable.zip",
     r"nice-dcv-client-Release-portable-(\d{4}\.\d+-\d+)\.zip"),
    ("macOS — Apple silicon (.dmg)", f"{CDN}/nice-dcv-viewer.arm64.dmg",
     r"nice-dcv-viewer-(\d{4}\.\d+\.\d+)\.arm64\.dmg"),
    ("macOS — Intel (.dmg)", f"{CDN}/nice-dcv-viewer.x86_64.dmg",
     r"nice-dcv-viewer-(\d{4}\.\d+\.\d+)\.x86_64\.dmg"),
    ("Ubuntu 24.04 (.deb)", f"{CDN}/nice-dcv-viewer_amd64.ubuntu2404.deb",
     r"nice-dcv-viewer_(\d{4}\.\d+\.\d+-\d+)_amd64\.ubuntu2404\.deb"),
]

_cache: dict = {"ts": 0.0, "items": None}


def _resolve_versions() -> dict[str, str]:
    """Best-effort version labels keyed by alias URL. Site first, manifest second."""
    versions: dict[str, str] = {}
    try:
        html = httpx.get(SITE, timeout=10, follow_redirects=True).text
        for _, url, pattern in PLATFORMS:
            m = re.search(pattern, html)
            if m:
                versions[url] = m.group(1)
    except Exception:
        pass
    missing = [p for p in PLATFORMS if p[1] not in versions]
    if missing:
        try:
            manifest = httpx.get(f"{CDN}/latest.json", timeout=10).json()
            blob = json.dumps(manifest)
            for _, url, pattern in missing:
                m = re.search(pattern, blob)
                if m:
                    versions[url] = m.group(1)
        except Exception:
            pass
    return versions


def get_downloads() -> list[dict]:
    """[{label, url, version|None}] — url always fetches the newest build."""
    now = time.time()
    if _cache["items"] is not None and now - _cache["ts"] < CACHE_TTL:
        return _cache["items"]
    versions = _resolve_versions()
    items = [
        {"label": label, "url": url, "version": versions.get(url)}
        for label, url, _ in PLATFORMS
    ]
    _cache.update(ts=now, items=items)
    return items
