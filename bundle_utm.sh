#!/usr/bin/env bash
if [[ -z $vmArch ]]; then
    vmArch=$(uname -m)
fi
ls -lah
mkdir -p ./output/bundle/ || exit 1
ls -R ./utm
cp -vR ./utm ./output/bundle/MagAO-X.utm || exit 1
ls -R ./output/bundle/MagAO-X.utm
cp ./output/xvm_stage2.qcow2 ./output/bundle/MagAO-X.utm/Data/xvm.qcow2 || exit 1
cp ./output/xvm_key ./output/xvm_key.pub ./output/bundle/ || exit 1
