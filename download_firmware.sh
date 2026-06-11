#!/usr/bin/env bash
set -xeo pipefail
mkdir -p ./input/firmware || exit 1
cd ./input/firmware

indexPage=https://dl.rockylinux.org/pub/rocky/9/AppStream/${vmArch}/os/Packages/e/

rpmName=$(
    curl -q "$indexPage" \
    | sed -n 's/.*href="\(edk2-[^"]*\.rpm\)".*/\1/p' \
    | sort -V \
    | tail -n 1
)
if [[ -z "$rpmName" ]]; then
    echo "Could not find edk2 firmware RPM at $indexPage"
    exit 1
fi
if [[ ! -e "$rpmName" ]]; then
    curl -f -L -o "$rpmName" "${indexPage}/${rpmName}" || exit 1
fi
if [[ $(uname -o) == Darwin ]]; then
    tar xf "$rpmName" || exit 1
else
    rpm2archive "$rpmName" > "$rpmName.tgz" || exit 1
    tar xf "$rpmName.tgz" || exit 1
fi
