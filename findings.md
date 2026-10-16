# JDK 21 in an OCI container: percentage heap sized from node RAM instead of the cgroup limit

**Answer.** The symptom is real and reproduced end to end on this workstation (kernel 7.2.9, `MemTotal`
32903991296 B, `/proc/cgroups` has **no `memory` row**). A JDK 21.0.5 started with
`-XX:InitialRAMPercentage=50 -XX:MaxRAMPercentage=70` inside a 2 GiB cgroup reports
`Runtime.maxMemory() = 23035117568` (21.45 GiB = 0.7 × node RAM) and is OOM-killed by the cgroup at exactly
the limit once it grows; 21.0.10 in the same cgroup reports `1503657984` (1.40 GiB = 0.7 × limit).

**Three different mechanisms produce that identical symptom.** Which one applies is decided by the JDK build
and by the container's cgroup view — not by the image itself:

| | Condition | Trigger source | Present in |
|---|---|---|---|
| **M1** | JDK ≤ 21.0.9 (also ≤ 17.0.19, ≤ 11.0.31, ≤ 8u511) | `/proc/cgroups` | every topology tested (4/4) |
| **M2** | JDK ≥ 21.0.10 **and** `/sys/fs/cgroup` inherited/bind-mounted from the host cgroup root (mountinfo root ≠ `/`, often rendered `/../../../../..`) | cgroup2 path resolution | `hostcgroup` topology |
| **M3** | JDK ≥ 21.0.10 **and** the process's cgroup has no `cpu` controller delegated (`cgroup.controllers` lacks `cpu`) | `/sys/fs/cgroup/cgroup.controllers` | `owncgroup-nocpu` topology |

For the work environment the decisive facts are (a) the exact `java -version` patch level in the image and
(b) the two files captured by `capture/collect.sh`: `/proc/cgroups` and `/sys/fs/cgroup/cgroup.controllers`.
M1 is by far the most likely: it needs nothing but a JDK older than 21.0.10 on a kernel whose `/proc/cgroups`
omits the v1 `memory` controller, and it reproduces **identically with and without a container**, so an OCI
image cannot prevent it or cause it.

## Environment

| | |
|---|---|
| Host | Debian forky/sid, kernel 7.2.9+deb14-amd64, 12 CPUs, `MemTotal=32903991296` B (30.64 GiB), cgroup2 mounted at `/sys/fs/cgroup` (rw, `nsdelegate`) |
| `/proc/cgroups` | lists `cpu cpuacct blkio devices freezer net_cls perf_event net_prio hugetlb pids rdma misc` — **no `memory`, no `cpuset`** (`grep -c '^memory' /proc/cgroups` → `0`) |
| Container limit used in all experiments | `memory.max = 2147483648`, `memory.swap.max = 0` |
| JDK builds | Corretto 21.0.5.11.1, 21.0.7.6.1, 21.0.9.11.1 (broken) and 21.0.10.7.1 (fixed) |
| Reproduction tools | `harness/cg-run.sh` (cgroup wrapper), `harness/sandbox-run.sh` (bwrap sandbox = user/pid/uts/ipc/**cgroup**/mount namespaces), `harness/java/Probe.java` (prints `Runtime.maxMemory()`/`totalMemory()`), `harness/openlog.c` (LD_PRELOAD open logger, used instead of `strace`), `harness/run-matrix.sh` |

Verified ergonomic values (2 GiB limit, `-XX:MaxRAMPercentage=70`, `-XX:InitialRAMPercentage=50`):

| build | `maxMemory` | `totalMemory` | verdict |
|---|---|---|---|
| 21.0.5.11.1 | 23035117568 (21.45 GiB) | 16475226112 (15.34 GiB) | node-scaled — **bug** |
| 21.0.10.7.1 | 1503657984 (1.40 GiB) | 1075838976 (1.00 GiB) | limit-scaled — correct |

## M1 — `/proc/cgroups`-based detection bails out (JDK ≤ 21.0.9)

`CgroupSubsystemFactory::determine_type()` in 21.0.5/21.0.7/21.0.9 always opens `/proc/cgroups` and requires
the `memory`, `cpu` and `cpuacct` rows to be present, `enabled == 1` and `hierarchy_id == 0` (cpuset/pids are
optional as of 21.0.7). With `memory` missing it hits:

```c
if (!all_required_controllers_enabled) {
    log_debug(os, container)("One or more required controllers disabled at kernel level.");
    cleanup(cg_infos);
    *flags = INVALID_CGROUPS_GENERIC;
    return false;                       // -> create() returns nullptr -> container support off
}
```
(`src/hotspot/os/linux/cgroupSubsystem_linux.cpp`, `determine_type`; identical in the 21.0.5+11, 21.0.9+10 sources.)

