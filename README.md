# JDK heap sized from node RAM instead of the container cgroup limit

A container with a cgroup v2 memory limit starts a JDK 21 with `-XX:InitialRAMPercentage=50
-XX:MaxRAMPercentage=70`, and the JVM ends up with a maximum heap larger than the container's memory
constraint — typically `MaxRAMPercentage × node RAM` instead of `MaxRAMPercentage × limit`. The result is a
cgroup OOM kill (exit 137) under load while the JVM's own GC still believes it has gigabytes of headroom.

This repository reproduces it, identifies **three distinct mechanisms** that produce the identical symptom,
and records the fixes and workarounds. Full evidence, traces and syscall-level proof: **[`findings.md`](findings.md)**.

## TL;DR

```bash
# in a 2 GiB cgroup: 21.0.5 reports 0.7 x NODE RAM, 21.0.10 reports 0.7 x LIMIT
# (prerequisites: see below - JDKs under ~/jdk, probes compiled into harness/java)
harness/cg-run.sh 2147483648 ~/jdk/amazon-corretto-21.0.5.11.1-linux-x64/bin/java \
  -XX:MaxRAMPercentage=70 -cp harness/java Probe
harness/cg-run.sh 2147483648 ~/jdk/amazon-corretto-21.0.10.7.1-linux-x64/bin/java \
  -XX:MaxRAMPercentage=70 -cp harness/java Probe
```

| build | `Runtime.maxMemory()` in a 2 GiB cgroup | meaning |
|---|---|---|
| 21.0.5 | `23035117568` (21.45 GiB = 0.7 × 30.64 GiB node) | **bug** — limit ignored |
| 21.0.10 | `1503657984` (1.40 GiB = 0.7 × 2 GiB limit) | correct |

## The three mechanisms

The symptom alone does not identify the cause; the JDK build and the container's cgroup view do.

| | Condition | What the JDK reads | Trace signature | Fix |
|---|---|---|---|---|
| **M1** | JDK ≤ 21.0.9 (also ≤ 17.0.19, ≤ 11.0.31, ≤ 8u511) | `/proc/cgroups`, which on newer kernels has **no `memory` row** (v1 memcg disabled) | `controller memory is not enabled` + `One or more required controllers disabled at kernel level.`, and **no** `Detected cgroups v2 unified hierarchy` line | JDK ≥ 21.0.10 |
| **M2** | JDK ≥ 21.0.10 **and** `/sys/fs/cgroup` inherited/bind-mounted from the host cgroup root (mountinfo root `≠ /`, often shown as `/../../../../..`) | builds the path as `mountpoint + /proc/self/cgroup`, ignoring the mountinfo root | `Detected cgroups v2 unified hierarchy` then `Open of file /sys/fs/cgroup/memory.max failed, No such file or directory` / `Memory Limit failed: -2` | mount a fresh cgroup2 fs at `/sys/fs/cgroup` inside the container |
| **M3** | JDK ≥ 21.0.10 **and** the process's cgroup has no `cpu` controller delegated (`cgroup.controllers` lacks `cpu`) | `/sys/fs/cgroup/cgroup.controllers` | source file named as `/sys/fs/cgroup/cgroup.controllers`, then `controller cpu is not enabled` + `One or more required controllers disabled at kernel level.` | delegate `cpu` **and** `memory` to the container's cgroup |

M1 is by far the most common. It is independent of the container runtime and of the image: the broken build
opens only `/proc/cgroups` and `/proc/meminfo` and never touches the cgroup filesystem at all, so no image or
mount layout can change its outcome. `/proc/cgroups` is a **kernel** file — the kernel, not the image, is the
trigger.

Version thresholds (first fixed release), upstream JDK-8349988:

| family | broken | fixed | upstream id |
|---|---|---|---|
| 21 | ≤ 21.0.9 | **21.0.10** | JDK-8371004 |
| 17 | ≤ 17.0.19 | 17.0.20 | JDK-8380682 |
| 11 | ≤ 11.0.31 | 11.0.32 | JDK-8383285 |
| 8 | ≤ 8u511 | 8u512 | JDK-8391548 |
| 25 | — | 25 GA | JDK-8349988 |

## Prerequisites

