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

# Make sure the host has the image locally — pull only if it's missing AND
# looks like a registry-qualified name. A bare 'name:tag' that resolves to a
# local-only image is fine to use as-is.
if ! podman image exists "$magaoxContainerImage"; then
    echo "Image $magaoxContainerImage not present locally; attempting podman pull..."
    podman pull "$magaoxContainerImage" || {
        echo "Could not find $magaoxContainerImage locally or in a registry."
        exit 1
    }
fi

$qemuSystemCommand &
qemuPid=$!
echo "Waiting for VM to become ready..."
sleep 20
if ! kill -0 $qemuPid 2>/dev/null; then
    echo "Failed - QEMU process exited unexpectedly"
    exit 1
fi

sshOpts="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ./output/xvm_key"

echo "Creating container so we can extract its /etc/ identity files..."
cid=$(podman create "$magaoxContainerImage")
trap 'podman rm -f "$cid" >/dev/null 2>&1 || true' EXIT

stagingDir=$(mktemp -d)
for stem in passwd group shadow gshadow; do
    if podman cp "$cid:/etc/$stem" "$stagingDir/container_etc_$stem" 2>/dev/null; then
        echo "extracted /etc/$stem from container"
    else
        echo "WARN: container has no /etc/$stem — skipping"
    fi
done

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
rm -rf "$stagingDir"

echo "Flattening container $magaoxContainerImage and streaming overlay into guest..."
# Ignore the SSH exit code: the overlay script ends with `systemctl poweroff`,
# which kills sshd mid-session, so ssh exits non-zero ("Connection closed by
# remote host"). The real success signal is QEMU shutting down cleanly below.
set +e
podman export "$cid" | ssh -p $guestPort $sshOpts xdev@localhost \
    'sudo bash /tmp/guest_apply_container_image.sh'
set -e
podman rm -f "$cid"
trap - EXIT

# guest_apply_container_image.sh ends with `systemctl poweroff` — wait for QEMU.
# Bound the wait so a hung guest doesn't deadlock the script forever.
for i in $(seq 1 120); do
    if ! kill -0 $qemuPid 2>/dev/null; then
        break
    fi
    sleep 5
done
if kill -0 $qemuPid 2>/dev/null; then
    echo "Guest did not power off within 10 minutes — killing QEMU."
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
