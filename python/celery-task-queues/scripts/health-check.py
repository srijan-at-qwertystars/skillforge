#!/usr/bin/env python3
"""
health-check.py — Check Celery worker health, queue lengths, and task status.

Usage:
    python health-check.py [--broker BROKER_URL] [--app APP_NAME] [--json]

Examples:
    python health-check.py
    python health-check.py --broker redis://localhost:6379/0
    python health-check.py --app myproject --json

Checks:
    - Worker availability (ping)
    - Active, reserved, and scheduled task counts
    - Queue lengths (Redis broker)
    - Worker stats (uptime, pool info, total tasks processed)
    - Registered tasks

Exit codes:
    0 — All workers healthy
    1 — One or more issues detected
    2 — No workers responding
"""

import argparse
import json as json_module
import sys
import os

try:
    from celery import Celery
except ImportError:
    print("ERROR: celery package not installed. Run: pip install celery[redis]")
    sys.exit(1)


def get_app(app_name, broker_url):
    """Create or connect to a Celery app."""
    if app_name:
        try:
            # Try importing existing app
            import importlib
            module = importlib.import_module(f"{app_name}.celery")
            return module.app
        except (ImportError, AttributeError):
            pass

    # Create a temporary app for inspection
    return Celery(broker=broker_url)


def check_workers(app):
    """Ping all workers and return status."""
    inspect = app.control.inspect()
    ping_result = inspect.ping()

    if not ping_result:
        return {"status": "critical", "workers": {}, "message": "No workers responding"}

    workers = {}
    for worker_name, response in ping_result.items():
        workers[worker_name] = {
            "alive": response.get("ok") == "pong",
        }

    return {"status": "ok", "workers": workers, "count": len(workers)}


def check_tasks(app):
    """Get active, reserved, and scheduled task counts."""
    inspect = app.control.inspect()

    active = inspect.active() or {}
    reserved = inspect.reserved() or {}
    scheduled = inspect.scheduled() or {}

    result = {"per_worker": {}}
    total_active = 0
    total_reserved = 0
    total_scheduled = 0

    for worker in set(list(active.keys()) + list(reserved.keys()) + list(scheduled.keys())):
        w_active = len(active.get(worker, []))
        w_reserved = len(reserved.get(worker, []))
        w_scheduled = len(scheduled.get(worker, []))
        total_active += w_active
        total_reserved += w_reserved
        total_scheduled += w_scheduled

        result["per_worker"][worker] = {
            "active": w_active,
            "reserved": w_reserved,
            "scheduled": w_scheduled,
        }

    result["totals"] = {
        "active": total_active,
        "reserved": total_reserved,
        "scheduled": total_scheduled,
    }
    return result


def check_queue_lengths(broker_url):
    """Get queue lengths from Redis broker."""
    if not broker_url or not broker_url.startswith("redis"):
        return {"available": False, "message": "Queue length check only supported for Redis broker"}

    try:
        import redis
        # Parse Redis URL
        r = redis.Redis.from_url(broker_url)
        queues = {}
        # Common queue names — also scan for celery keys
        for key in r.keys("*"):
            key_str = key.decode("utf-8") if isinstance(key, bytes) else key
            key_type = r.type(key)
            type_str = key_type.decode("utf-8") if isinstance(key_type, bytes) else key_type
            if type_str == "list":
                queues[key_str] = r.llen(key)

        return {"available": True, "queues": queues}
    except ImportError:
        return {"available": False, "message": "redis package not installed"}
    except Exception as e:
        return {"available": False, "message": str(e)}


def check_worker_stats(app):
    """Get worker statistics."""
    inspect = app.control.inspect()
    stats = inspect.stats() or {}

    result = {}
    for worker, info in stats.items():
        pool = info.get("pool", {})
        result[worker] = {
            "total_tasks": info.get("total", {}),
            "pool_type": pool.get("implementation", "unknown"),
            "concurrency": pool.get("max-concurrency", "unknown"),
            "pid": info.get("pid", "unknown"),
            "uptime": info.get("clock", "unknown"),
        }
    return result


def check_registered_tasks(app):
    """Get registered task names per worker."""
    inspect = app.control.inspect()
    registered = inspect.registered() or {}

    result = {}
    for worker, tasks in registered.items():
        result[worker] = sorted(tasks)
    return result


def print_report(report, as_json=False):
    """Print the health check report."""
    if as_json:
        print(json_module.dumps(report, indent=2, default=str))
        return

    print("=" * 60)
    print("CELERY HEALTH CHECK REPORT")
    print("=" * 60)

    # Workers
    workers = report.get("workers", {})
    status = workers.get("status", "unknown")
    print(f"\n[Workers] Status: {status.upper()}")
    if workers.get("workers"):
        for name, info in workers["workers"].items():
            alive = "✓" if info.get("alive") else "✗"
            print(f"  {alive} {name}")
    print(f"  Total workers: {workers.get('count', 0)}")

    # Tasks
    tasks = report.get("tasks", {})
    totals = tasks.get("totals", {})
    print(f"\n[Tasks]")
    print(f"  Active:    {totals.get('active', 0)}")
    print(f"  Reserved:  {totals.get('reserved', 0)}")
    print(f"  Scheduled: {totals.get('scheduled', 0)}")

    if tasks.get("per_worker"):
        for worker, counts in tasks["per_worker"].items():
            print(f"  {worker}: active={counts['active']} reserved={counts['reserved']} scheduled={counts['scheduled']}")

    # Queues
    queues = report.get("queues", {})
    if queues.get("available"):
        print(f"\n[Queue Lengths]")
        for queue, length in queues.get("queues", {}).items():
            indicator = "⚠" if length > 100 else " "
            print(f"  {indicator} {queue}: {length}")
    elif queues.get("message"):
        print(f"\n[Queue Lengths] {queues['message']}")

    # Stats
    stats = report.get("stats", {})
    if stats:
        print(f"\n[Worker Stats]")
        for worker, info in stats.items():
            print(f"  {worker}:")
            print(f"    Pool: {info.get('pool_type')} (concurrency: {info.get('concurrency')})")
            print(f"    PID: {info.get('pid')}")

    print("\n" + "=" * 60)


def main():
    parser = argparse.ArgumentParser(description="Celery health check")
    parser.add_argument("--broker", default=os.environ.get("CELERY_BROKER_URL", "redis://localhost:6379/0"),
                        help="Broker URL (default: $CELERY_BROKER_URL or redis://localhost:6379/0)")
    parser.add_argument("--app", default=None, help="Celery app name (e.g., myproject)")
    parser.add_argument("--json", action="store_true", help="Output as JSON")
    args = parser.parse_args()

    app = get_app(args.app, args.broker)

    report = {}

    # Run checks
    report["workers"] = check_workers(app)
    if report["workers"]["status"] == "critical":
        print_report(report, args.json)
        sys.exit(2)

    report["tasks"] = check_tasks(app)
    report["queues"] = check_queue_lengths(args.broker)
    report["stats"] = check_worker_stats(app)
    report["registered"] = check_registered_tasks(app)

    print_report(report, args.json)

    # Determine exit code
    if report["workers"]["status"] != "ok":
        sys.exit(1)

    # Warn on large queue backlogs
    for queue, length in report.get("queues", {}).get("queues", {}).items():
        if length > 1000:
            sys.exit(1)

    sys.exit(0)


if __name__ == "__main__":
    main()
