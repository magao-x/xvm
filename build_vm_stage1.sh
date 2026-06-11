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

echo "download firmware for EFI boot"
bash download_firmware.sh

if [[ $vmArch == aarch64 ]]; then
    echo "Using AAVMF (ARM) firmware"
    cp ./input/firmware/usr/share/AAVMF/AAVMF_VARS.fd ./output/firmware_vars.fd
    cp ./input/firmware/usr/share/AAVMF/AAVMF_CODE.fd ./output/firmware_code.fd
else
    echo "Using OVMF (x86_64) firmware"
    cp ./input/firmware/usr/share/edk2/ovmf/OVMF_VARS.fd ./output/firmware_vars.fd
    cp ./input/firmware/usr/share/edk2/ovmf/OVMF_CODE.fd ./output/firmware_code.fd
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
