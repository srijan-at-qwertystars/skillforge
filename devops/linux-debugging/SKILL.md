---
name: linux-debugging
description:
  positive: "Use when user debugs Linux processes, asks about strace, ltrace, perf, eBPF, bpftrace, flamegraphs, /proc, core dumps, memory leaks (valgrind), or system performance analysis."
  negative: "Do NOT use for application-level debugging (GDB breakpoints, IDE debuggers), Windows performance tools, or container orchestration troubleshooting (use kubernetes-troubleshooting skill)."
---

# Linux Debugging & Performance Analysis

## Process Inspection

List processes with resource usage:

```bash
ps aux --sort=-%mem | head -20          # top memory consumers
ps -eo pid,ppid,cmd,%cpu,%mem --sort=-%cpu | head  # top CPU consumers
```

Interactive monitoring:

```bash
top -bn1 | head -20     # batch mode snapshot
htop -t                  # tree view (interactive)
```

### /proc Filesystem

```bash
cat /proc/<pid>/status      # process state, memory, threads
cat /proc/<pid>/maps        # memory mappings
cat /proc/<pid>/fd          # open file descriptors (ls -la)
cat /proc/<pid>/stack       # kernel stack trace
cat /proc/<pid>/io          # read/write byte counters
cat /proc/<pid>/limits      # resource limits
cat /proc/<pid>/cmdline | tr '\0' ' '   # full command line
```

### Open Files and Sockets

```bash
lsof -p <pid>               # all open files for a process
lsof -i :8080               # who is listening on port 8080
lsof +D /var/log            # all open files under directory
fuser -v /var/log/syslog    # which processes use this file
fuser -k 8080/tcp           # kill process holding port 8080
```

---

## strace — Syscall Tracing

Trace a running process:

```bash
strace -p <pid>                         # attach to process
strace -p <pid> -e trace=open,read,write  # filter specific syscalls
strace -p <pid> -e trace=network        # network syscalls only
strace -p <pid> -f                      # follow child processes
```

Run a command under strace:

```bash
strace -o /tmp/trace.log ./myapp        # save output to file
strace -T ./myapp                       # show time spent in each syscall
strace -t ./myapp                       # timestamp each line
strace -c ./myapp                       # summary: count, time per syscall
# % time     seconds  usecs/call     calls    errors syscall
# ------ ----------- ----------- --------- --------- ----------------
#  45.23    0.004312          12       359           read
#  30.11    0.002870           8       358           write
```

Common patterns:

```bash
strace -e trace=open,openat ./myapp 2>&1 | grep -v ENOENT  # find config files read
strace -e trace=open,openat,access ./myapp 2>&1 | grep EACCES  # permission denied
strace -T ./myapp 2>&1 | awk -F'<' '{if ($2+0 > 0.1) print}'  # slow syscalls (>100ms)
```

---

## ltrace — Library Call Tracing

Trace dynamic library calls:

```bash
ltrace ./myapp                          # all library calls
ltrace -e malloc+free ./myapp           # filter malloc/free
ltrace -e 'getenv*' ./myapp             # trace getenv calls
ltrace -c ./myapp                       # summary: call counts and time
ltrace -p <pid>                         # attach to running process
```

strace vs ltrace: strace traces kernel syscalls; ltrace traces userspace library calls (libc, libpthread, etc.). Use ltrace to debug library-level behavior (string ops, memory allocation patterns). Use strace for I/O, networking, permissions.

---

## perf — Performance Profiling

### Quick Stats

```bash
perf stat ./myapp
# Performance counter stats for './myapp':
#       2,341.52 msec task-clock
#          1,203 context-switches
#             42 cpu-migrations
#         12,481 page-faults
#  8,234,567,890 cycles
#  6,123,456,789 instructions   # 0.74 insn per cycle
#    987,654,321 cache-misses

perf stat -e cycles,instructions,cache-misses,branch-misses ./myapp
perf stat -p <pid> sleep 10     # profile running process for 10s
```

### Record and Report

