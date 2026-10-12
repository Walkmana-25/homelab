#!/usr/bin/env bash
#
# build-cloudimage.sh — Build a btrfs-root Ubuntu 26.04 LTS (Resolute Raccoon)
# cloud image for the homelab k3s nodes.
#
# Pipeline:
#   1. Download the official resolute cloudimg + SHA256SUMS and verify.
#   1b. Enlarge the working copy by EXTRA_DISK_GB (virt-resize --expand):
#      the pristine cloudimg (~2GB virtual) overflows during the bake
#      ("No space left on device"). The GPT layout is sda1=/ followed by
#      sda14 (BIOS boot) + sda15 (EFI), so sda1 cannot be grown in place.
#   2. virt-customize: bake the apt proxy config, fluent-bit (build-time
#      portion of scripts/install-fluent-bit.sh), and multipathd masking
#      (mirrors ansible/roles/common, socket first, masked).
#   3. Convert the ext4 root filesystem to btrfs in place (btrfs-convert),
#      remove the ext2_saved remnant, rewrite /etc/fstab
#      (btrfs,compress=zstd), and enable btrfs in grub + initramfs.
#   4. virt-sysprep, export qcow2, smoke-verify.
#
# BOOT RISK (step 3 — btrfs root conversion):
#   Converting the root filesystem in place touches the boot chain (fstab,
#   grub, initramfs). A mismatch — e.g. grub without btrfs.mod at boot,
#   wrong rootflags, or a stale grub.cfg — yields an UNBOOTABLE image.
#   The smoke checks in step 4 only verify on-disk metadata; they do NOT
#   prove bootability. A converted image MUST be boot-tested (qemu with
#   cloud-localds, or a spare node) before trusting it for provisioning.
#
# Usage:
#   sudo ./scripts/build-cloudimage.sh [--dry-run]
#
# Environment overrides:
#   BASE_IMAGE_URL  official cloudimg URL
#                   (default: https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img)
#   OUTPUT          output qcow2 path (default: resolute-btrfs-cloudimg-amd64.qcow2)
#   EXTRA_DISK_GB   GiB to add to the working copy before baking (default: 10)
#   WORKDIR         scratch directory (default: a fresh mktemp -d, removed on exit)
#   ALLOW_GRUB_FAILURE=1
#                 opt-in to tolerate an update-grub failure inside the offline
#                 image (default: unset/empty = update-grub failure is fatal).
#                 Only set this if you will boot-test the image and accept a
#                 possibly stale /boot/grub/grub.cfg (BOOT RISK).
#
# Supply-chain note (step 1 — image authenticity):
#   Verification is TLS (https to cloud-images.ubuntu.com) + SHA256SUMS
#   match ONLY. There is deliberately no SHA256SUMS.gpg / gpgv signature
#   check: bootstrapping trust in the Ubuntu Cloud Images signing key from
#   inside CI has no secure root (fetching the key over the same TLS
#   channel adds no real assurance, and no keyring package reliably carries
#   this specific key on ubuntu-latest runners). Accepted risk: a TLS/MITM
#   compromise of cloud-images.ubuntu.com could serve a matching
#   image+checksum pair. Revisit if Ubuntu publishes the signing key via a
#   first-class keyring package.
#
# Runner note (step 3 — qemu-nbd):
#   Step 3 needs the nbd kernel module and /dev/nbd* nodes (modprobe nbd +
#   qemu-nbd --connect). GitHub-hosted ubuntu-latest runners have changed
#   device/module policy before — the FIRST manual run after any runner
#   image refresh must confirm `sudo modprobe nbd` and /dev/nbd{0..15}
#   probing still work before trusting scheduled builds.
#
set -euo pipefail

BASE_IMAGE_URL="${BASE_IMAGE_URL:-https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img}"
OUTPUT="${OUTPUT:-resolute-btrfs-cloudimg-amd64.qcow2}"
EXTRA_DISK_GB="${EXTRA_DISK_GB:-10}"
WORKDIR="${WORKDIR:-}"
DRY_RUN=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUDIMAGE_DIR="${SCRIPT_DIR}/cloudimage"
BAKE_SCRIPT="${CLOUDIMAGE_DIR}/bake-fluent-bit.sh"
PROXY_CONF="${CLOUDIMAGE_DIR}/00proxy"
PROXY_DETECT="${CLOUDIMAGE_DIR}/apt-cacher-proxy-detect.sh"
GUEST_PROXY_DETECT="/usr/local/apt-cacher-proxy-detect.sh"
WORKDIR_CREATED=0
NBD_DEV=""
MNT=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run]

