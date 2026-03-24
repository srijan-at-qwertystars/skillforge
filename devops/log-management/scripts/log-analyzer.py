#!/usr/bin/env python3
"""
log-analyzer.py — Analyze log files for error patterns, latency, and anomalies.

Supports JSON-formatted log files (one JSON object per line).
Outputs summary statistics, top errors, latency percentiles, and pattern detection.

Usage:
    ./log-analyzer.py <logfile> [OPTIONS]

Options:
    --top N              Number of top errors to show (default: 10)
    --percentiles P      Comma-separated percentiles (default: 50,90,95,99)
    --time-window MINS   Window size for rate calculation (default: 5)
    --level-field NAME   JSON field for log level (default: level)
    --message-field NAME JSON field for message (default: message)
    --time-field NAME    JSON field for timestamp (default: timestamp)
    --duration-field NAME JSON field for duration in ms (default: duration_ms)
    --output FORMAT      Output format: text, json (default: text)
    --since DATETIME     Only analyze logs after this time (ISO 8601)
    --until DATETIME     Only analyze logs before this time (ISO 8601)

Examples:
    ./log-analyzer.py /var/log/app/app.log
    ./log-analyzer.py app.log --top 20 --output json
    ./log-analyzer.py app.log --since 2024-03-24T00:00:00Z --percentiles 50,95,99,99.9
    cat logs/*.json | ./log-analyzer.py -
"""

import argparse
import json
import math
import re
import sys
from collections import Counter, defaultdict
from datetime import datetime, timezone


def parse_timestamp(ts_str):
    """Parse common timestamp formats."""
    if ts_str is None:
        return None
    if isinstance(ts_str, (int, float)):
        # Epoch seconds or milliseconds
        if ts_str > 1e12:
            return datetime.fromtimestamp(ts_str / 1000, tz=timezone.utc)
        return datetime.fromtimestamp(ts_str, tz=timezone.utc)

    for fmt in (
        "%Y-%m-%dT%H:%M:%S.%fZ",
        "%Y-%m-%dT%H:%M:%SZ",
        "%Y-%m-%dT%H:%M:%S.%f%z",
        "%Y-%m-%dT%H:%M:%S%z",
        "%Y-%m-%d %H:%M:%S.%f",
        "%Y-%m-%d %H:%M:%S",
    ):
        try:
            dt = datetime.strptime(ts_str, fmt)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt
        except ValueError:
            continue
    return None


def percentile(sorted_data, p):
    """Calculate percentile from sorted list."""
    if not sorted_data:
        return 0
    k = (len(sorted_data) - 1) * (p / 100.0)
    f = math.floor(k)
    c = math.ceil(k)
    if f == c:
        return sorted_data[int(k)]
    return sorted_data[int(f)] * (c - k) + sorted_data[int(c)] * (k - f)


def detect_patterns(messages, min_count=3):
    """Detect common log message patterns by normalizing variable parts."""
    normalized = Counter()
    pattern_map = defaultdict(list)

    for msg in messages:
        if not msg:
            continue
        # Normalize: replace numbers, UUIDs, hex strings, IPs, quoted strings
        pattern = re.sub(r'\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b', '<UUID>', msg)
        pattern = re.sub(r'\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b', '<IP>', pattern)
        pattern = re.sub(r'\b0x[0-9a-fA-F]+\b', '<HEX>', pattern)
        pattern = re.sub(r'\b\d+\b', '<N>', pattern)
        pattern = re.sub(r'"[^"]*"', '"<STR>"', pattern)
        normalized[pattern] += 1
        if len(pattern_map[pattern]) < 3:
            pattern_map[pattern].append(msg)

    return [
        {"pattern": p, "count": c, "examples": pattern_map[p]}
        for p, c in normalized.most_common(20)
        if c >= min_count
    ]