Container support is then disabled wholesale, so `os::physical_memory()` returns
`Linux::physical_memory()` = `/proc/meminfo` `MemTotal` (node RAM, *not* namespaced), and
`Arguments::set_heap_size()` computes `MaxHeapSize = MaxRAMPercentage × phys_mem` and
`InitialHeapSize = InitialRAMPercentage × phys_mem`.

Trace (`results/local/amazon-corretto-21.0.5.11.1-linux-x64.txt`):

```
[debug][os,container] Detected optional pids controller entry in /proc/cgroups
[debug][os,container] controller cpu is not enabled
[debug][os,container] controller memory is not enabled
[debug][os,container] One or more required controllers disabled at kernel level.
```

Independent syscall-level evidence (LD_PRELOAD logger applied to the JVM process only, so the harness's own
writes are not in the trace, `results/local/access-21.0.5.11.1.txt`): the JVM opens exactly
`/proc/cgroups`, `/proc/meminfo` and its class file — **it never opens `cgroup.controllers` or any
`memory.max`**, i.e. it gives up before touching the cgroup filesystem at all. The fixed build's trace
(`access-21.0.10.7.1.txt`) is the mirror image: `/proc/self/cgroup` +
`/sys/fs/cgroup/cgroup.controllers` + the leaf `memory.max` and its whole ancestor chain, and **no
`/proc/cgroups`**. This is why no container layout can change M1's outcome.

Production failure mode (`results/local/R6-broken-2g-alloc4g.txt`): a process that allocates 4 GiB live data
inside the 2 GiB cgroup was **killed by the cgroup** — exit 137, `memory.events: oom_kill 1`,
`memory.peak = 2147483648` (exactly the limit), because the JVM believed its maximum heap was 21.45 GiB and so
never collected. The same allocation on 21.0.10 fails cleanly inside its own heap
(`java.lang.OutOfMemoryError: Java heap space`, exit 1, `oom_kill 0`, peak 1.46 GiB —
`results/local/R7-fixed-2g-alloc4g.txt`).

Note on startup: with `-XX:InitialRAMPercentage=50` the broken build *reports* an initial heap of 15.34 GiB
inside a 2 GiB cgroup but does not die at startup — heap pages are committed lazily (peak RSS 74690560 B ≈ 71 MiB,
`results/local/R2-broken-2g-70-50.txt`). The cgroup kill happens later, when the heap actually grows. Do not
expect "container dies immediately at boot" as the signature.

## M2 — cgroup2 mount root ignored (JDK ≥ 21.0.10, host cgroup fs bound)

Detection succeeds (`Detected cgroups v2 unified hierarchy`) but the path the JDK builds is
`mount_point + /proc/self/cgroup path`; the mountinfo **root field is ignored for cgroup v2** (upstream comment
on `CgroupInfo::_root_mount_path`: "Unused for cgroup v2"). When the container has a private cgroup namespace
but `/sys/fs/cgroup` is the host's cgroup2 mount, mountinfo shows root `/../../../../..`, `/proc/self/cgroup`
shows `0::/`, and the JDK resolves `/sys/fs/cgroup/memory.max` — which does not exist (the host root cgroup
exposes no `memory.max`).

Trace (`results/local/cell-amazon-corretto-21.0.10.7.1-linux-x64-hostcgroup.txt`):

```
[debug][os,container] Detected cgroups v2 unified hierarchy
[debug][os,container] Open of file /sys/fs/cgroup/memory.max failed, No such file or directory
[trace][os,container] Memory Limit failed: -2
```
→ `maxMemory = 23035117568` (node-scaled) in a 2 GiB cgroup, i.e. **the bug survives a JDK upgrade** in this
topology. Check with `grep cgroup /proc/self/mountinfo`: a cgroup2 line whose 5th field is not `/`.
This is the topology produced by `--cgroupns=host` plus a bind of the host cgroup root, or by images/entry
scripts that mount the host cgroup fs themselves — i.e. the one case where the *image* really is implicated.

## M3 — required `cpu` controller not delegated (JDK ≥ 21.0.10)

