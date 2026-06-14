#!/usr/bin/env bash
# Run as root inside the freshly-installed guest VM. Reads a flattened
# container rootfs tarball on stdin (produced by `podman export` on the host)
# and overlays it onto /. Excludes:
#   - kernel/initrd/modules (keep the running kernel's matching set)
#   - system-identity files (/etc/passwd, /etc/group, /etc/shadow, /etc/gshadow,
#     /etc/machine-id, ssh host keys) — we merge specific entries from the
#     container separately below
#   - disk-layout files (/etc/fstab, /etc/crypttab) — the container's UUIDs
#     don't match this disk
#   - host-network identity (/etc/hostname, /etc/hosts, /etc/resolv.conf)
#   - /etc/sddm.conf — keep the desktop install's autologin config for xdev
#
# Runs end-to-end under a single sudo invocation because we don't want any new
# auth round-trips between overlay and shutdown.
set -xeo pipefail

# Mirror our trace and progress to /dev/console (which writes to ttyAMA0 /
# ttyS0 in our QEMU setup) so the host's -serial file: capture sees what
# we're doing. ssh stderr buffering plus sshd being killed by `systemctl
# poweroff` at the end of the script otherwise eats the trace before the
# host can see it. stdin stays untouched — the tar stream is on stdin.
exec > /dev/console 2>&1

# Flatten and overlay at /. See header for exclusion rationale.
#
# bsdtar (from libarchive) instead of GNU tar: crane export emits hardlink
# entries before their target file in the stream (e.g. /opt/conda/lib/.../X
# as a hardlink to /opt/conda/envs/xpy3_13/.../X which hasn't been extracted
# yet), and GNU tar errors then bails the whole extract with "Unexpected EOF
# in archive". bsdtar buffers pending hardlinks until their target appears.
# Rocky 9 has the binary in a package called `bsdtar` (not libarchive).
which bsdtar >/dev/null 2>&1 || dnf install -y bsdtar
# Ignore bsdtar's exit code: it reports each missing hardlink-target as an
# error and exits non-zero at the end ("Error exit delayed from previous
# errors"), but the regular-file entries all extract correctly — and crane's
# out-of-order hardlinks are deduplicated copies of files under
# /opt/conda/envs/xpy3_13/... that DO get extracted as regular files later in
# the stream, so we'd only lose duplicate /opt/conda/lib/ and /opt/conda/pkgs/
# entries which MagAO-X doesn't use at runtime. Sanity-check that /opt/MagAOX
# actually landed after extraction so we catch a genuinely empty extract.
bsdtar -C / -xpf - \
    --exclude='boot' --exclude='boot/*' \
    --exclude='lib/modules' --exclude='lib/modules/*' \
    --exclude='usr/lib/modules' --exclude='usr/lib/modules/*' \
    --exclude='etc/passwd' --exclude='etc/passwd-' \
    --exclude='etc/shadow' --exclude='etc/shadow-' \
    --exclude='etc/group'  --exclude='etc/group-' \
    --exclude='etc/gshadow' --exclude='etc/gshadow-' \
    --exclude='etc/subuid' --exclude='etc/subgid' \
    --exclude='etc/fstab' --exclude='etc/crypttab' \
    --exclude='etc/machine-id' \
    --exclude='etc/hostname' --exclude='etc/hosts' --exclude='etc/resolv.conf' \
    --exclude='etc/ssh/ssh_host_*' \
    --exclude='etc/sddm.conf' --exclude='etc/sddm.conf.d/*' \
    --exclude='home/xdev/.ssh/authorized_keys' \
    || echo "bsdtar exited non-zero (likely out-of-order hardlinks); continuing"
if [[ ! -d /opt/MagAOX/source/MagAOX ]]; then
    echo "FATAL: /opt/MagAOX/source/MagAOX missing after extraction"
    exit 1
fi