Build a btrfs-root Ubuntu 26.04 cloud image (see header comment for pipeline).
Must run as root (qemu-nbd/mount require privileges), except with --dry-run.

Options:
  --dry-run   print the commands that would run, without executing them
  -h, --help  show this help

Environment:
  BASE_IMAGE_URL  default: ${BASE_IMAGE_URL}
  OUTPUT          default: ${OUTPUT}
  EXTRA_DISK_GB   default: ${EXTRA_DISK_GB}
  WORKDIR         default: <fresh mktemp -d>
  ALLOW_GRUB_FAILURE=1  tolerate update-grub failure (default: fatal)
EOF
}

die() {
    echo "error: $*" >&2
    exit 1
}

log() {
    echo ">>> $*"
}

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[dry-run] $*"
    else
        log "$*"
        "$@"
    fi
}

disconnect_nbd() {
    if [ -n "$NBD_DEV" ]; then
        qemu-nbd --disconnect "$NBD_DEV" || true
        NBD_DEV=""
    fi
}

cleanup() {
    if [ -n "$MNT" ] && mountpoint -q "$MNT" 2>/dev/null; then
        umount "$MNT" || true
    fi
    # shellcheck disable=SC2115
    if [ -n "$NBD_DEV" ]; then
        qemu-nbd --disconnect "$NBD_DEV" || true
    fi
    if [ "$WORKDIR_CREATED" -eq 1 ] && [ -n "$WORKDIR" ]; then
        rm -rf "$WORKDIR"
    fi
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1 (see --help)" ;;
    esac
    shift
done

if [ "$DRY_RUN" -eq 0 ] && [ "$(id -u)" -ne 0 ]; then
    die "must run as root (qemu-nbd/mount require privileges); re-run with sudo"
fi

case "$EXTRA_DISK_GB" in
    ''|*[!0-9]*|0) die "EXTRA_DISK_GB must be a positive integer (got: '${EXTRA_DISK_GB}')" ;;
esac

check_deps() {
    local missing=0
    local cmd
    for cmd in curl sha256sum virt-customize virt-resize virt-sysprep virt-filesystems guestfish qemu-img qemu-nbd truncate btrfs-convert awk grep mount umount lsblk; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "missing required command: $cmd" >&2
            missing=1
        fi
    done
    if [ "$missing" -ne 0 ]; then
        die "install missing dependencies (e.g. sudo apt-get install -y libguestfs-tools qemu-utils btrfs-progs curl)"
    fi
    for f in "$BAKE_SCRIPT" "$PROXY_CONF" "$PROXY_DETECT"; do
        [ -f "$f" ] || die "required input file not found: $f"
    done
}

trap cleanup EXIT

if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] dependency check: curl sha256sum virt-customize virt-resize virt-sysprep virt-filesystems guestfish qemu-img qemu-nbd truncate btrfs-convert awk grep mount umount lsblk"
    echo "[dry-run] required inputs: $BAKE_SCRIPT $PROXY_CONF $PROXY_DETECT"
else
    check_deps
fi

if [ -z "$WORKDIR" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        WORKDIR="<mktemp -d>"
    else
        WORKDIR="$(mktemp -d)"
        WORKDIR_CREATED=1
    fi
fi
WORK_IMG="${WORKDIR}/work.img"
IMAGE_NAME="$(basename "$BASE_IMAGE_URL")"
SUMS_URL="${BASE_IMAGE_URL%/*}/SHA256SUMS"

# --- Step 1: download + verify -------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] curl -fsSL --retry 3 -o ${WORKDIR}/SHA256SUMS ${SUMS_URL}"
    echo "[dry-run] curl -fsSL --retry 3 -o ${WORKDIR}/${IMAGE_NAME} ${BASE_IMAGE_URL}"
    echo "[dry-run] (cd ${WORKDIR} && grep -F ${IMAGE_NAME} SHA256SUMS > ${IMAGE_NAME}.sha256 && sha256sum -c ${IMAGE_NAME}.sha256)"
    echo "[dry-run] cp ${WORKDIR}/${IMAGE_NAME} ${WORK_IMG}"
else
    log "Downloading SHA256SUMS..."
    curl -fsSL --retry 3 -o "${WORKDIR}/SHA256SUMS" "$SUMS_URL"
    log "Downloading ${IMAGE_NAME}..."
    curl -fsSL --retry 3 -o "${WORKDIR}/${IMAGE_NAME}" "$BASE_IMAGE_URL"
    log "Verifying SHA256 checksum..."
    (cd "$WORKDIR" && grep -F "$IMAGE_NAME" SHA256SUMS > "${IMAGE_NAME}.sha256" && sha256sum -c "${IMAGE_NAME}.sha256") \
        || die "SHA256 verification failed for ${IMAGE_NAME}"
    log "Copying base image to working copy (keeping the download pristine)..."
    cp "${WORKDIR}/${IMAGE_NAME}" "$WORK_IMG"
fi

# --- Step 1b: enlarge the working copy -------------------------------------
# The pristine cloudimg (~2GB virtual) overflows during the bake
# (node-exporter deps + fluent-bit: "No space left on device"), so grow the
# disk and expand the root partition BEFORE virt-customize runs.
# virt-resize (not in-place part-resize): the GPT layout is sda1=/ followed
# by sda14/sda15, so sda1 cannot be extended in place; virt-resize
# rearranges and expands it, resizing the ext4 content automatically.
EXPANDED_IMG="${WORKDIR}/expanded.img"
if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] truncate -r ${WORK_IMG} ${EXPANDED_IMG} && truncate -s +${EXTRA_DISK_GB}G ${EXPANDED_IMG}"
    echo "[dry-run] virt-resize --expand /dev/sda1 ${WORK_IMG} ${EXPANDED_IMG} && mv ${EXPANDED_IMG} ${WORK_IMG}"
