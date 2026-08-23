#!/usr/bin/env python3
"""Technitium DNS -> Prometheus HTTP SD bridge.

Polls Technitium DNS zones for enabled A records and serves them as
Prometheus HTTP service-discovery JSON so vmagent auto-discovers and
scrapes node_exporter on every Proxmox VM registered in DNS.

Endpoints:
  GET /sd       -> cached SD target groups (application/json)
  GET /healthz  -> liveness/readiness probe ("ok")

Python 3 standard library only.
"""

import json
import os
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Dict, List, Set, Tuple

NODE_EXPORTER_PORT = 9100
API_TIMEOUT_SECONDS = 10

SDGroup = Dict[str, object]


def log(message: str) -> None:
    timestamp = time.strftime("%Y-%m-%dT%H:%M:%S")
    print(f"[technitium-sd] {timestamp} {message}", file=sys.stderr, flush=True)


def parse_extra_labels(raw: str) -> Dict[str, str]:
    """Parse a comma-separated ``k=v`` list into a labels dict."""
    labels: Dict[str, str] = {}
    for item in raw.split(","):
        item = item.strip()
        if not item:
            continue
        if "=" not in item:
            log(f"ignoring malformed SD_EXTRA_LABELS entry: {item!r}")
            continue
        key, _, value = item.partition("=")
        labels[key.strip()] = value.strip()
    return labels


TECHNITIUM_URL = os.environ.get("TECHNITIUM_URL", "http://10.2.0.1:5380").rstrip("/")
TECHNITIUM_TOKEN = os.environ.get("TECHNITIUM_TOKEN", "")
TECHNITIUM_ZONES = [
    zone.strip()
    for zone in os.environ.get(
        "TECHNITIUM_ZONES", "k8s.cloud-milky.solufit.net,vm.cloud-milky.solufit.net"
    ).split(",")
    if zone.strip()
]
EXCLUDED_NAMES = {
    entry.strip().lower()
    for entry in os.environ.get(
        "TECHNITIUM_EXCLUDE", "k3s-controller-a,k3s-worker-a,k3s-worker-b"
    ).split(",")
    if entry.strip()
}
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "30"))
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8080"))
EXTRA_LABELS = parse_extra_labels(os.environ.get("SD_EXTRA_LABELS", "cluster=k3s,node_type=vm"))

_cache_lock = threading.Lock()
_sd_groups: List[SDGroup] = []


def is_excluded(name: str) -> bool:
    """True when the record name matches the exclusion list (short name or FQDN)."""
    normalized = name.lower().rstrip(".")
    short_name = normalized.split(".", 1)[0]
    return normalized in EXCLUDED_NAMES or short_name in EXCLUDED_NAMES


def _sanitize_url(url: str) -> str:
    """Return scheme://host/path without query string (avoids leaking tokens)."""
    parsed = urllib.parse.urlparse(url)
    return urllib.parse.urlunparse(parsed._replace(query="", fragment=""))


def fetch_zone_records(zone: str) -> List[Dict[str, object]]:
    """Return the raw record list for a zone; raises on HTTP/API failure.

    The API token is passed as a query parameter (``token=…``), which is the
    backward-compatible authentication method supported by all Technitium
    DNS Server versions.  The ``Authorization: Bearer`` header is *not* used
    because some versions reject it with "Parameter 'token' missing".
    """
    query = urllib.parse.urlencode(
        {"token": TECHNITIUM_TOKEN, "domain": zone, "zone": zone, "listZone": "true"}
    )
    url = f"{TECHNITIUM_URL}/api/zones/records/get?{query}"
    request = urllib.request.Request(url)
    try:
        with urllib.request.urlopen(request, timeout=API_TIMEOUT_SECONDS) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        # Re-raise with a sanitized URL so the token never appears in logs.
        raise urllib.error.HTTPError(
            _sanitize_url(exc.url), exc.code, exc.msg, exc.hdrs, exc.fp,
        ) from exc
    except urllib.error.URLError:
        # URLError has no .url attribute — just re-raise as-is (no leak risk).
        raise
    if payload.get("status") != "ok":
        raise RuntimeError(f"API error status for zone {zone!r}: {payload.get('status')!r}")
    response_body = payload.get("response")
    if not isinstance(response_body, dict):
        raise RuntimeError(f"unexpected API response shape for zone {zone!r}")
    records = response_body.get("records")
    if not isinstance(records, list):
        # Malformed-but-200 shape (missing/renamed key): treat as poll failure
        # so the last-good cache is kept instead of being wiped empty.
        # A legitimately empty zone still returns `records: []` (a list).
        raise RuntimeError(f"missing or invalid 'records' list for zone {zone!r}")
    return records