- Linux with cgroup v2 mounted at `/sys/fs/cgroup` (verified on kernel 7.2.9; reported on 6.12+).
- No root required. The harness creates a cgroup under your own systemd user slice; if your uid is not 1000,
  adjust `PARENT` in `harness/cg-run.sh` (`systemctl --user show -p Slice` or
  `cat /proc/self/cgroup`). Fallback if that cgroup is not writable:
  `systemd-run --user --scope -p MemoryMax=2G -p MemorySwapMax=0 <cmd>`.
- `bash`, `gcc`, `curl`, `bwrap` (bubblewrap, for the container-topology variants), ~250 MB per JDK download.
- Two JDK 21 builds bracketing the fix. Any vendor works; these URLs are verified:

```bash
mkdir -p ~/jdk && cd ~/jdk
for v in 21.0.5.11.1 21.0.10.7.1; do
  curl -fsSLO "https://corretto.aws/downloads/resources/$v/amazon-corretto-$v-linux-x64.tar.gz"
  tar -xzf "amazon-corretto-$v-linux-x64.tar.gz"
done
```

## Steps to reproduce

### 1. Confirm your kernel exposes the trigger (M1)

```bash
grep -c '^memory' /proc/cgroups          # 0 => the v1 memory controller is not listed
cat /proc/cgroups                        # this host: cpu cpuacct blkio ... pids rdma misc, no memory
grep MemTotal /proc/meminfo              # node RAM, used as the fallback heap source
```

### 2. Build the probes

```bash
cd /home/jamey/workspace/cgroup_bug
FIXED=~/jdk/amazon-corretto-21.0.10.7.1-linux-x64
$FIXED/bin/javac -d harness/java harness/java/Probe.java harness/java/Alloc.java
gcc -shared -fPIC -o harness/libopenlog.so harness/openlog.c -ldl
```

### 3. Run the two builds inside the same 2 GiB cgroup

`harness/cg-run.sh <limit-bytes> <cmd...>` writes `memory.max = 2 GiB`, `memory.swap.max = 0`, then puts itself
(and therefore the JVM) into that cgroup. Every run must go through it or through a container `--memory` flag —
never run the `-XX:InitialRAMPercentage=50` variant without a limit, it will commit ~15 GiB on the node.

```bash
harness/cg-run.sh 2147483648 ~/jdk/amazon-corretto-21.0.5.11.1-linux-x64/bin/java \
  -Xlog:os+container=trace -XX:MaxRAMPercentage=70 -XshowSettings:vm -cp harness/java Probe

harness/cg-run.sh 2147483648 ~/jdk/amazon-corretto-21.0.10.7.1-linux-x64/bin/java \
  -Xlog:os+container=trace -XX:MaxRAMPercentage=70 -XshowSettings:vm -cp harness/java Probe
```

Expected, on a 30.64 GiB node with a 2 GiB limit:

| | 21.0.5 (broken) | 21.0.10 (fixed) |
|---|---|---|
| trace | `controller cpu is not enabled`, `controller memory is not enabled`, `One or more required controllers disabled at kernel level.`, no `Detected cgroups` line | `Detected cgroups v2 unified hierarchy`, `Memory Limit is: 2147483648` |
| `-XshowSettings:vm` | `Max. Heap Size (Estimated): 21.45G` | `Max. Heap Size (Estimated): 1.40G` |
| `Runtime.maxMemory()` | `23035117568` (= 0.7 × node RAM) | `1503657984` (= 0.7 × limit) |

### 4. Reproduce the production failure

```bash
# broken: the JVM believes it has 21.45 GiB, never collects, and the cgroup kills it
harness/cg-run.sh 2147483648 ~/jdk/amazon-corretto-21.0.5.11.1-linux-x64/bin/java \
  -XX:MaxRAMPercentage=70 -XX:InitialRAMPercentage=50 -cp harness/java Alloc 4096
# => exit 137, memory.events: oom_kill 1, memory.peak = 2147483648 (exactly the limit)

# fixed: fails cleanly inside its own heap
harness/cg-run.sh 2147483648 ~/jdk/amazon-corretto-21.0.10.7.1-linux-x64/bin/java \
  -XX:MaxRAMPercentage=70 -XX:InitialRAMPercentage=50 -cp harness/java Alloc 4096
# => java.lang.OutOfMemoryError: Java heap space, exit 1, oom_kill 0
```

Note: with `-XX:InitialRAMPercentage=50` the broken build *prints* an initial heap of 15.34 GiB inside a 2 GiB
cgroup yet still starts (heap pages commit lazily, peak RSS ~71 MiB). The kill happens later, when the heap
actually grows — do not expect a boot-time death as the signature.

