#!/usr/bin/env bash
set -xeo pipefail
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source $DIR/_common.sh

mkdir -p input/kickstart output

echo "Generating SSH key pair for local SSH login to VM"
if [[ ! -e ./output/xvm_key ]]; then
    ssh-keygen -q -t ed25519 -f ./output/xvm_key -N '' -C 'xvm'
fi

echo "Generate kickstart (./input/kickstart/ks.cfg) from template"
export sshPublicKey=$(cat ./output/xvm_key.pub)
cat ./kickstart/ks.cfg.template | envsubst '$vmArch $sshPublicKey $anacondaInstallKind' > ./input/kickstart/ks.cfg
