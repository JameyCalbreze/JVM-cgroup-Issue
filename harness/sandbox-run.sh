#!/usr/bin/env bash
# Run a command inside a bwrap sandbox that emulates an OCI container's namespaces
# (user/pid/uts/ipc/cgroup + mount). Two topologies:
#   hostcgroup : /sys/fs/cgroup bound from the host cgroup root  (mountinfo root escapes -> /../../../../..)
#   owncgroup  : /sys/fs/cgroup bound from this process's own cgroup dir (mountinfo root = /)
# usage: sandbox-run.sh <hostcgroup|owncgroup> <cmd...>
set -euo pipefail
MODE=$1; shift
CGROOT=/sys/fs/cgroup
SELF=$(cut -d: -f3 /proc/self/cgroup)
case "$MODE" in
  hostcgroup) BIND="$CGROOT" ;;
  owncgroup)  BIND="$CGROOT$SELF" ;;
  *) echo "usage: $0 <hostcgroup|owncgroup> cmd..." >&2; exit 2 ;;
esac
exec bwrap --unshare-user --unshare-pid --unshare-uts --unshare-ipc --unshare-cgroup-try \
  --ro-bind / / --proc /proc --dev /dev --bind "$BIND" /sys/fs/cgroup -- "$@"