else
    log "Enlarging working copy by ${EXTRA_DISK_GB}G and expanding /dev/sda1..."
    if ! truncate -r "$WORK_IMG" "$EXPANDED_IMG" \
        || ! truncate -s "+${EXTRA_DISK_GB}G" "$EXPANDED_IMG"; then
        die "failed to pre-size expanded image"
    fi
    virt-resize --expand /dev/sda1 "$WORK_IMG" "$EXPANDED_IMG" \
        || die "virt-resize --expand /dev/sda1 failed"
    mv "$EXPANDED_IMG" "$WORK_IMG"
fi

# --- Step 2: virt-customize bake ------------------------------------------
# Single invocation (one appliance boot): proxy files first so the later
# apt runs inside bake-fluent-bit.sh already use Proxy-Auto-Detect
# (DIRECT fallback outside the LAN), then fluent-bit, then multipathd.
MULTIPATHD_CMD="systemctl stop multipathd.socket multipathd.service || true; systemctl disable multipathd.socket multipathd.service || true; systemctl mask multipathd.socket multipathd.service || true"
if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] virt-customize -a ${WORK_IMG} --copy-in ${PROXY_CONF}:/etc/apt/apt.conf.d/ --copy-in ${PROXY_DETECT}:/usr/local/ --run-command 'chmod 0755 ${GUEST_PROXY_DETECT}' --run ${BAKE_SCRIPT} --run-command '${MULTIPATHD_CMD}'"
else
    log "Baking proxy config, fluent-bit, and multipathd masking..."
    run virt-customize -a "$WORK_IMG" \
        --copy-in "${PROXY_CONF}:/etc/apt/apt.conf.d/" \
        --copy-in "${PROXY_DETECT}:/usr/local/" \
        --run-command "chmod 0755 ${GUEST_PROXY_DETECT}" \
        --run "$BAKE_SCRIPT" \
        --run-command "$MULTIPATHD_CMD" \
        || die "virt-customize bake failed"
fi

# --- Step 3: ext4 root -> btrfs in place ----------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] modprobe nbd; qemu-nbd --connect first free /dev/nbd{0..15}"
    echo "[dry-run] locate root partition (LABEL=cloudimg-rootfs, fallback: FSTYPE=ext4)"
    echo "[dry-run] btrfs-convert <root-part>; mount; btrfs subvolume delete ext2_saved"
    echo "[dry-run] rewrite /etc/fstab root entry to btrfs,compress=zstd; umount; qemu-nbd --disconnect"
    echo "[dry-run] virt-customize: btrfs in initramfs + update-initramfs -u; grub btrfs preload + update-grub"
