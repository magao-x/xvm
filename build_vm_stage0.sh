#!/usr/bin/env bash
source ./_common.sh
set -x
if [[ -e ./output/Rocky-9-${vmArch}-unattended.iso &&
      -e ./output/firmware_vars.fd &&
      -e ./output/firmware_code.fd &&
      -e ./output/xvm_key &&
      -e ./output/xvm_key.pub
]]; then
    echo "Stage 0 populated from cache. Skipping stage 0."
    exit 0
fi
mkdir -p output input

echo "create SSH key and kickstart file"
bash create_kickstart.sh || exit 1

echo "download ISO and insert kickstart file"
bash create_rocky_iso.sh || exit 1

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

du -hs ./output/Rocky-9-${vmArch}-unattended.iso \
    ./output/firmware_vars.fd \
    ./output/firmware_code.fd \
    ./output/xvm_key \
    ./output/xvm_key.pub

echo "Finished creating the unattended Rocky install ISO, firmware, and SSH keypair"