```bash
perf record -g ./myapp          # record with call graphs
perf record -F 99 -p <pid> -g -- sleep 30  # sample at 99Hz for 30s
perf report                     # interactive TUI report
perf report --stdio             # text-based report
```

### Live Monitoring

```bash
perf top                        # live function profiling (system-wide)
perf top -p <pid>               # live profiling of one process
```

### Hardware Counters

```bash
perf list hardware              # list available hardware events
perf stat -e L1-dcache-load-misses,LLC-load-misses ./myapp
perf stat -e dTLB-load-misses ./myapp   # TLB pressure
```

---

## Flamegraphs

### Generate with perf

```bash
# 1. Record call stacks
perf record -F 99 -ag -- sleep 30

# 2. Generate flamegraph (Brendan Gregg's tools)
perf script | stackcollapse-perf.pl | flamegraph.pl > flamegraph.svg

# Or with perf's built-in support (newer kernels)
perf script report flamegraph
```

### Interpretation

- **Width** = proportion of total samples (wider = more CPU time).
- **Y-axis** = stack depth (bottom is on-CPU entry, top is leaf function).
- **Color** = random; no semantic meaning by default.
- Look for **wide plateaus** — those are the hot functions consuming CPU.

### Differential Flamegraphs

Compare before/after performance:

```bash
# Record baseline and test
perf script -i perf-before.data | stackcollapse-perf.pl > before.folded
perf script -i perf-after.data | stackcollapse-perf.pl > after.folded
difffolded.pl before.folded after.folded | flamegraph.pl > diff.svg
```

Red = regression (more samples), blue = improvement (fewer samples).

### speedscope

Alternative viewer — load `perf script` output directly at https://speedscope.app or install locally. Supports time-ordered, left-heavy, and sandwich views.

---

## eBPF and bpftrace

### bpftrace One-Liners

```bash
# Count syscalls by process
bpftrace -e 'tracepoint:raw_syscalls:sys_enter { @[comm] = count(); }'

# Trace process creation
bpftrace -e 'tracepoint:syscalls:sys_enter_execve { printf("%s: %s\n", comm, str(args.filename)); }'

# Histogram of read() sizes
bpftrace -e 'tracepoint:syscalls:sys_exit_read /args.ret > 0/ { @= hist(args.ret); }'

# Trace file opens with path
bpftrace -e 'tracepoint:syscalls:sys_enter_openat { printf("%s %s\n", comm, str(args.filename)); }'

# Block I/O latency histogram
bpftrace -e 'kprobe:blk_account_io_start { @start[arg0] = nsecs; }
  kprobe:blk_account_io_done /@start[arg0]/ {
    @usecs = hist((nsecs - @start[arg0]) / 1000); delete(@start[arg0]); }'

# Kernel stack trace on context switch
bpftrace -e 'tracepoint:sched:sched_switch { @[kstack] = count(); }'
```

### Probe Types

| Type | Target | Example |
|------|--------|---------|
| tracepoint | Stable kernel hooks | `tracepoint:syscalls:sys_enter_read` |
| kprobe | Any kernel function | `kprobe:tcp_sendmsg` |
| uprobe | User-space function | `uprobe:/usr/bin/app:main` |
| usdt | App-defined probes | `usdt:/usr/bin/app:probe_name` |

Prefer tracepoints over kprobes — they are ABI-stable across kernel versions.

### BCC Tools

Pre-built eBPF tools (install `bcc-tools` or `bpfcc-tools`):

```bash
execsnoop          # trace new process execution
opensnoop          # trace file opens
biolatency         # block I/O latency histogram
tcpconnect         # trace TCP active connections
runqlat            # scheduler run queue latency
funccount          # count kernel function calls
profile            # CPU profiling via sampling
cachestat          # page cache hit/miss stats
```

---

## Memory Debugging

### Valgrind / Memcheck

