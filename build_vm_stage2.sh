#!/usr/bin/env bash
echo "Overlaying MagAO-X container image onto the VM..."
source ./_common.sh
set -xeo pipefail

if [[ -e ./output/xvm_stage2.qcow2 ]]; then
    echo "Stage 2 image populated from cache. Skipping stage 2."
    exit 0
fi
if [[ -e ./output/xvm_stage1.qcow2 ]]; then
    cp ./output/xvm_stage1.qcow2 ./output/xvm.qcow2
elif [[ ! -e ./output/xvm.qcow2 ]]; then
    echo "Neither stage1 vm nor existing output/xvm.qcow2 found"
    exit 1
fi

: "${magaoxContainerImage:?magaoxContainerImage must be set (e.g. magaox:gui)}"

# Where to find the pre-flattened container artifact. CI sets
# `containerPrepDir` after downloading the container-prep job's artifact;
# local dev can either set it or fall back to running podman locally.
containerPrepDir="${containerPrepDir:-./prep-stage}"

if [[ -f "$containerPrepDir/prep.tar" ]]; then
    containerSource=prep-artifact
    echo "Using pre-flattened container artifact at $containerPrepDir/prep.tar"
elif command -v podman >/dev/null 2>&1; then
    containerSource=podman
    echo "No prep artifact found; using local podman for $magaoxContainerImage"
else
    echo "No prep artifact at $containerPrepDir/prep.tar AND no podman available."
    echo "Run the container-prep CI job, or `podman pull` the image locally first."
    exit 1
fi

stage2SerialLog=./output/stage2-serial.log
: > "$stage2SerialLog"
# Capture the guest's serial console so we can see what the in-guest overlay
# is doing — ssh without a PTY block-buffers stderr, and the buffer gets lost
# when sshd is killed by systemctl poweroff, so otherwise we'd be blind.
$qemuSystemCommand -serial "file:$stage2SerialLog" &
qemuPid=$!
echo "Waiting for VM to become ready..."
sleep 20
if ! kill -0 $qemuPid 2>/dev/null; then
    echo "Failed - QEMU process exited unexpectedly"
    exit 1
fi

sshOpts="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ./output/xvm_key"

echo "Staging container's /etc/ identity files for merge..."
stagingDir=$(mktemp -d)
trap 'rm -rf "$stagingDir"' EXIT
if [[ $containerSource == prep-artifact ]]; then
    for stem in passwd group shadow gshadow; do
        if [[ -f "$containerPrepDir/container_etc_$stem" ]]; then
            cp "$containerPrepDir/container_etc_$stem" "$stagingDir/container_etc_$stem"
            echo "extracted /etc/$stem from container-prep artifact"
        else
            echo "WARN: container-prep artifact has no container_etc_$stem — skipping"
        fi
    done
else
    if ! podman image exists "$magaoxContainerImage"; then
        podman pull "$magaoxContainerImage" || {
            echo "Could not find $magaoxContainerImage locally or in a registry."
            exit 1
        }
    fi
    cid=$(podman create "$magaoxContainerImage")
    trap 'podman rm -f "$cid" >/dev/null 2>&1 || true; rm -rf "$stagingDir"' EXIT
    for stem in passwd group shadow gshadow; do
        if podman cp "$cid:/etc/$stem" "$stagingDir/container_etc_$stem" 2>/dev/null; then
            echo "extracted /etc/$stem from container"
        else
            echo "WARN: container has no /etc/$stem — skipping"
        fi
    done
fi

echo "Copying overlay script + container identity files into guest..."
# Retry a few times in case sshd isn't quite ready yet. NB: scp uses -P (capital)
# for the port flag; lowercase -p means "preserve mtimes" — they are NOT the same.
for i in 1 2 3 4 5; do
    scp -P $guestPort $sshOpts \
        ./guest_apply_container_image.sh \
        "$stagingDir"/container_etc_* \
        xdev@localhost:/tmp/ \
    && break
    echo "scp attempt $i failed, retrying in 5s..."
    sleep 5
done

echo "Streaming container rootfs into guest..."
# Ignore the SSH exit code: the overlay script ends with `systemctl poweroff`,
# which kills sshd mid-session, so ssh exits non-zero ("Connection closed by
# remote host"). The real success signal is QEMU shutting down cleanly below.
set +e
if [[ $containerSource == prep-artifact ]]; then
    # podman export wrote a clean, in-order tar; just feed it to the guest.
    cat "$containerPrepDir/prep.tar" | ssh -p $guestPort $sshOpts xdev@localhost \
        'sudo bash /tmp/guest_apply_container_image.sh'
else
    podman export "$cid" | ssh -p $guestPort $sshOpts xdev@localhost \
        'sudo bash /tmp/guest_apply_container_image.sh'
fi
set -e
if [[ $containerSource == podman ]]; then
    podman rm -f "$cid"
fi
trap - EXIT
rm -rf "$stagingDir"

# Dump the guest serial log tail now (not only on poweroff-wait timeout) so
# every run shows where the in-guest overlay got to.
echo "=== guest serial log tail right after overlay ssh exit ==="
LC_ALL=C tr -d '\000-\010\013-\037' < "$stage2SerialLog" 2>/dev/null \
    | LC_ALL=C tr '\r' '\n' \
    | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\[K//g' \
    | tail -120 || true
echo "=== end of guest serial log tail ==="

# If the overlay didn't reach its terminal sentinel, bail fast — otherwise the
# wait-for-poweroff loop sits idle for its full 30-min cap on a guest that's
# just running normally (the overlay errored before calling poweroff).
if ! grep -q 'XVM-OVERLAY-COMPLETE' "$stage2SerialLog" 2>/dev/null; then
    echo "Overlay did not reach the XVM-OVERLAY-COMPLETE sentinel — aborting."
    kill $qemuPid 2>/dev/null || true
    wait $qemuPid 2>/dev/null || true
    exit 1
fi

# guest_apply_container_image.sh ends with `systemctl poweroff` — wait for QEMU.
# Bound the wait so a hung guest doesn't deadlock the script forever. On
# TCG-emulated aarch64 the full systemd shutdown can take 10-15 min after the
# script reaches poweroff, so cap at 30 min.
for i in $(seq 1 360); do
    if ! kill -0 $qemuPid 2>/dev/null; then
        break
    fi
    sleep 5
done
if kill -0 $qemuPid 2>/dev/null; then
    echo "Guest did not power off within 30 minutes — killing QEMU."
    echo "=== last 80 lines of guest serial log ($stage2SerialLog) ==="
    LC_ALL=C tr -d '\000-\010\013-\037' < "$stage2SerialLog" 2>/dev/null \
        | LC_ALL=C tr '\r' '\n' \
        | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\[K//g' \
        | tail -80 || true
    kill $qemuPid
    wait $qemuPid 2>/dev/null || true
    exit 1
fi
wait $qemuPid 2>/dev/null || true

echo "Compressing disk image through QCOW2 to QCOW2 conversion"
qemu-img convert -O qcow2 -c ./output/xvm.qcow2 ./output/xvm_stage2.qcow2 || exit 1
du -hs ./output/xvm*
rm -fv ./output/xvm.qcow2 || exit 1

echo "Bundling VM for distribution"
if [[ $vmArch == aarch64 ]]; then
    bash -x bundle_utm.sh || exit 1
else
    bash -x bundle_qcow2.sh || exit 1
fi
realpath ./output/bundle/
ls -lah ./output/bundle/