else
    log "Converting ext4 root to btrfs (BOOT RISK — see header comment)..."
    modprobe nbd || die "could not load the nbd kernel module (qemu-nbd backend unavailable)"
    # Probe /dev/nbd{0..15} in order; the first successful connect wins.
    # (Never hard-code /dev/nbd0: it may already be in use.) A connect
    # failure on every candidate is fatal.
    NBD_DEV=""
    for i in $(seq 0 15); do
        CAND="/dev/nbd${i}"
        [ -e "$CAND" ] || continue
        if qemu-nbd --connect="$CAND" "$WORK_IMG" 2>/dev/null; then
            NBD_DEV="$CAND"
            break
        fi
    done
    [ -n "$NBD_DEV" ] || die "qemu-nbd --connect failed on all of /dev/nbd{0..15} for ${WORK_IMG}"

    ROOT_PART=""
    TRIES=0
    while [ "$TRIES" -lt 30 ]; do
        ROOT_PART="$(lsblk -ln -o NAME,LABEL "$NBD_DEV" 2>/dev/null | awk '$2 == "cloudimg-rootfs" {print "/dev/" $1; exit}')"
        if [ -z "$ROOT_PART" ]; then
            ROOT_PART="$(lsblk -ln -o NAME,FSTYPE "$NBD_DEV" 2>/dev/null | awk '$2 == "ext4" {print "/dev/" $1; exit}')"
        fi
        if [ -n "$ROOT_PART" ]; then
            break
        fi
        TRIES=$((TRIES + 1))
        sleep 2
    done
    [ -n "$ROOT_PART" ] || { disconnect_nbd; die "could not locate the ext4 root partition (tried LABEL=cloudimg-rootfs, then FSTYPE=ext4)"; }
    log "Root partition: ${ROOT_PART}"

    btrfs-convert "$ROOT_PART" \
        || { disconnect_nbd; die "btrfs-convert failed on ${ROOT_PART} — image left unconverted, aborting"; }

    MNT="$(mktemp -d)"
    mount -t btrfs "$ROOT_PART" "$MNT" || { disconnect_nbd; die "could not mount converted btrfs root ${ROOT_PART}"; }
    # btrfs-convert keeps the old ext4 metadata in an ext2_saved subvolume.
    # Remove it to reclaim space. (No balance here: balancing immediately
    # after conversion is discouraged.)
    if [ -e "${MNT}/ext2_saved" ]; then
        btrfs subvolume delete "${MNT}/ext2_saved" || echo "warning: could not delete ext2_saved subvolume, continuing" >&2
    fi
    awk '$2 == "/" { $3 = "btrfs"; if ($4 == "defaults") { $4 = "defaults,compress=zstd" } else if ($4 !~ /(^|,)compress=/) { $4 = $4 ",compress=zstd" } } { print }' \
        "${MNT}/etc/fstab" > "${MNT}/etc/fstab.new" \
        || { disconnect_nbd; die "failed to rewrite /etc/fstab for btrfs"; }
    grep -q "compress=zstd" "${MNT}/etc/fstab.new" \
        || { disconnect_nbd; die "fstab rewrite did not yield compress=zstd on the root entry — aborting before touching grub/initramfs"; }
    mv "${MNT}/etc/fstab.new" "${MNT}/etc/fstab"
    umount "$MNT"
    rmdir "$MNT"
    MNT=""
    disconnect_nbd

    log "Enabling btrfs in initramfs..."
    run virt-customize -a "$WORK_IMG" \
        --run-command 'grep -q -E "^btrfs([[:space:]]|$)" /etc/initramfs-tools/modules 2>/dev/null || echo "btrfs" >> /etc/initramfs-tools/modules' \
        --run-command 'update-initramfs -u' \
        || die "update-initramfs -u failed inside the image — btrfs module may be missing at boot, aborting"

    log "Enabling btrfs in grub..."
    # update-grub failure is FATAL by default: a stale grub.cfg without
    # btrfs support yields an unbootable image (fail-closed). Only an
    # explicit ALLOW_GRUB_FAILURE=1 opts into continuing with a warning.
    if ! virt-customize -a "$WORK_IMG" \
        --run-command 'grep -q "^GRUB_PRELOAD_MODULES=" /etc/default/grub && sed -i -E "s/^GRUB_PRELOAD_MODULES=.*/GRUB_PRELOAD_MODULES=\"part_gpt btrfs\"/" /etc/default/grub || echo "GRUB_PRELOAD_MODULES=\"part_gpt btrfs\"" >> /etc/default/grub' \
        --run-command 'update-grub'; then
        if [ "${ALLOW_GRUB_FAILURE:-0}" = "1" ]; then
            echo "WARNING: update-grub failed inside the offline image (tolerated via ALLOW_GRUB_FAILURE=1)." >&2
            echo "WARNING: /boot/grub/grub.cfg may lack btrfs support — BOOT RISK, verify by actually booting the image." >&2
        else
            disconnect_nbd; die "update-grub failed inside the image — grub.cfg may lack btrfs support, aborting (set ALLOW_GRUB_FAILURE=1 to tolerate)"
        fi
    fi
fi

# --- Step 4: sysprep, export, smoke-verify --------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] virt-sysprep -a ${WORK_IMG}"
    echo "[dry-run] qemu-img convert -p -O qcow2 ${WORK_IMG} ${OUTPUT}"
    echo "[dry-run] smoke: virt-filesystems shows btrfs; guestfish /etc/fstab root line has compress=zstd; grub.cfg has btrfs+insmod; initramfs modules list btrfs kernel module present; 00proxy + detect script present; fluent-bit.service + node-exporter enabled symlinks present"