def build_groups() -> List[SDGroup]:
    """Poll every zone and build one SD group per kept A record."""
    groups: List[SDGroup] = []
    seen_ips: Set[str] = set()  # L4: same IP in multiple zones -> single scrape
    for zone in TECHNITIUM_ZONES:
        records = fetch_zone_records(zone)
        kept = 0
        for record in records:
            if not isinstance(record, dict):
                continue
            if record.get("type") != "A" or record.get("disabled"):
                continue
            name = str(record.get("name", ""))
            if not name or name.startswith("*") or is_excluded(name):
                continue
            r_data = record.get("rData")
            ip_address = str(r_data.get("ipAddress", "")) if isinstance(r_data, dict) else ""
            if not ip_address:
                continue
            if ip_address in seen_ips:
                continue  # already scraped via an earlier zone (zone order = precedence)
            seen_ips.add(ip_address)
            labels: Dict[str, str] = {"vm_name": name}
            labels.update(EXTRA_LABELS)
            groups.append({"targets": [f"{ip_address}:{NODE_EXPORTER_PORT}"], "labels": labels})
            kept += 1
        log(f"zone {zone}: kept {kept} of {len(records)} records")
    return groups


def poll_loop() -> None:
    """Refresh the SD cache every POLL_INTERVAL seconds; keep last-good on failure."""
    global _sd_groups
    while True:
        try:
            groups = build_groups()
            with _cache_lock:
                _sd_groups = groups
            log(f"cache updated: {len(groups)} target group(s)")
        except Exception as exc:  # noqa: BLE001
            # Broad catch on purpose: any unexpected error (e.g. TypeError from
            # an odd API shape) must not kill the poller thread silently —
            # keep the last-good cache and retry on the next interval.
            # KeyboardInterrupt/SystemExit derive from BaseException and still propagate.
            with _cache_lock:
                count = len(_sd_groups)
            log(f"poll failed, keeping last-good cache ({count} group(s)): {exc!r}")
        time.sleep(POLL_INTERVAL)


class SdHandler(BaseHTTPRequestHandler):
    """Serves /sd (SD groups) and /healthz (probe)."""

    def _send(self, status: int, content_type: str, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 (BaseHTTPRequestHandler API)
        if self.path == "/sd":
            with _cache_lock:
                body = json.dumps(_sd_groups).encode("utf-8")
            self._send(200, "application/json", body)
        elif self.path == "/healthz":
            self._send(200, "text/plain; charset=utf-8", b"ok")
        else:
            self.send_error(404)

    def log_message(self, format: str, *args: object) -> None:  # noqa: A002
        """Silence per-request access logs; app logs go through log()."""


def main() -> None:
    if not TECHNITIUM_TOKEN:
        log("TECHNITIUM_TOKEN is required but not set — exiting")
        sys.exit(1)
    log(
        f"starting: url={TECHNITIUM_URL} token=<redacted> zones={TECHNITIUM_ZONES} "
        f"exclude={sorted(EXCLUDED_NAMES)} poll_interval={POLL_INTERVAL}s "
        f"listen_port={LISTEN_PORT} extra_labels={EXTRA_LABELS}"
    )
    poller = threading.Thread(target=poll_loop, name="technitium-poller", daemon=True)
    poller.start()
    server = ThreadingHTTPServer(("", LISTEN_PORT), SdHandler)
    log(f"serving /sd and /healthz on port {LISTEN_PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
