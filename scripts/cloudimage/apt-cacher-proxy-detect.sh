#!/bin/sh
# apt-cacher-proxy-detect.sh — APT Proxy-Auto-Detect helper.
#
# Prints the LAN apt-cacher proxy URL when it is reachable, otherwise prints
# DIRECT so APT falls back to a direct connection (e.g. on GitHub-hosted
# runners where the LAN proxy is unreachable).
#
# Installed to /usr/local/apt-cacher-proxy-detect.sh with mode 0755.
# NOTE: this script runs as the _apt user, so it MUST stay world-executable
# and MUST fail fast (nc -w1 / timeout 1) to avoid stalling every apt run.
# REQUIRES: netcat-openbsd (nc) preferred; falls back to a /dev/tcp probe
# via bash+timeout when nc is absent (e.g. minimal images). The image bake
# script installs netcat-openbsd, so the fallback is belt-and-braces.
Proxy_Host=172.19.0.2
PORT=3142
if command -v nc >/dev/null 2>&1 && nc -w1 -z "$Proxy_Host" "$PORT" 2>/dev/null; then
    echo "http://$Proxy_Host:$PORT"
elif command -v timeout >/dev/null 2>&1 && command -v bash >/dev/null 2>&1 && timeout 1 bash -c 'exec 3<>/dev/tcp/'"$Proxy_Host"'/'"$PORT" 2>/dev/null; then
    echo "http://$Proxy_Host:$PORT"
else
    echo "DIRECT"
fi
