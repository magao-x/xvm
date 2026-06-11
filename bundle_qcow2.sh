#!/usr/bin/env bash
if [[ -z $vmArch ]]; then
    vmArch=$(uname -m)
fi
ls -lah
mkdir -p ./output/bundle/ || exit 1
cp ./output/xvm_stage2.qcow2 ./output/bundle/xvm.qcow2 || exit 1
cp ./output/xvm_key ./output/xvm_key.pub ./output/bundle/ || exit 1
cd ./output/bundle/ || exit 1
