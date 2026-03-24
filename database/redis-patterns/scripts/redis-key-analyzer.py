#!/usr/bin/env python3
"""
redis-key-analyzer.py — Redis Key Namespace Analyzer

Analyzes key distribution by prefix, TTL statistics, memory usage per prefix,
and idle time stats using SCAN (production-safe).

Usage:
    ./redis-key-analyzer.py [-H HOST] [-p PORT] [-a PASSWORD] [-n DB]
                            [--prefix-depth DEPTH] [--sample-size SIZE]

Examples:
    ./redis-key-analyzer.py
    ./redis-key-analyzer.py -H redis.example.com -p 6380
    ./redis-key-analyzer.py --prefix-depth 2 --sample-size 50000
    ./redis-key-analyzer.py -a mypassword --prefix-depth 3
"""

import argparse
import sys
import time
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Optional

try:
    import redis
except ImportError:
    print("ERROR: redis-py is required. Install with: pip install redis", file=sys.stderr)
    sys.exit(1)


@dataclass
class PrefixStats:
    count: int = 0
    total_memory: int = 0
    total_ttl: int = 0
    ttl_count: int = 0
    no_ttl_count: int = 0
    total_idle: int = 0
    idle_count: int = 0
    min_ttl: Optional[int] = None
    max_ttl: int = 0
    min_idle: Optional[int] = None
    max_idle: int = 0
    types: dict = field(default_factory=lambda: defaultdict(int))
    encodings: dict = field(default_factory=lambda: defaultdict(int))
    sample_keys: list = field(default_factory=list)
    max_memory_key: str = ""
    max_memory_val: int = 0


def get_prefix(key: str, depth: int) -> str:
    """Extract prefix from key based on colon-delimited depth."""
    parts = key.split(":")
    if len(parts) <= depth:
        return key
    return ":".join(parts[:depth]) + ":*"


def format_bytes(nbytes: int) -> str:
    """Format bytes to human-readable string."""
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(nbytes) < 1024:
            return f"{nbytes:.1f} {unit}"
        nbytes /= 1024
    return f"{nbytes:.1f} PB"


def format_duration(seconds: int) -> str:
    """Format seconds to human-readable duration."""
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m {seconds % 60}s"
    if seconds < 86400:
        return f"{seconds // 3600}h {(seconds % 3600) // 60}m"
    return f"{seconds // 86400}d {(seconds % 86400) // 3600}h"


def analyze_keys(r: redis.Redis, prefix_depth: int, sample_size: int) -> dict:
    """Scan all keys and collect statistics grouped by prefix."""
    stats = defaultdict(PrefixStats)
    total_scanned = 0
    cursor = 0
    start_time = time.time()

    print(f"\nScanning keys (sample size: {sample_size})...\n", flush=True)

    while True:
        cursor, keys = r.scan(cursor=cursor, count=500)
        if not keys and cursor == 0:
            break

        pipe = r.pipeline(transaction=False)
        key_strs = []

        for key in keys:
            if total_scanned >= sample_size:
                break
            key_str = key.decode("utf-8", errors="replace") if isinstance(key, bytes) else key
            key_strs.append(key_str)
            pipe.type(key)
            pipe.object("encoding", key)
            pipe.memory_usage(key, samples=0)
            pipe.ttl(key)
            pipe.object("idletime", key)
            total_scanned += 1

        if not key_strs:
            if cursor == 0:
                break
            continue

        try:
            results = pipe.execute()
        except redis.RedisError as e:
            print(f"  Warning: Pipeline error: {e}", file=sys.stderr)
            if cursor == 0:
                break
            continue

        for i, key_str in enumerate(key_strs):
            base = i * 5
            try:
                key_type = results[base]
                if isinstance(key_type, bytes):
                    key_type = key_type.decode()
                encoding = results[base + 1]
                if isinstance(encoding, bytes):
                    encoding = encoding.decode()
                mem_usage = results[base + 2] or 0
                ttl = results[base + 3]
                idle_time = results[base + 4] or 0
            except (IndexError, redis.RedisError):
                continue

            prefix = get_prefix(key_str, prefix_depth)
            s = stats[prefix]
            s.count += 1
            s.total_memory += mem_usage
            s.types[key_type] += 1
            s.encodings[encoding] += 1

            if mem_usage > s.max_memory_val:
                s.max_memory_val = mem_usage
                s.max_memory_key = key_str

            if len(s.sample_keys) < 3:
                s.sample_keys.append(key_str)

            if ttl is not None and ttl >= 0:
                s.ttl_count += 1
                s.total_ttl += ttl
                if s.min_ttl is None or ttl < s.min_ttl:
                    s.min_ttl = ttl
                if ttl > s.max_ttl:
                    s.max_ttl = ttl
            else:
                s.no_ttl_count += 1

            if idle_time is not None and idle_time >= 0:
                s.idle_count += 1
                s.total_idle += idle_time
                if s.min_idle is None or idle_time < s.min_idle:
                    s.min_idle = idle_time
                if idle_time > s.max_idle:
                    s.max_idle = idle_time

        if total_scanned % 5000 == 0:
            elapsed = time.time() - start_time
            rate = total_scanned / elapsed if elapsed > 0 else 0
            print(f"  Scanned {total_scanned:,} keys ({rate:.0f} keys/s)...", flush=True)

        if total_scanned >= sample_size or cursor == 0:
            break

    elapsed = time.time() - start_time
    print(f"\nScan complete: {total_scanned:,} keys in {elapsed:.1f}s\n")
    return dict(stats), total_scanned