# Merge selected user/group entries from the container's identity files.
# The host stages these as /tmp/container_etc_{passwd,group,shadow,gshadow}.
mergeNames="xsup magaox magaox-dev"
for stem in passwd group shadow gshadow; do
    src="/tmp/container_etc_${stem}"
    dst="/etc/${stem}"
    if [[ ! -f $src ]]; then
        echo "WARN: $src missing — skipping merge of /etc/${stem}"
        continue
    fi
    for name in $mergeNames; do
        entry=$(grep -E "^${name}:" "$src" || true)
        if [[ -z $entry ]]; then continue; fi
        if grep -qE "^${name}:" "$dst"; then
            echo "skip ${stem}: ${name} already present"
            continue
        fi
        echo "$entry" >> "$dst"
        echo "merged ${stem}: ${name}"
    done
    rm -f "$src"
done

# Now that magaox/magaox-dev groups exist (from the merge), make xdev a member
# of both so it can read/write MagAO-X tree owned by those groups.
gpasswd -a xdev magaox || true
gpasswd -a xdev magaox-dev || true

# Reclaim /home/xdev for desktop's xdev: the tar extracted /home/xdev with
# ownership from the container's xdev UID (collides until containers are rebuilt
# to put xdev at 1000/xsup at 1001). Force everything in /home/xdev to be owned
# by the desktop's xdev so sshd's StrictModes check passes and the directory is
# actually usable. authorized_keys itself was excluded from the tar so the
# kickstart's xvm_key entry stays in place.
chown -R xdev:xdev /home/xdev
chmod 0700 /home/xdev/.ssh
chmod 0600 /home/xdev/.ssh/authorized_keys

# The container is bootc/ostree-based and ships unit files + generators that
# assume an ostree-managed disk layout (read-only sysroot, /ostree/deploy/,
# etc.). On our regular partitioned/LVM disk they hang `local-fs.target` on
# devices that don't exist, dropping the boot into emergency mode. Strip
# them out — both the wants-symlinks under /etc and the generators that
# would recreate equivalents on the next boot.
find /etc/systemd/system /usr/lib/systemd/system /usr/lib/systemd/system-generators \
    -maxdepth 3 \
    \( -name 'ostree-*' -o -name 'bootc-*' \) \
    -print -delete 2>/dev/null || true

# Drop any systemd unit masks (/etc/systemd/system/X -> /dev/null) the container
# shipped. bootc/ostree-style images mask systemd-udevd, NetworkManager-wait-online,
# and other units they don't want in their managed mode — fatal on a normal disk
# boot because the masked service can't start (e.g. without udev, no /dev/disk/
# by-uuid symlinks, no LVM activation, fstab times out → emergency mode).
find /etc/systemd/system -lname /dev/null -print -delete 2>/dev/null || true

# Refresh dynamic linker cache and SELinux labels after the overlay. We need a
# full-tree relabel because the container's tar wrote into /usr, /var, /etc,
# /opt, /home, /root with default file contexts — leaving e.g.
# /usr/lib/systemd/systemd mislabeled blocks init_t-typed services like
# user@.service from starting under enforcing mode, killing every SSH/SDDM
# session at PAM setup time. setfiles is faster than `restorecon -RF /` and
# uses the policy's authoritative file_contexts.
ldconfig || true
setfiles -F -e /proc -e /sys -e /dev -e /run \
    /etc/selinux/targeted/contexts/files/file_contexts / || true

