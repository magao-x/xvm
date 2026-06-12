#!/usr/bin/env bash
source ./_common.sh
set -xeo pipefail
if [[ -e ./output/xvm_stage1.qcow2 ]]; then
    echo "Stage one image populated from cache. Skipping stage one."
    exit 0
fi

if [[ ! -z $useOemDrv ]]; then
    bash -x create_oemdrv.sh
    oemDrvArgs="-drive file=input/oemdrv.qcow2,format=qcow2"
    cdromArgs="-cdrom input/iso/Rocky-9-latest-${vmArch}-minimal.iso"
else
    oemDrvArgs=""
    cdromArgs="-cdrom output/Rocky-9-${vmArch}-unattended.iso"
fi

# make disk drive image
qemu-img create -f qcow2 output/xvm.qcow2 64G

# Stage 0 is responsible for ./output/firmware_{code,vars}.fd; bail loudly if
# they're missing so we don't trip over it inside qemu later.
if [[ ! -e ./output/firmware_code.fd || ! -e ./output/firmware_vars.fd ]]; then
    echo "Firmware files missing in ./output/; run build_vm_stage0.sh first."
    exit 1
fi

echo "Starting VM installation process..."
# Kickstart ends with `poweroff`, so the VM exits on its own when install finishes.
$qemuSystemCommand \
    $cdromArgs \
    $oemDrvArgs \
    -serial stdio || exit 1
echo "Created VM and installed Rocky Linux + KDE"

mv -v ./output/xvm.qcow2 ./output/xvm_stage1.qcow2
echo "Finished creating initial Rocky VM"