def print_report(stats: dict, total_scanned: int, r: redis.Redis):
    """Print the analysis report."""
    if not stats:
        print("No keys found.")
        return

    total_memory = sum(s.total_memory for s in stats.values())
    total_keys = sum(s.count for s in stats.values())
    dbsize = r.dbsize()

    # --- Header ---
    print("=" * 78)
    print("  REDIS KEY NAMESPACE ANALYSIS REPORT")
    print("=" * 78)
    print(f"  Database Size:    {dbsize:,} total keys")
    print(f"  Keys Analyzed:    {total_scanned:,} ({total_scanned * 100 / max(dbsize, 1):.1f}% sampled)")
    print(f"  Total Memory:     {format_bytes(total_memory)} (sampled keys)")
    print(f"  Unique Prefixes:  {len(stats)}")

    # --- Distribution by Prefix ---
    print("\n" + "=" * 78)
    print("  KEY DISTRIBUTION BY PREFIX")
    print("=" * 78)
    sorted_prefixes = sorted(stats.items(), key=lambda x: x[1].count, reverse=True)

    print(f"\n  {'Prefix':<30} {'Count':>8} {'%':>6} {'Memory':>10} {'Mem %':>6} {'Types'}")
    print(f"  {'-' * 30} {'-' * 8} {'-' * 6} {'-' * 10} {'-' * 6} {'-' * 20}")

    for prefix, s in sorted_prefixes[:30]:
        pct = s.count * 100 / total_keys if total_keys > 0 else 0
        mem_pct = s.total_memory * 100 / total_memory if total_memory > 0 else 0
        types_str = ", ".join(f"{t}({c})" for t, c in sorted(s.types.items(), key=lambda x: -x[1]))
        print(f"  {prefix:<30} {s.count:>8,} {pct:>5.1f}% {format_bytes(s.total_memory):>10} {mem_pct:>5.1f}% {types_str}")

    if len(sorted_prefixes) > 30:
        remaining = len(sorted_prefixes) - 30
        remaining_count = sum(s.count for _, s in sorted_prefixes[30:])
        remaining_mem = sum(s.total_memory for _, s in sorted_prefixes[30:])
        print(f"  {'... and ' + str(remaining) + ' more':<30} {remaining_count:>8,} {'':>6} {format_bytes(remaining_mem):>10}")

    # --- Memory Usage per Prefix ---
    print("\n" + "=" * 78)
    print("  MEMORY USAGE BY PREFIX (top 20 by memory)")
    print("=" * 78)
    sorted_by_mem = sorted(stats.items(), key=lambda x: x[1].total_memory, reverse=True)

    print(f"\n  {'Prefix':<30} {'Total Mem':>10} {'Avg/Key':>10} {'Biggest Key':<30} {'Size':>8}")
    print(f"  {'-' * 30} {'-' * 10} {'-' * 10} {'-' * 30} {'-' * 8}")

    for prefix, s in sorted_by_mem[:20]:
        avg_mem = s.total_memory // s.count if s.count > 0 else 0
        biggest = s.max_memory_key[:28] + ".." if len(s.max_memory_key) > 30 else s.max_memory_key
        print(f"  {prefix:<30} {format_bytes(s.total_memory):>10} {format_bytes(avg_mem):>10} {biggest:<30} {format_bytes(s.max_memory_val):>8}")

    # --- TTL Analysis ---
    print("\n" + "=" * 78)
    print("  TTL ANALYSIS BY PREFIX")
    print("=" * 78)

    has_ttl_data = any(s.ttl_count > 0 for s in stats.values())
    if has_ttl_data:
        print(f"\n  {'Prefix':<30} {'With TTL':>9} {'No TTL':>8} {'% TTL':>7} {'Avg TTL':>10} {'Min TTL':>10} {'Max TTL':>10}")
        print(f"  {'-' * 30} {'-' * 9} {'-' * 8} {'-' * 7} {'-' * 10} {'-' * 10} {'-' * 10}")

        for prefix, s in sorted_prefixes[:20]:
            if s.ttl_count > 0 or s.no_ttl_count > 0:
                ttl_pct = s.ttl_count * 100 / s.count if s.count > 0 else 0
                avg_ttl = s.total_ttl // s.ttl_count if s.ttl_count > 0 else 0
                min_ttl = format_duration(s.min_ttl) if s.min_ttl is not None else "—"
                max_ttl = format_duration(s.max_ttl) if s.max_ttl > 0 else "—"
                avg_ttl_str = format_duration(avg_ttl) if s.ttl_count > 0 else "—"
                print(f"  {prefix:<30} {s.ttl_count:>9,} {s.no_ttl_count:>8,} {ttl_pct:>6.1f}% {avg_ttl_str:>10} {min_ttl:>10} {max_ttl:>10}")

        no_ttl_total = sum(s.no_ttl_count for s in stats.values())
        ttl_total = sum(s.ttl_count for s in stats.values())
        print(f"\n  Summary: {ttl_total:,} keys with TTL, {no_ttl_total:,} keys without TTL")
        if no_ttl_total > 0:
            print(f"  ⚠  {no_ttl_total:,} keys have no TTL — review if these should expire")
    else:
        print("\n  No keys with TTL found in sample.")

    # --- Idle Time Stats ---
    print("\n" + "=" * 78)
    print("  IDLE TIME STATS BY PREFIX (top 20 by avg idle)")
    print("=" * 78)

    idle_sorted = sorted(
        [(p, s) for p, s in stats.items() if s.idle_count > 0],
        key=lambda x: x[1].total_idle / max(x[1].idle_count, 1),
        reverse=True,
    )

    if idle_sorted:
        print(f"\n  {'Prefix':<30} {'Keys':>8} {'Avg Idle':>12} {'Min Idle':>12} {'Max Idle':>12}")
        print(f"  {'-' * 30} {'-' * 8} {'-' * 12} {'-' * 12} {'-' * 12}")

        for prefix, s in idle_sorted[:20]:
            avg_idle = s.total_idle // s.idle_count if s.idle_count > 0 else 0
            min_idle = format_duration(s.min_idle) if s.min_idle is not None else "—"
            max_idle = format_duration(s.max_idle) if s.max_idle > 0 else "—"
            print(f"  {prefix:<30} {s.count:>8,} {format_duration(avg_idle):>12} {min_idle:>12} {max_idle:>12}")
    else:
        print("\n  No idle time data available.")

    # --- Encoding Distribution ---
    print("\n" + "=" * 78)
    print("  ENCODING DISTRIBUTION")
    print("=" * 78)

    all_encodings = defaultdict(int)
    for s in stats.values():
        for enc, cnt in s.encodings.items():
            all_encodings[enc] += cnt

    print(f"\n  {'Encoding':<20} {'Count':>10} {'%':>7}")
    print(f"  {'-' * 20} {'-' * 10} {'-' * 7}")
    for enc, cnt in sorted(all_encodings.items(), key=lambda x: -x[1]):
        pct = cnt * 100 / total_keys if total_keys > 0 else 0
        print(f"  {enc:<20} {cnt:>10,} {pct:>6.1f}%")

    print("\n" + "=" * 78)
    print("  ANALYSIS COMPLETE")
    print("=" * 78)
    print()