### 5. Prove the file accesses (no root; `strace` substitute)

```bash
harness/cg-run.sh 2147483648 env LD_PRELOAD=$PWD/harness/libopenlog.so \
  ~/jdk/amazon-corretto-21.0.5.11.1-linux-x64/bin/java -XX:MaxRAMPercentage=70 -cp harness/java Probe 2>&1 \
  | grep openlog
# => fopen64(/proc/cgroups), fopen64(/proc/meminfo) and nothing else cgroup-related

harness/cg-run.sh 2147483648 env LD_PRELOAD=$PWD/harness/libopenlog.so \
  ~/jdk/amazon-corretto-21.0.10.7.1-linux-x64/bin/java -XX:MaxRAMPercentage=70 -cp harness/java Probe 2>&1 \
  | grep openlog
# => /proc/self/cgroup, /sys/fs/cgroup/cgroup.controllers, the leaf memory.max and its whole ancestor chain,
#    and never /proc/cgroups
```

### 6. Full version × topology matrix

```bash
# fetch the two intermediate builds as well, to pin the flip between 21.0.9 and 21.0.10
cd ~/jdk
for v in 21.0.7.6.1 21.0.9.11.1; do
  curl -fsSLO "https://corretto.aws/downloads/resources/$v/amazon-corretto-$v-linux-x64.tar.gz"
  tar -xzf "amazon-corretto-$v-linux-x64.tar.gz"
done

cd /home/jamey/workspace/cgroup_bug
harness/run-matrix.sh ~/jdk/amazon-corretto-21.0.{5.11.1,7.6.1,9.11.1,10.7.1}-linux-x64
cat results/matrix.tsv
```

`harness/sandbox-run.sh` wraps a command in a bubblewrap sandbox with real user/pid/uts/ipc/**cgroup**/mount
namespaces (`/proc/self/cgroup` becomes `0::/`) to stand in for a container runtime without root:

| topology | `/sys/fs/cgroup` source |
|---|---|
| `owncgroup` | this process's own cgroup dir (mountinfo root `/`) — what a normal runtime produces |
| `owncgroup-nocpu` | same, but no `cpu` controller delegated (isolates M3) |
| `hostcgroup` | the host cgroup root (mountinfo root escapes, `/../../../../..`) — isolates M2 |

Verified result: broken builds are node-scaled in **every** topology; 21.0.10 is correct in `bare` and
`owncgroup`, node-scaled in `owncgroup-nocpu` (M3) and `hostcgroup` (M2).

### 7. Capture your own failing container

```bash
# run inside the failing container, overriding its command, and save the output
bash capture/collect.sh > results/work/collect.txt 2>&1
```

`collect.sh` prints, read-only: kernel, `/proc/cgroups`, `/proc/self/cgroup`, namespace ids, cgroup mountinfo,
the cgroup files, `MemTotal`, `java -version`, the ergonomic flags and a full `-Xlog:os+container=trace` run.
Its header contains the same M1/M2/M3 decision guide as above. The two files that matter most are
`/proc/cgroups` and `/sys/fs/cgroup/cgroup.controllers`.

## Remediation

### Identify which mechanism you have

| In `results/work/collect.txt` | Mechanism | Do this |
|---|---|---|
| `## java` is ≤ 21.0.9 (≤ 17.0.19 / ≤ 11.0.31 / ≤ 8u511), and `## proc_cgroups` has no `memory` row | **M1** | upgrade the JDK (or use the workaround below) |
| trace has `Detected cgroups v2 unified hierarchy` + `Open of file .../memory.max failed, No such file or directory`, or `## mountinfo` shows a cgroup2 line whose 5th field is not `/` (e.g. `/../../../../..`) | **M2** | fix the mount (below), or use the workaround |
| trace names `/sys/fs/cgroup/cgroup.controllers`, `## cgroup.controllers` (or `/sys/fs/cgroup/cgroup.controllers`) lacks `cpu` | **M3** | delegate `cpu` + `memory` to the cgroup, or use the workaround |

### Fix properly

1. **M1 — upgrade the JDK.** Move the image to ≥ 21.0.10 (or ≥ 17.0.20 / ≥ 11.0.32 / ≥ 8u512 / any 25). The
   same update train is fixed in every vendor (Temurin, Corretto, Azul, Red Hat); confirm with the trace
   (`Detected cgroups v2 unified hierarchy` + `Memory Limit is: <your limit>`), not with the version string
   alone. Note 21.0.7–21.0.9 are still broken on kernels that also drop `memory`.
