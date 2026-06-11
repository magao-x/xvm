#!/usr/bin/env bash
set -xeo pipefail
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source $DIR/_common.sh

mkdir -p ./input/iso ./input/kickstart
ISO_FILE=Rocky-9-latest-${vmArch}-minimal.iso
maxAttempts=10
attempt=1
if [[ ! -e ./input/iso/${ISO_FILE} ]]; then
    while [[ $attempt -le $maxAttempts ]]; do
        curl --no-progress-meter --http1.1 -f -L \
        --continue-at - \
        "https://download.rockylinux.org/pub/rocky/9/isos/${vmArch}/${ISO_FILE}" -o "./input/iso/${ISO_FILE}.part" && break
        echo "Download attempt $attempt failed. Retrying in 10 seconds..."
        sleep 10
        attempt=$((attempt+1))
    done

    if [[ -f "./input/iso/${ISO_FILE}.part" ]]; then
        mv "./input/iso/${ISO_FILE}.part" "./input/iso/${ISO_FILE}"
    else
        echo "Download failed after $maxAttempts attempts."
        exit 1
    fi
else
    echo "Rocky Linux ${vmArch} minimal ISO already downloaded."
fi

if [[ ! -e ./input/iso/${ISO_FILE}.CHECKSUM ]]; then
    curl --no-progress-meter -f -L https://download.rockylinux.org/pub/rocky/9/isos/${vmArch}/${ISO_FILE}.CHECKSUM > ./input/iso/${ISO_FILE}.CHECKSUM || true
    cat ./input/iso/${ISO_FILE}.CHECKSUM
    if [[ $(uname -o) == Darwin ]]; then
        shasum -a 256 ./input/iso/${ISO_FILE}
    else
        sha256sum ./input/iso/${ISO_FILE}
    fi
    # NOTE: not verifying the checksum (yet), just printing it into the log for diagnostic use
else
    echo "Rocky Linux ${vmArch} minimal ISO checksum already downloaded."
fi


rebuildDest=./output/Rocky-9-${vmArch}-unattended.iso
rm -f $rebuildDest
echo "Rebuild the ISO so that it includes the kickstart file"
kickstartPath=./input/kickstart/ks.cfg
sourceIsoPath=./input/iso/${ISO_FILE}
destIsoPath=${rebuildDest}

if [[ -e /etc/os-release ]]; then
    source /etc/os-release
else
    ID=$(uname)
fi

if [[ $ID != rocky ]]; then
    if command -v docker 2>&1 > /dev/null; then
        dockerCmd=docker
    elif command -v podman 2>&1 > /dev/null; then
        dockerCmd=podman
        podman machine init 2>&1 > /dev/null || true
        podman machine start 2>&1 > /dev/null || true
    else
        echo "Neither docker nor podman present, aborting"
        exit 1
    fi
    rockyContainer=rockylinux:9
    $dockerCmd pull $rockyContainer
    $dockerCmd run \
        -v "${DIR}/:/xvm" \
        --security-opt label=disable \
        --rm \
        -t $rockyContainer \
        bash /xvm/mkksisowrap.sh \
        --skip-mkefiboot \
        --cmdline 'inst.cmdline' \
        --cmdline 'console=ttyS0' \
        --rm-args rd.live.check \
        --ks /xvm/input/kickstart/ks.cfg \
        /xvm/input/iso/${ISO_FILE} \
        /xvm/$rebuildDest \
    || exit 1
else
    dnf --setopt=timeout=300 --setopt=retries=10 -y install lorax
    mkksiso --skip-mkefiboot \
        --cmdline 'inst.cmdline' \
        --cmdline 'console=ttyS0' \
        --rm-args rd.live.check \
        --ks "${kickstartPath}" \
        "${sourceIsoPath}" \
        "${destIsoPath}" \
    || exit 1
fi
