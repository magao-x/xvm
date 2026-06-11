#!/usr/bin/env bash
set -euo pipefail

dnf --setopt=timeout=300 --setopt=retries=10 -y install lorax

echo "mkksiso wrapper diagnostics:"
echo "uid=$(id -u) gid=$(id -g)"
echo "kernel=$(uname -a)"
if command -v losetup >/dev/null 2>&1; then
    echo "losetup available at $(command -v losetup)"
    losetup -f || true
else
    echo "losetup binary not found"
fi

if compgen -G "/dev/loop*" >/dev/null; then
    ls -l /dev/loop* || true
else
    echo "No loop devices are visible in /dev"
fi

pwd
exec mkksiso "$@"
