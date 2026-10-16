#!/usr/bin/env bash
# Phase 1 wrapper: run a command inside a fresh cgroup v2 with a hard memory limit.
# usage: cg-run.sh <limit-bytes> <cmd...>
# DELEGATE (env, default "+cpu +memory +pids") is written to the parent's cgroup.subtree_control,
# which is what decides the contents of the leaf's /sys/fs/cgroup/cgroup.controllers.
# Caller owns cleanup of $PARENT/jvmtest (cat memory.events; rmdir).
set -euo pipefail
LIMIT=$1; shift
DELEGATE=${DELEGATE:-"+cpu +memory +pids"}
PARENT=/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice
CG=$PARENT/jvmtest
mkdir -p "$CG"
printf '%s' "$DELEGATE" > "$PARENT/cgroup.subtree_control" 2>/dev/null || true
printf '%s' "$LIMIT"  > "$CG/memory.max"
printf '0'            > "$CG/memory.swap.max"
printf '%s' "$$"      > "$CG/cgroup.procs"
exec "$@"