```bash
valgrind --leak-check=full --show-leak-kinds=all ./myapp
# ==1234== HEAP SUMMARY:
# ==1234==   in use at exit: 1,024 bytes in 2 blocks
# ==1234==   total heap usage: 100 allocs, 98 frees, 50,000 bytes allocated
# ==1234== LEAK SUMMARY:
# ==1234==   definitely lost: 512 bytes in 1 blocks
# ==1234==   indirectly lost: 512 bytes in 1 blocks

valgrind --tool=massif ./myapp          # heap profiler
ms_print massif.out.<pid>               # visualize heap over time
valgrind --tool=callgrind ./myapp       # call graph profiler
```

### AddressSanitizer (ASan)

Compile-time instrumentation — faster than Valgrind, catches buffer overflows and use-after-free:

```bash
gcc -fsanitize=address -g -o myapp myapp.c
./myapp
# ==ERROR: AddressSanitizer: heap-buffer-overflow on address 0x602000000014
# WRITE of size 4 at 0x602000000014 thread T0
#     #0 0x4011a3 in main myapp.c:10
```

### System Memory

```bash
free -h                                 # overview: total, used, free, cached
cat /proc/meminfo                       # detailed breakdown
cat /proc/<pid>/smaps_rollup            # per-process memory summary (RSS, PSS, swap)
slabtop                                 # kernel slab allocator usage
```

### OOM Killer

```bash
# Check if OOM killer fired
dmesg | grep -i "out of memory"
journalctl -k | grep -i "oom"

# View OOM score for a process (higher = more likely to be killed)
cat /proc/<pid>/oom_score
cat /proc/<pid>/oom_score_adj           # tunable: -1000 to 1000

# Protect a critical process from OOM
echo -1000 > /proc/<pid>/oom_score_adj
```

---

## CPU Analysis

### Load Average

```bash
uptime
# load average: 4.50, 3.20, 2.10 (1-min, 5-min, 15-min)
# Compare to CPU count (nproc). Load > nproc = tasks queuing.
# Rising trend (left > right) = load increasing.
```

### CPU Pinning and Affinity

```bash
taskset -c 0,1 ./myapp                 # pin to cores 0 and 1
taskset -p -c 2 <pid>                  # move running process to core 2
numactl --cpunodebind=0 ./myapp        # bind to NUMA node 0
numastat -p <pid>                      # NUMA memory allocation stats
```

### Scheduler

```bash
chrt -p <pid>                          # check scheduling policy
chrt -f -p 50 <pid>                    # set FIFO realtime priority
cat /proc/schedstat                    # scheduler statistics
perf sched record -- sleep 5           # record scheduling events
perf sched latency                     # analyze scheduler latency
```

---

## Disk I/O

```bash
iostat -xz 1                           # extended stats, 1s interval
# Device  r/s   w/s   rkB/s  wkB/s  await  %util
# sda     150   200   6000   8000   2.5    85.0
# %util near 100% = saturated; await > 10ms = latency issue

iotop -oP                              # show only processes doing I/O
pidstat -d 1                           # per-process I/O stats

# Detailed block layer tracing
blktrace -d /dev/sda -o - | blkparse -i -
```

### Benchmarking with fio

```bash
fio --name=seqread --rw=read --bs=1M --size=1G --numjobs=1 --runtime=30       # sequential read
fio --name=randwrite --rw=randwrite --bs=4k --size=1G --iodepth=32 --runtime=30  # random 4K IOPS
```

---

## Network Debugging

### Socket Statistics

```bash
ss -tlnp                               # listening TCP sockets with process
ss -s                                   # socket summary statistics
ss -ti                                  # TCP internal info (RTT, cwnd, retrans)
ss state established '( dport = :443 )' # filter established HTTPS connections
```

### Packet Capture

```bash
tcpdump -i eth0 -nn port 80            # capture HTTP traffic
tcpdump -i any -c 100 -w capture.pcap  # save 100 packets to file
tcpdump -i eth0 'tcp[tcpflags] & (tcp-syn) != 0'  # SYN packets only
tcpdump -i eth0 -A host 10.0.0.1       # ASCII dump for specific host
```

### iptables Tracing

