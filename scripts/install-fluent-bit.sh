#!/usr/bin/env bash
#
# install-fluent-bit.sh — Bootstrap Fluent Bit log shipping to Loki.
#
# Deploys the exact same configuration as the `fluent_bit` Ansible role
# (ansible/roles/fluent_bit/) so VMs provisioned outside the Ansible
# inventories can start shipping journald logs with a single command.
#
# Usage (run as root on a fresh Ubuntu VM):
#   curl -fsSL https://raw.githubusercontent.com/Walkmana-25/homelab/main/scripts/install-fluent-bit.sh | sudo bash
#
# Environment variables:
#   LOKI_HOST  — Loki ingestion endpoint host (default: k3s-router.k8s.cloud-milky.solufit.net)
#   LOKI_PORT  — Loki ingestion endpoint port (default: 3100)
#
set -euo pipefail

LOKI_HOST="${LOKI_HOST:-k3s-router.k8s.cloud-milky.solufit.net}"
LOKI_PORT="${LOKI_PORT:-3100}"
FLUENT_BIT_USER="fluent-bit"
FLUENT_BIT_GROUP="fluent-bit"
CONFIG_PATH="/etc/fluent-bit/fluent-bit.conf"

# 1. Require root.
[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

# 2. Install prerequisites (role task: "Install prerequisites").
echo ">>> Installing prerequisite packages..."
apt-get update -qq && apt-get install -y -qq apt-transport-https gnupg2 curl

# 3. Create keyrings directory (role task: "Create keyrings directory").
echo ">>> Creating /etc/apt/keyrings..."
install -d -m 0755 /etc/apt/keyrings

# 4. Download and dearmor the Fluent Bit GPG key (role tasks:
#    "Download Fluent Bit GPG key" + "Dearmor Fluent Bit GPG key").
echo ">>> Installing Fluent Bit GPG key..."
curl -fsSL https://packages.fluentbit.io/fluentbit.key -o /tmp/fluentbit.asc
gpg --batch --yes --dearmor -o /etc/apt/keyrings/fluentbit.gpg < /tmp/fluentbit.asc

# 5. Add the Fluent Bit APT repository (role task: "Add Fluent Bit APT repository").
echo ">>> Adding Fluent Bit APT repository..."
# shellcheck disable=SC1091
CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
[ -n "$CODENAME" ] || { echo "could not determine Ubuntu codename from /etc/os-release" >&2; exit 1; }
echo "deb [signed-by=/etc/apt/keyrings/fluentbit.gpg] https://packages.fluentbit.io/ubuntu/${CODENAME} ${CODENAME} main" > /etc/apt/sources.list.d/fluent-bit.list

# 6. Install fluent-bit (role task: "Install fluent-bit").
echo ">>> Installing fluent-bit..."
apt-get update -qq && apt-get install -y -qq fluent-bit

# 7. Create the config directory (role task: "Create Fluent Bit config directory").
echo ">>> Creating $(dirname "$CONFIG_PATH")..."
install -d -o root -g root -m 0755 "$(dirname "$CONFIG_PATH")"

# 8. Deploy the configuration (role task: "Deploy Fluent Bit configuration").
#    The rendered file is byte-identical to templates/fluent-bit.conf.j2 with the
#    role defaults, so a later Ansible run reports no drift. The service restart
#    is skipped when the on-disk config already matches (idempotent).
echo ">>> Deploying ${CONFIG_PATH}..."
TMP_CONF="$(mktemp)"
cat > "$TMP_CONF" <<EOF
[SERVICE]
    Flush         10
    Log_Level     info
    Daemon        off
    Parsers_File  parsers.conf
    storage.path  /var/lib/fluent-bit/buffer
    storage.sync  normal

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
EOF

NEED_RESTART=0
if [ -f "$CONFIG_PATH" ] \
    && [ "$(md5sum "$CONFIG_PATH" | awk '{print $1}')" = "$(md5sum "$TMP_CONF" | awk '{print $1}')" ]; then
    echo ">>> ${CONFIG_PATH} unchanged"
else
    install -o root -g root -m 0644 "$TMP_CONF" "$CONFIG_PATH"
    NEED_RESTART=1
fi
rm -f "$TMP_CONF"

# 9. Create the buffer directory (role task: "Create Fluent Bit buffer directory").
#    The fluent-bit package creates the fluent-bit user/group.
echo ">>> Creating /var/lib/fluent-bit/buffer..."
install -d -o "$FLUENT_BIT_USER" -g "$FLUENT_BIT_GROUP" -m 0750 /var/lib/fluent-bit/buffer

# 10. Add the fluent-bit user to the systemd-journal group (role task:
#     "Add fluent-bit user to systemd-journal group").
echo ">>> Adding ${FLUENT_BIT_USER} user to systemd-journal group..."
usermod -aG systemd-journal "$FLUENT_BIT_USER"

# 11. Enable and start the service (role task: "Enable and start fluent-bit service").
echo ">>> Enabling fluent-bit service..."
systemctl enable fluent-bit
if [ "$NEED_RESTART" -eq 1 ]; then
    echo ">>> Restarting fluent-bit (configuration changed)..."
    systemctl restart fluent-bit
elif ! systemctl is-active --quiet fluent-bit; then
    echo ">>> Starting fluent-bit..."
    systemctl start fluent-bit
fi

# 12. Final check: the service must be active.
if systemctl is-active --quiet fluent-bit; then
    echo ">>> Fluent Bit is active and shipping journald logs to Loki at ${LOKI_HOST}:${LOKI_PORT}"
else
    echo "fluent-bit service is not active" >&2
    exit 1
fi

# 13. Clean up the temporary GPG key.
rm -f /tmp/fluentbit.asc

echo ">>> Done."
