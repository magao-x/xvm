#!/usr/bin/env bash
if [[ -z $vmArch ]]; then
    echo "Set vmArch environment variable to aarch64 or x86_64"
    exit 1
fi
if [[ $vmArch == "aarch64" && ($(uname -m) == "arm64" || $(uname -m) == "aarch64") && -z $CI ]]; then
    # ARM on ARM -besides- CI: virtualizable
    qemuMachineFlags="-machine type=virt -cpu host"
    qemuAccelFlags="-accel kvm -accel hvf -accel tcg,thread=multi"
elif [[ $vmArch == "aarch64" ]]; then
    # ARM on x86_64 and/or in CI: emulate
    qemuMachineFlags="-machine type=virt -cpu max"
    qemuAccelFlags="-accel tcg,thread=multi"
elif [[ $vmArch == "x86_64" && $(uname -m) == "x86_64" && -z $CI ]]; then
    # x86_64 on x86_64 (besides CI): virtualizable
    qemuMachineFlags="-machine q35 -cpu host"
    qemuAccelFlags="-accel kvm -accel hvf -accel tcg,thread=multi"
elif [[ $vmArch == "x86_64" ]]; then
    # x86_64 on ARM and/or in CI: emulate
    qemuMachineFlags="-machine q35 -cpu max"
    qemuAccelFlags="-accel tcg,thread=multi"
else
    echo "Unknown combination of vmArch and platform"
    echo "vmArch = $vmArch"
    echo "uname -m = $(uname -m)"
    echo "CI = $CI"
    exit 1
fi
export qemuMachineFlags

magaoxContainerImage=${magaoxContainerImage:-ghcr.io/magao-x/magaox:gui}
export magaoxContainerImage

anacondaInstallKind=${anacondaInstallKind:-cmdline}
export anacondaInstallKind
qemuDisplay=${qemuDisplay:-}
if [[ ! -z $qemuDisplay ]]; then
    ioFlag="-display $qemuDisplay -device qemu-xhci -device usb-kbd -device usb-tablet"
else
    ioFlag='-display none'
fi
export ioFlag

# nproc is unavailable on macOS, but GitHub Actions macOS ARM
# runners have 3 CPUs visible so that's as good a default
# as any
nCpus=$(nproc 2>/dev/null || echo '3')
ramMB=8192

if [[ -n "$CI" ]]; then
    # Find an almost-certainly-unused port to give QEMU
    guestPort=$(python3 -c 'import socket; s=socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()')
else
    guestPort=2201
fi

if [[ $vmArch == aarch64 ]]; then
    # ARM gets UEFI (no qemu-kvm here yet)
    qemuSystemCommand="qemu-system-${vmArch} \
        -drive if=pflash,format=raw,id=ovmf_code,readonly=on,file=./output/firmware_code.fd \
        -drive if=pflash,format=raw,id=ovmf_vars,file=./output/firmware_vars.fd \
        -device virtio-gpu-pci"
elif [[ $vmArch == x86_64 ]]; then
    if command -v qemu-system-${vmArch} >/dev/null 2>&1; then
        qemuSystemCommand="qemu-system-${vmArch}"
    elif [[ -x /usr/libexec/qemu-kvm ]]; then
        qemuSystemCommand="/usr/libexec/qemu-kvm"
    else
        echo "Could not find qemu executable for ${vmArch}"
        exit 1
    fi
else
    echo 'set $vmArch'
    exit 1
fi

# Why these flags?
# user-mode networking ensures it routes out through tailscale -- we use $guestPort for SSHing in
# NIC for network
# multithread if possible
# qemuAccelFlags - see above
# qemuMachineFlags - see above
# virtio passes 'discard'/'trim' through to storage device and can unmap runs of zeroes
# 16 GB is the total RAM on these GitHub Actions runners, so 8 GB is conservative (assuming QEMU itself + Linux host can run in 8 GB)
# ioFlag - see above
qemuSystemCommand="$qemuSystemCommand \
    -netdev user,id=user.0,hostfwd=tcp::${guestPort}-:22 \
    -device virtio-net-pci,netdev=user.0 \
    -name xvm \
    -smp $nCpus \
    $qemuAccelFlags \
    $qemuMachineFlags \
    -drive file=output/xvm.qcow2,if=virtio,format=qcow2,discard=unmap,detect-zeroes=unmap \
    -m ${ramMB}M \
    $ioFlag "
export qemuSystemCommand
