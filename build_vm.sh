#!/usr/bin/env bash
bash -x build_vm_stage0.sh || exit 1
bash -x build_vm_stage1.sh || exit 1
bash -x build_vm_stage2.sh || exit 1