else
    log "Running virt-sysprep..."
    run virt-sysprep -a "$WORK_IMG" || die "virt-sysprep failed"

    log "Exporting qcow2 to ${OUTPUT}..."
    run qemu-img convert -p -O qcow2 "$WORK_IMG" "$OUTPUT" || die "qemu-img convert failed"

    log "Smoke-verifying ${OUTPUT}..."
    FS_LIST="$(virt-filesystems -a "$OUTPUT" --long)" || die "smoke: virt-filesystems failed on ${OUTPUT}"
    echo "$FS_LIST" | grep -qw "btrfs" || die "smoke: no btrfs filesystem found in ${OUTPUT}"
    GUEST_FSTAB="$(guestfish --ro -a "$OUTPUT" -i cat /etc/fstab)" || die "smoke: cannot read /etc/fstab from ${OUTPUT}"
    echo "$GUEST_FSTAB" | grep -qE '^[^#]*[[:space:]]/[[:space:]].*compress=zstd' \
        || die "smoke: /etc/fstab in ${OUTPUT} lacks compress=zstd on the root (/) entry"
    GUEST_GRUB="$(guestfish --ro -a "$OUTPUT" -i cat /boot/grub/grub.cfg)" || die "smoke: cannot read /boot/grub/grub.cfg from ${OUTPUT}"
    echo "$GUEST_GRUB" | grep -q "btrfs" || die "smoke: /boot/grub/grub.cfg in ${OUTPUT} lacks btrfs (update-grub may have failed)"
    echo "$GUEST_GRUB" | grep -q "insmod" || die "smoke: /boot/grub/grub.cfg in ${OUTPUT} lacks insmod lines (unexpected grub.cfg)"
    GUEST_MODULES="$(guestfish --ro -a "$OUTPUT" -i cat /etc/initramfs-tools/modules)" \
        || die "smoke: cannot read /etc/initramfs-tools/modules from ${OUTPUT}"
    echo "$GUEST_MODULES" | grep -qE '^btrfs([[:space:]]|$)' \
        || die "smoke: btrfs missing from /etc/initramfs-tools/modules in ${OUTPUT} (initramfs may lack btrfs)"
    GUEST_BTRFS_KO="$(guestfish --ro -a "$OUTPUT" -i glob '/lib/modules/*/kernel/fs/btrfs/btrfs.ko*')" \
        || die "smoke: guestfish failed inspecting the btrfs kernel module"
    [ -n "$GUEST_BTRFS_KO" ] || die "smoke: btrfs kernel module not found under /lib/modules in ${OUTPUT}"
    PROXY_STATE="$(guestfish --ro -a "$OUTPUT" -i is-file /etc/apt/apt.conf.d/00proxy)" \
        || die "smoke: guestfish failed inspecting /etc/apt/apt.conf.d/00proxy"
    [ "$PROXY_STATE" = "true" ] || die "smoke: /etc/apt/apt.conf.d/00proxy missing in ${OUTPUT}"
    DETECT_STATE="$(guestfish --ro -a "$OUTPUT" -i is-file "$GUEST_PROXY_DETECT")" \
        || die "smoke: guestfish failed inspecting ${GUEST_PROXY_DETECT}"
    [ "$DETECT_STATE" = "true" ] || die "smoke: ${GUEST_PROXY_DETECT} missing in ${OUTPUT}"
    ENABLED_STATE="$(guestfish --ro -a "$OUTPUT" -i is-symlink /etc/systemd/system/multi-user.target.wants/fluent-bit.service)" \
        || die "smoke: guestfish failed inspecting the fluent-bit enabled symlink"
    [ "$ENABLED_STATE" = "true" ] || die "smoke: fluent-bit.service is not enabled in ${OUTPUT}"
    NODEEXP_STATE="$(guestfish --ro -a "$OUTPUT" -i is-symlink /etc/systemd/system/multi-user.target.wants/prometheus-node-exporter.service)" \
        || die "smoke: guestfish failed inspecting the node-exporter enabled symlink"
    [ "$NODEEXP_STATE" = "true" ] || die "smoke: prometheus-node-exporter.service is not enabled in ${OUTPUT}"
    log "Smoke checks passed: btrfs root + compress=zstd fstab + grub/initramfs btrfs + apt proxy files + fluent-bit/node-exporter enabled."
fi

log "Done: ${OUTPUT}"
