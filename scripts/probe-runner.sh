#!/usr/bin/env bash
#
# probe-runner.sh — TEMPORARY diagnostic for the cloudimage pipeline.
# Collects facts (tool versions, nbd usability) on the Actions runner so the
# next pipeline fix is based on evidence, not guesses.
# DELETE THIS FILE (and cloudimage-probe.yml) once the pipeline is green.
#
# Usage: sudo ./scripts/probe-runner.sh
#
set -euo pipefail

say() { echo ">>> $*"; }
die() { echo "error: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root; re-run with sudo"

say "kernel: $(uname -r) / nproc: $(nproc)"
free -g | head -n 2 || true
ls /dev/kvm 2>/dev/null || echo "NO /dev/kvm"

say "tool presence + versions"
for cmd in virt-customize virt-resize guestfish qemu-nbd qemu-img btrfs-convert e2fsck resize2fs modprobe blkid; do
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "HAVE $cmd"
    else
        echo "MISS $cmd"
    fi
done
e2fsck -V 2>&1 | head -n 2 || true
btrfs-convert --version 2>&1 | head -n 2 || true
qemu-nbd --version 2>&1 | head -n 2 || true
virt-customize --version 2>&1 | head -n 2 || true

say "apt candidate versions"
apt-cache policy passt btrfs-progs e2fsprogs qemu-utils libguestfs-tools 2>/dev/null \
    | grep -E '^(passt|btrfs-progs|e2fsprogs|qemu-utils|libguestfs-tools):|  Candidate:' || true

say "nbd module + device nodes"
if modprobe nbd nbds_max=16 max_part=8 2>&1; then
    echo "modprobe nbd OK"
else
    echo "modprobe nbd FAILED"
fi
cat /sys/module/nbd/parameters/nbds_max 2>/dev/null || echo "no nbds_max param"
ls /dev/nbd* 2>/dev/null || echo "NO /dev/nbd* nodes"

nbd_roundtrip() {
    local fmt="$1"
    local img="$2"
    local i cand
    for i in $(seq 0 15); do
        cand="/dev/nbd${i}"
        [ -e "$cand" ] || continue
        if qemu-nbd --connect="$cand" -f "$fmt" "$img" 2>&1; then
            echo "connected $cand ($fmt)"
            sleep 2
            lsblk -ln -o NAME,LABEL "$cand" 2>&1 || true
            if qemu-nbd --disconnect "$cand" 2>&1; then
                echo "disconnected $cand ($fmt)"
                return 0
            fi
            echo "DISCONNECT FAILED $cand ($fmt)"
            return 1
        fi
    done
    echo "NBD ROUNDTRIP FAILED ($fmt)"
    dmesg 2>/dev/null | tail -n 20 || true
    return 1
}

say "nbd roundtrip on tiny images (raw + qcow2)"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
qemu-img create -f raw "$TMPD/tiny.raw" 64M
mkfs.ext4 -q -L probelabel "$TMPD/tiny.raw"
qemu-img create -f qcow2 "$TMPD/tiny.qcow2" 64M
mkfs.ext4 -q -L probelabel "$TMPD/tiny.qcow2" || echo "mkfs on qcow2-container skipped (host mount of qcow2 needs nbd — expected if nbd is broken)"
nbd_roundtrip raw "$TMPD/tiny.raw" || true
nbd_roundtrip qcow2 "$TMPD/tiny.qcow2" || true

say "probe done"