```bash
iptables -t raw -A PREROUTING -p tcp --dport 80 -j TRACE
# View trace in: dmesg or journalctl -k
# Clean up: iptables -t raw -F
```

### MTU Issues

```bash
ping -M do -s 1472 <host>              # test path MTU (1472 + 28 = 1500)
ip link show eth0 | grep mtu           # current MTU
ip route get <dest> | grep mtu         # effective path MTU
tracepath <host>                        # discover path MTU
```

---

## Core Dumps

### Enable and Configure

```bash
ulimit -c unlimited                     # enable core dumps for current shell
echo '/tmp/core.%e.%p.%t' > /proc/sys/kernel/core_pattern  # set pattern
# %e = executable, %p = PID, %t = timestamp
```

Persistent via `/etc/security/limits.conf`: `*  soft  core  unlimited`

### Analyze with GDB

```bash
gdb ./myapp /tmp/core.myapp.1234.1700000000
(gdb) bt                               # backtrace
(gdb) bt full                           # backtrace with local variables
(gdb) info registers                    # register state at crash
(gdb) list                              # source code at crash point
(gdb) print variable_name               # inspect variable
```

### systemd coredumpctl

```bash
coredumpctl list                        # list stored core dumps
coredumpctl info <pid>                  # details of a specific dump
coredumpctl gdb <pid>                   # open dump directly in GDB
coredumpctl dump <pid> -o /tmp/core     # extract core file
```

---

## Logging

```bash
journalctl -u myservice --since "1 hour ago"   # service logs, last hour
journalctl -k                                   # kernel messages
journalctl -p err                               # errors and above
journalctl -f                                   # follow (like tail -f)

dmesg -T                                # kernel ring buffer with timestamps
dmesg --level=err,warn                  # only errors and warnings
```

---

## Container Debugging

### Enter Container Namespaces

```bash
docker inspect --format '{{.State.Pid}}' <container>  # get container PID
nsenter -t <pid> -m -u -i -n -p -- /bin/bash           # enter all namespaces
nsenter -t <pid> -n -- ss -tlnp                         # network namespace only
```

### cgroup Limits (v2)

```bash
cat /sys/fs/cgroup/system.slice/docker-<id>.scope/cpu.max       # CPU limit
cat /sys/fs/cgroup/system.slice/docker-<id>.scope/memory.max    # memory limit
cat /sys/fs/cgroup/system.slice/docker-<id>.scope/cpu.stat      # nr_throttled = CPU throttling
```

### Debug from Host

```bash
strace -p <container_pid>              # strace containerized process
perf record -g -p <container_pid> -- sleep 10  # perf from host
cat /proc/<container_pid>/cgroup       # cgroup membership
```

---

## Quick Diagnosis Checklist — USE Method

**U**tilization, **S**aturation, **E**rrors — check each for every resource:

| Resource | Utilization | Saturation | Errors |
|----------|-------------|------------|--------|
| **CPU** | `mpstat -P ALL 1` (%usr+%sys) | `vmstat 1` (r > nproc) | `dmesg \| grep -i mce` |
| **Memory** | `free -h` (used/total) | `vmstat 1` (si/so > 0) | `dmesg \| grep -i oom` |
| **Disk** | `iostat -xz 1` (%util) | `iostat` (avgqu-sz, await) | `smartctl -a /dev/sda` |
| **Network** | `sar -n DEV 1` (rxkB/txkB) | `ss -ti` (retrans) | `ip -s link` (errors) |

### 60-Second Triage

Run these in order for a fast system health check:

```bash
uptime                    # load averages — CPU demand trend
dmesg -T | tail -20       # recent kernel errors
vmstat 1 5                # CPU, memory, swap, I/O overview
mpstat -P ALL 1 3         # per-CPU balance
iostat -xz 1 3            # disk utilization and latency
free -h                   # memory and swap usage
sar -n DEV 1 3            # network throughput
ss -s                     # socket counts and states
top -bn1 | head -20       # top resource consumers
pidstat 1 3               # per-process CPU breakdown
```

If the triage points to a subsystem, dive deeper with perf, strace, or bpftrace as described above.
