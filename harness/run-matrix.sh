#!/usr/bin/env bash
# Phase 3: run each (JDK build x topology) cell inside a 2 GiB cgroup; write results/matrix.tsv.
# The JVM reports its own ergonomic heap (Probe prints Runtime.maxMemory()/totalMemory()).
# Topologies:
#   bare            : no sandbox, process entered into the cgroup directly
#   owncgroup       : bwrap sandbox (user/pid/uts/ipc/cgroup/mount ns); /sys/fs/cgroup bound from
#                     this process's own cgroup dir, so mountinfo root = /
#   owncgroup-nocpu : same as owncgroup, but the cgroup has no 'cpu' controller delegated
#                     (its cgroup.controllers lacks cpu)
#   hostcgroup      : bwrap sandbox; /sys/fs/cgroup bound from the host cgroup root, so the
#                     mountinfo root escapes (rendered /../../../../..) under a private cgroup ns
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

LIMIT=2147483648
PARENT=/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/app.slice
CG=$PARENT/jvmtest
OUT=results/matrix.tsv
JDKS=("$@")
MEMTOTAL_BYTES=$(awk '/^MemTotal:/{print $2*1024}' /proc/meminfo)
EXPECT_BUG=$(awk -v m="$MEMTOTAL_BYTES" 'BEGIN{printf "%.2f", m*0.7/1073741824}')
EXPECT_OK=$(awk -v l="$LIMIT" 'BEGIN{printf "%.2f", l*0.7/1073741824}')
PROC_CG_MEM=$(grep -c '^memory' /proc/cgroups)

cell() {
  local home="$1" lbl="$2" sbx="$3" jdk ver log runner=() det lim max_i max_g tot_g verdict ctrl
  jdk=$(basename "$home")
  ver=$("$home/bin/java" -version 2>&1 | head -1 | sed 's/.*"\(.*\)".*/\1/')
  log="results/local/cell-${jdk}-${lbl}.txt"
  [ "$sbx" = "bare" ] || runner=(harness/sandbox-run.sh "$sbx")

  harness/cg-run.sh "$LIMIT" "${runner[@]}" "$home/bin/java" \
    -Xlog:os+container=trace -XX:MaxRAMPercentage=70 -cp harness/java Probe > "$log" 2>&1
  ctrl=$(tr ' ' ',' < "$CG/cgroup.controllers" 2>/dev/null)

  det=$(grep -c 'Detected cgroups v2 unified hierarchy' "$log")
  lim=$(grep -o 'Memory Limit is: [0-9-]*' "$log" | head -1 | awk '{print $NF}')
  max_i=$(grep -o 'maxMemory=[0-9]*' "$log" | head -1 | cut -d= -f2)
  tot_g=$(grep -o 'totalMemoryGiB=[0-9.]*' "$log" | head -1 | cut -d= -f2)
  if [ -z "$max_i" ]; then
    verdict="NO-HEAP-REPORTED"; max_g="none"
  else
    max_g=$(awk -v m="$max_i" 'BEGIN{printf "%.2f", m/1073741824}')
    if awk -v a="$max_g" -v b="$EXPECT_OK" 'BEGIN{exit !(a<b+0.05 && a>b-0.05)}'; then
      verdict="CORRECT(limit-scaled)"
    elif awk -v a="$max_g" -v b="$EXPECT_BUG" 'BEGIN{exit !(a<b+0.05 && a>b-0.05)}'; then
      verdict="BUG(node-scaled)"
    else
      verdict="UNEXPECTED($max_g GiB)"
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$jdk" "$ver" "$lbl" "$PROC_CG_MEM" "$det" "${lim:-none}" "${max_i:-none}" "$max_g" "${tot_g:-none}" "$verdict" "$ctrl" | tee -a "$OUT"
  awk '/oom_kill/{print "        cgroup oom_kill=" $2}' "$CG/memory.events"
  rmdir "$CG" 2>/dev/null
}

run_cell() { local d="$1"; shift; export DELEGATE="$d"; cell "$@"; }

echo "# MemTotal=$MEMTOTAL_BYTES B; expect node-scaled(BUG)=${EXPECT_BUG} GiB, limit-scaled(CORRECT)=${EXPECT_OK} GiB; /proc/cgroups memory lines=$PROC_CG_MEM"
printf 'build\tjdk_version\ttopology\tproc_cgroups_memory\tdetected_v2\tlimit_line\tmaxMemory_bytes\tmaxMemory_GiB\tinitial_GiB\tverdict\tcgroup.controllers\n' > "$OUT"

for home in "${JDKS[@]}"; do
  run_cell "+cpu +memory +pids" "$home" bare            bare
  run_cell "+cpu +memory +pids" "$home" owncgroup       owncgroup
  run_cell "-cpu +memory +pids" "$home" owncgroup-nocpu owncgroup
  run_cell "+cpu +memory +pids" "$home" hostcgroup      hostcgroup
done
