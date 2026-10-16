#!/usr/bin/env bash
# Phase 0 capture. Run INSIDE the failing container by overriding its command:
#   docker run --rm <image> bash /path/to/collect.sh   (bind-mount or docker cp this file)
# Read-only: prints state, modifies nothing. Save stdout+stderr to results/work/collect.txt
#
# Reading the result - three mechanisms produce the same symptom
# (heap = MaxRAMPercentage x NODE memory instead of x the container limit):
#
# M1  JDK <= 21.0.9 (<=17.0.19, <=11.0.31, <=8u511): detection reads /proc/cgroups.
#     If "## proc_cgroups" has no memory row (newer kernels where v1 memory is disabled),
#     the trace shows: "controller ... is not enabled" + "One or more required controllers
#     disabled at kernel level." with the source file named as /proc/cgroups, and no
#     "Detected cgroups v2 unified hierarchy" line.
#     Fix: bump the JDK (21.0.10+ / 17.0.20+ / 11.0.32+ / 8u512+ / any 25), else pin -Xmx or -XX:MaxRAM.
#
# M2  JDK >= 21.0.10, /sys/fs/cgroup inherited or bind-mounted from the host cgroup root
#     (cgroupns=host, or a private cgroup ns holding the host cgroup2 mount). Detection succeeds
#     ("Detected cgroups v2 unified hierarchy") but the path it builds is not the real limit path:
#     trace shows "Open of file /sys/fs/cgroup/memory.max failed, No such file or directory" and
#     "Memory Limit failed: -2". The JDK ignores the mountinfo root for cgroup v2.
#     Check "## mountinfo": cgroup2 line whose 5th field (root) is not "/" (often "/../../../../..").
#     Fix: mount a fresh cgroup2 fs at /sys/fs/cgroup in the container, or use cgroupns=private
#     without a host cgroup bind, else pin -Xmx or -XX:MaxRAM.
#
# M3  JDK >= 21.0.10, the cgroup holding the process has no "cpu" controller delegated, so
#     "## cgroup.controllers" (or the file at /sys/fs/cgroup/cgroup.controllers) lacks "cpu".
#     The trace names /sys/fs/cgroup/cgroup.controllers as the source and shows
#     "controller cpu is not enabled" + "One or more required controllers disabled at kernel level.".
#     Fix: delegate cpu + memory to the container's cgroup, else pin -Xmx or -XX:MaxRAM.
#
# In all three cases "## flags" shows MaxHeapSize = ~70% and InitialHeapSize = ~50% of NODE
# MemTotal rather than of the container limit.
set -u
echo "## kernel";   uname -r; cat /proc/version
echo "## id";       id
echo "## proc_cgroups";  cat /proc/cgroups
echo "## proc_self_cgroup"; cat /proc/self/cgroup
echo "## ns";       readlink /proc/self/ns/cgroup; readlink /proc/self/ns/mnt
echo "## mountinfo"; grep -E 'cgroup' /proc/self/mountinfo
echo "## cgdir";    ls -la /sys/fs/cgroup 2>&1
for f in memory.max memory.high memory.current memory.stat cgroup.controllers cgroup.subtree_control; do
  printf '%-24s ' "$f"; head -1 "/sys/fs/cgroup/$f" 2>&1
done
echo "## mem";      grep -E 'MemTotal|SwapTotal' /proc/meminfo; nproc
echo "## selinux";  ls -Z /sys/fs/cgroup 2>&1 | head -3
echo "## java";     java -version 2>&1
echo "## flags";    java -XX:MaxRAMPercentage=70 -XX:InitialRAMPercentage=50 -XX:+PrintFlagsFinal -version 2>&1 \
                      | grep -E 'MaxHeapSize|InitialHeapSize|MaxRAM |UseContainerSupport'
echo "## trace";    java -Xlog:os+container=trace -XX:MaxRAMPercentage=70 -XX:InitialRAMPercentage=50 \
                      -XshowSettings:vm -version 2>&1
echo "## trace_exit=$?"
