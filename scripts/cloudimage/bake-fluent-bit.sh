#!/usr/bin/env bash
#
# bake-fluent-bit.sh — Build-time portion of scripts/install-fluent-bit.sh.
#
# Runs INSIDE the cloud image via `virt-customize --run` (no PID 1, systemd
# is not running). It performs everything that works offline except starting
# services: GPG key + APT repo setup, package install, user/group creation,
# config deployment, buffer directory, journal group membership, and
# `systemctl enable` (symlink creation only).
#
# MUST NOT contain `systemctl enable --now`, `restart`, `is-active`, or
# `start`: those require a running systemd and would fail at build time.
# Services are first started at boot (cloud-init runcmd).
#
# The deployed fluent-bit.conf is identical to the config rendered by
# scripts/install-fluent-bit.sh with default values.
#
# Environment variables:
#   LOKI_HOST  — Loki ingestion endpoint host (default: k3s-router.vm.cloud-milky.solufit.net)
#   LOKI_PORT  — Loki ingestion endpoint port (default: 3100)
#
set -euo pipefail

LOKI_HOST="${LOKI_HOST:-k3s-router.vm.cloud-milky.solufit.net}"
LOKI_PORT="${LOKI_PORT:-3100}"
FLUENT_BIT_USER="fluent-bit"
FLUENT_BIT_GROUP="fluent-bit"
CONFIG_PATH="/etc/fluent-bit/fluent-bit.conf"

# 1. Require root.
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

# 2. Install prerequisites + node-exporter (enable-only, see step 9).
#    netcat-openbsd provides `nc` for the apt Proxy-Auto-Detect helper
#    (see apt-cacher-proxy-detect.sh; the helper also has a /dev/tcp
#    fallback, but nc is the fast primary path).
echo ">>> Installing prerequisite packages..."
apt-get update -qq && apt-get install -y -qq apt-transport-https gnupg2 curl netcat-openbsd prometheus-node-exporter

# 3. Create keyrings directory.
echo ">>> Creating /etc/apt/keyrings..."
install -d -m 0755 /etc/apt/keyrings

# 4. Download and dearmor the Fluent Bit GPG key.
echo ">>> Installing Fluent Bit GPG key..."
curl -fsSL https://packages.fluentbit.io/fluentbit.key -o /tmp/fluentbit.asc
gpg --batch --yes --dearmor -o /etc/apt/keyrings/fluentbit.gpg < /tmp/fluentbit.asc

# 5. Add the Fluent Bit APT repository.
#    Inside the target image /etc/os-release resolves to resolute.
echo ">>> Adding Fluent Bit APT repository..."
# shellcheck disable=SC1091
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
[ -n "$CODENAME" ] || { echo "could not determine Ubuntu codename from /etc/os-release" >&2; exit 1; }
echo "deb [signed-by=/etc/apt/keyrings/fluentbit.gpg] https://packages.fluentbit.io/ubuntu/${CODENAME} ${CODENAME} main" > /etc/apt/sources.list.d/fluent-bit.list

# 6. Install fluent-bit.
echo ">>> Installing fluent-bit..."
apt-get update -qq && apt-get install -y -qq fluent-bit

# 7. Ensure the fluent-bit service user/group exist BEFORE the buffer
#    directory step: the fluent-bit deb package does NOT create a service
#    user (postinst only runs ldconfig/daemon-reload), so `install -o`
#    below would fail on a fresh image without this.
echo ">>> Ensuring fluent-bit user/group exist..."
if ! getent group "$FLUENT_BIT_GROUP" >/dev/null 2>&1; then
    groupadd --system "$FLUENT_BIT_GROUP"
fi
if ! getent passwd "$FLUENT_BIT_USER" >/dev/null 2>&1; then
    useradd --system --gid "$FLUENT_BIT_GROUP" --no-create-home --shell /usr/sbin/nologin "$FLUENT_BIT_USER"
fi

# 8. Deploy the configuration (identical content to install-fluent-bit.sh).
echo ">>> Deploying ${CONFIG_PATH}..."
install -d -o root -g root -m 0755 "$(dirname "$CONFIG_PATH")"
cat > "$CONFIG_PATH" <<EOF
[SERVICE]
    Flush         10
    Log_Level     info
    Daemon        off
    Parsers_File  parsers.conf
    storage.path  /var/lib/fluent-bit/buffer
    storage.sync  normal
    scheduler.base   30
    scheduler.cap    600

[INPUT]
    Name              systemd
    Tag               host.*
    Path              /var/log/journal
    Read_From_Tail    On
    Mem_Buf_Limit     5MB
    Strip_Underscores On
    storage.type      filesystem

[OUTPUT]
    Name              loki
    Match             *
    Host              ${LOKI_HOST}
    Port              ${LOKI_PORT}
    labels            job=fluent-bit, log_type=syslog, hostname=\$HOSTNAME
    Retry_Limit       False
    storage.total_limit_size 1G
EOF
chmod 0644 "$CONFIG_PATH"

# 9. Create the buffer directory owned by the service user.
echo ">>> Creating /var/lib/fluent-bit/buffer..."
install -d -o "$FLUENT_BIT_USER" -g "$FLUENT_BIT_GROUP" -m 0750 /var/lib/fluent-bit/buffer

# 10. Add the fluent-bit user to the systemd-journal group.
echo ">>> Adding ${FLUENT_BIT_USER} user to systemd-journal group..."
getent group systemd-journal >/dev/null 2>&1 || { echo "group systemd-journal does not exist" >&2; exit 1; }
usermod -aG systemd-journal "$FLUENT_BIT_USER"

# 11. Enable services WITHOUT starting them (no PID 1 at build time).
#     First boot (cloud-init runcmd) performs start + is-active verification.
echo ">>> Enabling fluent-bit service (no start at build time)..."
systemctl enable fluent-bit
systemctl enable prometheus-node-exporter

# 12. Clean up the temporary GPG key.
rm -f /tmp/fluentbit.asc

echo ">>> Done."