2. **M2 — stop handing the container the host's cgroup mount.** Run with a private cgroup namespace and let the
   runtime mount cgroup2 at `/sys/fs/cgroup` (`--cgroupns=private`, and do **not** pass
   `-v /sys/fs/cgroup:/sys/fs/cgroup`); in Kubernetes avoid a `hostPath` mount of `/sys/fs/cgroup`. The JDK
   then sees a mount whose root is `/` and resolves `memory.max` correctly.
3. **M3 — delegate both controllers.** Make sure `cpu` and `memory` are enabled for the cgroup the process runs
   in (systemd `Delegate=cpu memory`, or `cpu` present in `cgroup.controllers` for that cgroup). The fixed
   detection requires `cpu`; `cpuset` and `pids` are optional.

### Workaround when the image (or the JDK in it) cannot be changed

Only the RAM *source* needs pinning; all of these were verified to make the broken 21.0.5 behave exactly like
21.0.10 (`maxMemory=1503657984`, `totalMemory=1075838976`) and to turn the 4 GiB allocation into a clean
`OutOfMemoryError` instead of a cgroup kill:

```bash
# 1. no command-line change needed - best when the entrypoint is baked into the image
JAVA_TOOL_OPTIONS="-XX:MaxRAM=2147483648 -XX:MaxRAMPercentage=70 -XX:InitialRAMPercentage=50"

# 2. or pin the source explicitly (MaxRAM becomes phys_mem, so the percentages scale the limit)
java -XX:MaxRAM=2147483648 -XX:MaxRAMPercentage=70 -XX:InitialRAMPercentage=50 ...

# 3. or drop the percentages entirely
java -Xmx1433m ...        # 0.7 x a 2 GiB limit
```

Set `MaxRAM` (or `-Xmx`) to your container limit and scale by your percentage. If you only need the JVM to
stop overshooting and can give up dynamic sizing, a bare `-Xmx` is the smallest change.

Do **not** bother with `-XX:+UseContainerSupport` — it is on by default, and the detection it enables is
exactly what is bailing out.

## Layout

| Path | Purpose |
|---|---|
| `findings.md` | root-cause write-up with traces, matrix, thresholds, verified workarounds |
| `capture/collect.sh` | read-only capture to run inside the failing container (header = M1/M2/M3 decision guide) |
| `harness/cg-run.sh` | run a command inside a fresh cgroup v2 with `memory.max`/`memory.swap.max` set |
| `harness/sandbox-run.sh` | bubblewrap sandbox giving container-like namespaces + a chosen `/sys/fs/cgroup` view |
| `harness/sandbox-probe.sh` | prints the cgroup view (namespaces, `/proc/self/cgroup`, mountinfo, cgroup files) as a JDK would resolve it |
| `harness/run-matrix.sh` | build × topology matrix → `results/matrix.tsv` |
| `harness/java/Probe.java` | prints `Runtime.maxMemory()`/`totalMemory()` — ground truth from inside the JVM |
| `harness/java/Alloc.java` | allocates N MiB live to trigger the cgroup kill vs a Java OOM |
| `harness/openlog.c` | LD_PRELOAD open() logger (rootless `strace` substitute) |
| `results/matrix.tsv`, `results/local/`, `results/work/` | generated artifacts (safe to regenerate) |

## References

- JDK-8349988 "Change cgroup version detection logic to not depend on /proc/cgroups" (fix; 25 GA, backported to
  21.0.10 / 17.0.20 / 11.0.32 / 8u512) — https://bugs.openjdk.org/browse/JDK-8349988
- JDK-8348566 "OpenJDK is not respecting cgroupv2" (reported on kernel 6.12 with a 21.0.5 build; closed as a
  duplicate of the above) — https://bugs.openjdk.org/browse/JDK-8348566
- JDK-8347811 / JDK-8349988 history: 21.0.7 only made `cpuset` optional, which is why 21.0.7–21.0.9 remain
  broken when `memory` is also absent from `/proc/cgroups`.
- Kernel side: cgroup v1 memory-controller support being disabled makes `/proc/cgroups` omit the `memory` row.
  `/proc/cgroups` and `/proc/meminfo` are not namespaced, so containers see the node's values.
