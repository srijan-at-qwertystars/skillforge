# Review: linux-debugging

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.75/5

Issues: Non-standard description format (positive:/negative: sub-keys). Minor: `cat /proc/<pid>/fd` should be `ls -la` since fd is a directory (comment already notes this).

Excellent systems debugging guide. Covers process inspection (/proc, lsof, fuser), strace (attach/filter/timing/patterns), ltrace, perf (stat/record/report/top/hardware counters), flamegraphs (generation/interpretation/differential/speedscope), eBPF/bpftrace (one-liners for syscalls/execve/I/O/block latency), BCC tools, memory debugging (Valgrind/ASan/OOM killer), CPU analysis (load average/taskset/numactl/scheduler), disk I/O (iostat/iotop/fio), network debugging (ss/tcpdump/iptables/MTU), core dumps (GDB/coredumpctl), container debugging (nsenter/cgroups v2), USE method checklist, and 60-second triage.