# The installed kernel cmdline inherits `console=ttyS0` from the build-time
# boot args. Without `console=tty0` alongside it, the kernel doesn't echo to
# the framebuffer during early boot, so UTM/cocoa users see a black screen
# until KWin finally lights up the display. We want BOTH consoles active so
# the same image works for headless serial debug AND for end-users with a
# display. grubby's --args= treats `console=` as a single key (last wins), so
# we patch the BLS loader entries directly: prepend `console=tty0` if missing.
for f in /boot/loader/entries/*.conf; do
    if ! grep -q 'console=tty0' "$f"; then
        sed -i 's|^options |options console=tty0 |' "$f"
    fi
done

mkdir -p /etc/xdg

# Disable KDE's "Switch User" / start-new-session actions. Triggering a new
# SDDM session locks up the VM (virtio_gpu doesn't handle multi-seat handoff
# well). The `[$i]` suffix marks the entries immutable from user config.
if ! grep -q '^# xvm: kiosk action restrictions$' /etc/xdg/kdeglobals 2>/dev/null; then
    cat >> /etc/xdg/kdeglobals <<'KIOSK_EOF'

# xvm: kiosk action restrictions
[KDE Action Restrictions][$i]
action/start_new_session=false
action/switch_user=false
KIOSK_EOF
fi

# Apply the same KDE convenience defaults the kickstart sets for xdev — but
# system-wide via /etc/xdg/ so xsup (and any future user) inherits them too.
# Plasma layers user-level ~/.config files on top of these, so users can still
# override if they want.
cat > /etc/xdg/plasma-welcomerc <<'PWR_EOF'
[General]
LastSeenVersion=5.27.11
ShouldShow=false
PWR_EOF
cat > /etc/xdg/kscreenlockerrc <<'KSL_EOF'
[Daemon]
Autolock=false
LockOnResume=false
KSL_EOF
cat > /etc/xdg/powermanagementprofilesrc <<'PMP_EOF'
[AC]
icon=battery-charging
PMP_EOF

# Make SDDM autologin xsup instead of xdev. The kickstart writes the file
# during stage 1 (when only xdev exists) so it still says User=xdev there —
# this catches existing stage 1 images so we don't have to rebuild.
sed -i 's/^User=xdev$/User=xsup/' /etc/sddm.conf 2>/dev/null || true

# The container's /etc/profile.d/magaox_role.sh has `MAGAOX_ROLE=workstation`
# without an `export`, so login shells set the variable locally but child
# processes don't inherit it. Re-emit with export, and mirror to
# /etc/environment so PAM (and thus the SDDM/KDE session env) picks it up too.
if [[ -f /etc/profile.d/magaox_role.sh ]]; then
    sed -i 's/^\(MAGAOX_ROLE=\)/export \1/' /etc/profile.d/magaox_role.sh
    role=$(awk -F= '/^export MAGAOX_ROLE=/ {print $2; exit}' /etc/profile.d/magaox_role.sh)
    if [[ -n $role ]] && ! grep -q '^MAGAOX_ROLE=' /etc/environment 2>/dev/null; then
        echo "MAGAOX_ROLE=$role" >> /etc/environment
    fi
fi

# Pre-populate ~/.ssh/known_hosts + ~/.ssh/config for xdev and xsup with the
# exao1/exao2/exao3 host keys + aliases, so the user can ssh from the VM
# without TOFU prompts. Script lives in the container's MagAOX setup tree.
sshConfigure=/opt/MagAOX/source/magao-x-setup/configure_system/configure_ssh_for_workstations.sh
if [[ -f $sshConfigure ]]; then
    bash "$sshConfigure" || echo "WARN: $sshConfigure exited non-zero"
else
    echo "WARN: $sshConfigure not found in container — skipping known_hosts prepopulation"
fi

# Compaction (lifted from the old stage 4).
dnf clean all -y || true
rm -rf /var/cache/dnf
journalctl --vacuum-size=20M || true
rm -rf /tmp/* /var/tmp/*
systemd-tmpfiles --clean || true
find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name 'en*' -exec rm -rf {} +

echo "Trimming..."
fstrim -av || true
echo "Zeroing..."
dd if=/dev/zero of=/EMPTY bs=1M || true
rm -f /EMPTY
echo "Trimming again..."
fstrim -av || true

# Caller waits on the QEMU pid; we power ourselves off here.
systemctl poweroff
