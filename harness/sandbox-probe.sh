#!/bin/sh
# Prints the cgroup view exactly as a JDK would resolve it. Run inside a container/bwrap sandbox.
echo "id=$(id -u)"
echo "ns_cgroup=$(readlink /proc/self/ns/cgroup)"
echo "ns_mnt=$(readlink /proc/self/ns/mnt)"
echo "self_cgroup_raw=$(cat /proc/self/cgroup)"
p=$(cut -d: -f3 /proc/self/cgroup)
echo "self_cgroup_path=$p"
echo "jdk_resolved_memory_max=/sys/fs/cgroup$p/memory.max"
echo "--- reads at the JDK-resolved path ---"
printf 'memory.max = '; cat "/sys/fs/cgroup$p/memory.max" 2>&1
printf 'memory.high = '; cat "/sys/fs/cgroup$p/memory.high" 2>&1
echo "--- reads at /sys/fs/cgroup directly ---"
printf 'memory.max = '; cat /sys/fs/cgroup/memory.max 2>&1
printf 'cgroup.controllers = '; cat /sys/fs/cgroup/cgroup.controllers 2>&1
echo "--- cgroup mountinfo ---"
grep -E 'cgroup2? ' /proc/self/mountinfo
echo "--- ls /sys/fs/cgroup ---"
ls /sys/fs/cgroup 2>&1 | head -8
echo "--- /proc/cgroups (first columns) ---"
awk '{print $1, $2, $4}' /proc/cgroups | head -8
grep -c '^memory' /proc/cgroups 2>/dev/null | sed 's/^/memory_lines_in_proc_cgroups=/'