The fixed detection reads `/sys/fs/cgroup/cgroup.controllers` and requires `cpu` **and** `memory` there.
`cgroup.controllers` lists what the parent delegated to that cgroup, so a cgroup that only has memory
delegated fails even on a fixed JDK. In this harness the test cgroup had `cgroup.controllers = "memory pids"`
(systemd's `app.slice` does not delegate `cpu` to children):

Trace (`results/local/cell-amazon-corretto-21.0.10.7.1-linux-x64-owncgroup-nocpu.txt`):

```
[debug][os,container] Detected optional pids controller entry in /sys/fs/cgroup/cgroup.controllers
[debug][os,container] controller cpuset is not enabled
[debug][os,container] controller cpu is not enabled
[debug][os,container] One or more required controllers disabled at kernel level.
```
→ node-scaled. With `cpu` delegated (`cpu,memory,pids`) the same build in the same topology reports
`1503657984` (limit-scaled, `...-owncgroup.txt`). Verified only in this harness so far; whether the work
containers delegate `cpu` is what `## cgroup.controllers` in `results/work/collect.txt` will show.

## Version thresholds

Behavioural (this host, 16-cell matrix in `results/matrix.tsv`) — `BUG` = `maxMemory ≈ 0.7 × 32903991296`,
`CORRECT` = `maxMemory ≈ 0.7 × 2147483648`:

| build | bare | owncgroup | owncgroup-nocpu | hostcgroup |
|---|---|---|---|---|
| 21.0.5 | BUG | BUG | BUG | BUG |
| 21.0.7 | BUG | BUG | BUG | BUG |
| 21.0.9 | BUG | BUG | BUG | BUG |
| 21.0.10 | CORRECT | CORRECT | BUG (M3) | BUG (M2) |

Source-level: 21.0.9+10 still has the `/proc/cgroups` logic (8 refs, 0 `cgroup.controllers` refs); 21.0.10+7 has
`statfs("/sys/fs/cgroup") == CGROUP2_SUPER_MAGIC` + `/sys/fs/cgroup/cgroup.controllers` (2 refs). 21.0.7 only
made `cpuset` optional (JDK-8347811), which is why 21.0.7–21.0.9 remain broken on kernels that also drop
`memory`.

| family | broken | first fixed | upstream |
|---|---|---|---|
| 21 | ≤ 21.0.9 | **21.0.10** | JDK-8371004 → JDK-8349988 |
| 17 | ≤ 17.0.19 | 17.0.20 | JDK-8380682 |
| 11 | ≤ 11.0.31 | 11.0.32 | JDK-8383285 |
| 8 | ≤ 8u511 | 8u512 | JDK-8391548 |
| 25 | — | 25 GA | JDK-8349988 |
| 24 | affected | — | fix not backported to 24 |

Upstream context: JDK-8348566 ("OpenJDK is not respecting cgroupv2", reported on kernel 6.12 with Red Hat
21.0.5, closed as duplicate of JDK-8349988 "Change cgroup version detection logic to not depend on
/proc/cgroups"). The kernel is central, not incidental: it decides what `/proc/cgroups` contains.

## Workarounds (all verified on this host)

1. **Bump the JDK in the image** to ≥ 21.0.10 (or ≥ 17.0.20 / ≥ 11.0.32 / ≥ 8u512 / any 25). Fixes M1 only —
   M2 and M3 still need their conditions removed.
2. **Pin the RAM source when the image cannot change** (`results/local/W1`–`W4`): the broken 21.0.5 then
   behaves exactly like 21.0.10.
   - `-XX:MaxRAM=<limit-in-bytes>` alongside the percentages (with `MaxRAM` set, `phys_mem` becomes that
     value, so `MaxRAMPercentage` scales the limit): `maxMemory=1503657984` (1.40 GiB),
     `totalMemory=1075838976` (1.00 GiB).
   - or plain `-Xmx1433m` → same numbers.
   - Without touching the container command line: `JAVA_TOOL_OPTIONS="-XX:MaxRAM=2147483648
     -XX:MaxRAMPercentage=70 -XX:InitialRAMPercentage=50"` → `maxMemory=1503657984` (JVM logs
     "Picked up JAVA_TOOL_OPTIONS: ...").
   - With the workaround the 4 GiB allocation fails as `OutOfMemoryError` (exit 1, `oom_kill 0`) instead of
     being OOM-killed by the cgroup.
3. **For M2**: give the container a fresh cgroup2 mount at `/sys/fs/cgroup` (private cgroup namespace, no host
   cgroup bind), or drop the host cgroup bind.
4. **For M3**: delegate both `cpu` and `memory` to the container's cgroup.
5. `-XX:+UseContainerSupport` is not a lever — it is on by default, and the detection it gates is what bails out.

## Reproduce it

```bash
# 1 GiB+ of JDK tarballs into ~/jdk (URLs verified 200):
#   21.0.5.11.1, 21.0.7.6.1, 21.0.9.11.1 (broken), 21.0.10.7.1 (fixed)
#   https://corretto.aws/downloads/resources/<VER>/amazon-corretto-<VER>-linux-x64.tar.gz

cd /home/jamey/workspace/cgroup_bug
FIXED=~/jdk/amazon-corretto-21.0.10.7.1-linux-x64
$FIXED/bin/javac -d harness/java harness/java/Probe.java harness/java/Alloc.java
gcc -shared -fPIC -o harness/libopenlog.so harness/openlog.c -ldl

# heap = 0.7 x node RAM (bug) vs 0.7 x limit (correct); each runs inside a 2 GiB cgroup with no swap
harness/cg-run.sh 2147483648 ~/jdk/amazon-corretto-21.0.5.11.1-linux-x64/bin/java  -XX:MaxRAMPercentage=70 -XshowSettings:vm -cp harness/java Probe
harness/cg-run.sh 2147483648 ~/jdk/amazon-corretto-21.0.10.7.1-linux-x64/bin/java -XX:MaxRAMPercentage=70 -XshowSettings:vm -cp harness/java Probe

# production symptom: cgroup kill instead of a Java OOM
harness/cg-run.sh 2147483648 ~/jdk/amazon-corretto-21.0.5.11.1-linux-x64/bin/java -XX:MaxRAMPercentage=70 -XX:InitialRAMPercentage=50 -cp harness/java Alloc 4096

# full version x topology matrix -> results/matrix.tsv
harness/run-matrix.sh ~/jdk/amazon-corretto-21.0.{5.11.1,7.6.1,9.11.1,10.7.1}-linux-x64
```

## Artifacts

| Path | Contents |
|---|---|
| `results/matrix.tsv` | 16 cells: build × topology × detection × `maxMemory` × cgroup.controllers × verdict |
| `results/local/amazon-corretto-21.0.5.11.1-linux-x64.txt` | full `-Xlog:os+container=trace` for the broken build |
| `results/local/amazon-corretto-21.0.10.7.1-linux-x64.txt` | full trace for the fixed build (path walk, limit 2147483648) |
| `results/local/access-*.txt` | LD_PRELOAD open() traces: broken → only `/proc/cgroups`; fixed → `cgroup.controllers` + `memory.max` chain, no `/proc/cgroups` |
| `results/local/R1,R2,R3,R4,R5` | heap values in-cgroup and on the host (host runs cannot distinguish correct from broken: both print 21.45 GiB) |
| `results/local/R6,R7` | 4 GiB allocation: cgroup OOM kill (broken) vs Java `OutOfMemoryError` (fixed) |
| `results/local/W1–W4` | `-XX:MaxRAM` / `-Xmx` / `JAVA_TOOL_OPTIONS` workarounds, verified |
| `results/local/cell-*` | per-cell traces behind `matrix.tsv` |

## Deviations from the plan and what is still open

- **No root on this workstation** (`sudo` needs a password), so `podman`/`docker.io` were not installed and
  `capture/collect.sh` has not been run against the failing work container. Instead the container topology was
  reproduced with `bwrap`, which does create a real cgroup namespace (`/proc/self/cgroup = 0::/`) plus user,
  pid, uts, ipc and mount namespaces — sufficient, because M1's decision input (`/proc/cgroups`) is a kernel
  file identical in and out of any container, and M2/M3 were reproduced by their actual filesystem/delegation
  conditions. Unprivileged `unshare -c` cannot create a cgroup namespace here (the cgroup belongs to the init
  user namespace), hence bwrap.
- **`strace` was replaced** by an LD_PRELOAD logger (`harness/openlog.c`) — same evidence class (observed file
  access), no root needed.
- If you want the rootful-runtime confirmation: `sudo apt-get install -y podman uidmap strace jq`, then
  `podman run --rm --memory=2g --memory-swap=2g -v ~/jdk:/jdk:ro docker.io/library/debian:stable-slim
  /jdk/amazon-corretto-21.0.5.11.1-linux-x64/bin/java -Xlog:os+container=trace -XX:MaxRAMPercentage=70
  -XshowSettings:vm -version`. Expected: the same node-scaled 21.45G, because M1 never reads the cgroup fs.
- **Still needed from the work environment** (`capture/collect.sh` → `results/work/collect.txt`): the image's
  `java -version` patch level, `## proc_cgroups`, `## cgroup.controllers`, `## mountinfo`, and the trace. Those
  four lines select M1 vs M2 vs M3; the interpretation guide for them is in the header of `capture/collect.sh`.
  Until that capture exists, the local evidence above establishes the mechanisms, not which one your
  production incident hit.