def analyze_logs(lines, args):
    """Main analysis logic."""
    total = 0
    parse_errors = 0
    level_counts = Counter()
    error_messages = Counter()
    service_counts = Counter()
    durations = []
    durations_by_endpoint = defaultdict(list)
    timestamps = []
    error_timestamps = []
    all_messages = []

    since = parse_timestamp(args.since) if args.since else None
    until = parse_timestamp(args.until) if args.until else None

    for line in lines:
        line = line.strip()
        if not line:
            continue

        total += 1
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            parse_errors += 1
            continue

        # Timestamp filtering
        ts = parse_timestamp(entry.get(args.time_field))
        if ts:
            if since and ts < since:
                continue
            if until and ts > until:
                continue
            timestamps.append(ts)

        # Level counting
        level = str(entry.get(args.level_field, "unknown")).lower()
        level_counts[level] += 1

        # Message collection
        message = entry.get(args.message_field, "")
        all_messages.append(message)

        # Error tracking
        if level in ("error", "fatal", "critical"):
            error_msg = message
            if "error" in entry and isinstance(entry["error"], dict):
                error_msg = entry["error"].get("message", message)
                error_type = entry["error"].get("type", "")
                if error_type:
                    error_msg = f"{error_type}: {error_msg}"
            error_messages[error_msg] += 1
            if ts:
                error_timestamps.append(ts)

        # Duration tracking
        duration = entry.get(args.duration_field)
        if duration is not None:
            try:
                d = float(duration)
                durations.append(d)
                endpoint = entry.get("path", entry.get("endpoint", entry.get("url", "unknown")))
                durations_by_endpoint[endpoint].append(d)
            except (ValueError, TypeError):
                pass

        # Service tracking
        service = entry.get("service", entry.get("service_name"))
        if service:
            service_counts[service] += 1

    # Calculate results
    results = {
        "summary": {
            "total_lines": total,
            "parsed_ok": total - parse_errors,
            "parse_errors": parse_errors,
        },
        "levels": dict(level_counts.most_common()),
        "time_range": {},
        "error_rate": {},
        "top_errors": [],
        "latency": {},
        "latency_by_endpoint": {},
        "patterns": [],
        "services": dict(service_counts.most_common(20)),
    }

    # Time range
    if timestamps:
        results["time_range"] = {
            "start": min(timestamps).isoformat(),
            "end": max(timestamps).isoformat(),
            "duration_seconds": (max(timestamps) - min(timestamps)).total_seconds(),
        }

    # Error rate
    error_count = sum(level_counts.get(l, 0) for l in ("error", "fatal", "critical"))
    valid_count = total - parse_errors
    if valid_count > 0:
        results["error_rate"] = {
            "total_errors": error_count,
            "error_percentage": round(error_count / valid_count * 100, 2),
        }
        if timestamps and (max(timestamps) - min(timestamps)).total_seconds() > 0:
            span_minutes = (max(timestamps) - min(timestamps)).total_seconds() / 60
            results["error_rate"]["errors_per_minute"] = round(error_count / span_minutes, 2)

    # Top errors
    results["top_errors"] = [
        {"message": msg[:200], "count": cnt}
        for msg, cnt in error_messages.most_common(args.top)
    ]

    # Latency percentiles
    pcts = [float(p) for p in args.percentiles.split(",")]
    if durations:
        sorted_d = sorted(durations)
        results["latency"] = {
            "count": len(durations),
            "min_ms": round(min(durations), 2),
            "max_ms": round(max(durations), 2),
            "avg_ms": round(sum(durations) / len(durations), 2),
            "percentiles": {f"p{p}": round(percentile(sorted_d, p), 2) for p in pcts},
        }

        # Top 5 slowest endpoints
        endpoint_stats = {}
        for ep, durs in sorted(durations_by_endpoint.items(), key=lambda x: -max(x[1]))[:10]:
            sd = sorted(durs)
            endpoint_stats[ep] = {
                "count": len(durs),
                "avg_ms": round(sum(durs) / len(durs), 2),
                "p99_ms": round(percentile(sd, 99), 2),
            }
        results["latency_by_endpoint"] = endpoint_stats

    # Pattern detection
    results["patterns"] = detect_patterns(all_messages)

    return results