def main():
    parser = argparse.ArgumentParser(description="Redis Key Namespace Analyzer")
    parser.add_argument("-H", "--host", default="127.0.0.1", help="Redis host (default: 127.0.0.1)")
    parser.add_argument("-p", "--port", type=int, default=6379, help="Redis port (default: 6379)")
    parser.add_argument("-a", "--password", default=None, help="Redis password")
    parser.add_argument("-n", "--db", type=int, default=0, help="Redis database number (default: 0)")
    parser.add_argument("--prefix-depth", type=int, default=2, help="Colon-delimited prefix depth (default: 2)")
    parser.add_argument("--sample-size", type=int, default=100000, help="Max keys to scan (default: 100000)")

    args = parser.parse_args()

    try:
        r = redis.Redis(
            host=args.host,
            port=args.port,
            password=args.password,
            db=args.db,
            socket_timeout=10,
            socket_connect_timeout=5,
            decode_responses=False,
        )
        r.ping()
    except redis.ConnectionError as e:
        print(f"ERROR: Cannot connect to Redis at {args.host}:{args.port}: {e}", file=sys.stderr)
        sys.exit(1)
    except redis.AuthenticationError:
        print("ERROR: Authentication failed. Check password.", file=sys.stderr)
        sys.exit(1)

    print(f"Redis Key Analyzer — {time.strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"Target: {args.host}:{args.port} (db{args.db})")
    print(f"Prefix Depth: {args.prefix_depth}")

    stats, total_scanned = analyze_keys(r, args.prefix_depth, args.sample_size)
    print_report(stats, total_scanned, r)


if __name__ == "__main__":
    main()