def print_text_report(results):
    """Print human-readable report."""
    print("=" * 70)
    print("  LOG ANALYSIS REPORT")
    print("=" * 70)

    # Summary
    s = results["summary"]
    print(f"\n📊 Summary")
    print(f"   Total lines:    {s['total_lines']:,}")
    print(f"   Parsed OK:      {s['parsed_ok']:,}")
    print(f"   Parse errors:   {s['parse_errors']:,}")

    # Time range
    if results["time_range"]:
        t = results["time_range"]
        print(f"\n⏱  Time Range")
        print(f"   Start: {t['start']}")
        print(f"   End:   {t['end']}")
        hours = t["duration_seconds"] / 3600
        print(f"   Span:  {hours:.1f} hours")

    # Log levels
    print(f"\n📈 Log Levels")
    for level, count in results["levels"].items():
        pct = count / max(s["parsed_ok"], 1) * 100
        bar = "█" * int(pct / 2)
        print(f"   {level:>8s}: {count:>8,} ({pct:5.1f}%) {bar}")

    # Error rate
    if results["error_rate"]:
        e = results["error_rate"]
        print(f"\n🔴 Error Rate")
        print(f"   Total errors:     {e['total_errors']:,}")
        print(f"   Error percentage: {e['error_percentage']}%")
        if "errors_per_minute" in e:
            print(f"   Errors/minute:    {e['errors_per_minute']}")

    # Top errors
    if results["top_errors"]:
        print(f"\n🔝 Top Errors")
        for i, err in enumerate(results["top_errors"], 1):
            msg = err["message"][:80]
            print(f"   {i:>2}. [{err['count']:>5,}×] {msg}")

    # Latency
    if results["latency"]:
        lat = results["latency"]
        print(f"\n⚡ Request Latency")
        print(f"   Samples:  {lat['count']:,}")
        print(f"   Min:      {lat['min_ms']} ms")
        print(f"   Avg:      {lat['avg_ms']} ms")
        print(f"   Max:      {lat['max_ms']} ms")
        print(f"   Percentiles:")
        for p, v in lat["percentiles"].items():
            print(f"     {p}: {v} ms")

    if results["latency_by_endpoint"]:
        print(f"\n🐌 Slowest Endpoints")
        for ep, stats in list(results["latency_by_endpoint"].items())[:5]:
            print(f"   {ep}: avg={stats['avg_ms']}ms p99={stats['p99_ms']}ms ({stats['count']} reqs)")

    # Patterns
    if results["patterns"]:
        print(f"\n🔍 Detected Patterns (top 10)")
        for i, p in enumerate(results["patterns"][:10], 1):
            print(f"   {i:>2}. [{p['count']:>5,}×] {p['pattern'][:80]}")

    # Services
    if results["services"]:
        print(f"\n🏷  Services")
        for svc, count in list(results["services"].items())[:10]:
            print(f"   {svc}: {count:,}")

    print("\n" + "=" * 70)


def main():
    parser = argparse.ArgumentParser(
        description="Analyze JSON log files for errors, latency, and patterns."
    )
    parser.add_argument("logfile", help="Log file path (use - for stdin)")
    parser.add_argument("--top", type=int, default=10, help="Number of top errors")
    parser.add_argument("--percentiles", default="50,90,95,99", help="Comma-separated percentiles")
    parser.add_argument("--time-window", type=int, default=5, help="Time window in minutes")
    parser.add_argument("--level-field", default="level", help="JSON field for log level")
    parser.add_argument("--message-field", default="message", help="JSON field for message")
    parser.add_argument("--time-field", default="timestamp", help="JSON field for timestamp")
    parser.add_argument("--duration-field", default="duration_ms", help="JSON field for duration")
    parser.add_argument("--output", choices=["text", "json"], default="text", help="Output format")
    parser.add_argument("--since", help="Only logs after this time (ISO 8601)")
    parser.add_argument("--until", help="Only logs before this time (ISO 8601)")
    args = parser.parse_args()

    if args.logfile == "-":
        lines = sys.stdin
    else:
        try:
            lines = open(args.logfile, "r", encoding="utf-8", errors="replace")
        except FileNotFoundError:
            print(f"Error: File not found: {args.logfile}", file=sys.stderr)
            sys.exit(1)

    results = analyze_logs(lines, args)

    if args.output == "json":
        print(json.dumps(results, indent=2))
    else:
        print_text_report(results)

    if args.logfile != "-":
        lines.close()


if __name__ == "__main__":
    main()
