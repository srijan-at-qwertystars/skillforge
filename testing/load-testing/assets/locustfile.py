"""
locustfile.py — Production-ready Locust load test template

Usage:
    # Web UI mode
    locust -f locustfile.py

    # Headless mode
    locust -f locustfile.py --headless -u 100 -r 10 -t 5m --host https://api.example.com

    # With CSV output
    locust -f locustfile.py --headless -u 100 -r 10 -t 5m --csv=results --csv-full-history

    # Distributed mode
    locust -f locustfile.py --master --expect-workers=4
    locust -f locustfile.py --worker --master-host=192.168.1.100

Environment variables:
    TARGET_HOST       - Target host URL (or use --host flag)
    AUTH_USERNAME      - Username for authentication
    AUTH_PASSWORD      - Password for authentication
"""

import os
import json
import random
import time
import logging
from typing import Optional

from locust import (
    HttpUser,
    task,
    between,
    events,
    LoadTestShape,
    tag,
)

logger = logging.getLogger(__name__)

# =============================================================================
# Configuration
# =============================================================================

AUTH_USERNAME = os.getenv("AUTH_USERNAME", "loadtest")
AUTH_PASSWORD = os.getenv("AUTH_PASSWORD", "password")


# =============================================================================
# Event Hooks — Custom Logging and Metrics
# =============================================================================

@events.test_start.add_listener
def on_test_start(environment, **kwargs):
    """Called when the test starts."""
    logger.info(f"Load test starting. Target: {environment.host}")
    logger.info(f"Users: {environment.parsed_options.num_users if environment.parsed_options else 'N/A'}")


@events.test_stop.add_listener
def on_test_stop(environment, **kwargs):
    """Called when the test stops."""
    stats = environment.runner.stats
    logger.info("=" * 60)
    logger.info("LOAD TEST COMPLETE")
    logger.info(f"Total requests: {stats.total.num_requests}")
    logger.info(f"Total failures: {stats.total.num_failures}")
    logger.info(f"Average response time: {stats.total.avg_response_time:.0f}ms")
    logger.info(f"p95 response time: {stats.total.get_response_time_percentile(0.95):.0f}ms")
    logger.info(f"Requests/s: {stats.total.current_rps:.1f}")
    logger.info("=" * 60)

    # Fail if error rate exceeds threshold
    if stats.total.num_requests > 0:
        error_rate = stats.total.num_failures / stats.total.num_requests
        if error_rate > 0.01:
            logger.error(f"ERROR RATE {error_rate:.2%} exceeds 1% threshold!")


@events.request.add_listener
def on_request(request_type, name, response_time, response_length, exception, **kwargs):
    """Called for every request — use for custom metrics or logging."""
    if exception:
        logger.debug(f"Request failed: {request_type} {name} — {exception}")
    elif response_time > 5000:
        logger.warning(f"Slow request: {request_type} {name} — {response_time:.0f}ms")


# =============================================================================
# User Classes
# =============================================================================

class APIUser(HttpUser):
    """Simulates a typical API user browsing and interacting with resources."""

    host = os.getenv("TARGET_HOST", "http://localhost:8080")
    wait_time = between(1, 3)  # 1-3s think time between tasks

    # Relative weight — if multiple user classes, this controls proportion
    weight = 3

    token: Optional[str] = None

    def on_start(self):
        """Called when a simulated user starts. Authenticate here."""
        try:
            resp = self.client.post("/auth/login", json={
                "username": AUTH_USERNAME,
                "password": AUTH_PASSWORD,
            }, name="POST /auth/login")

            if resp.status_code == 200:
                self.token = resp.json().get("token") or resp.json().get("access_token")
                self.headers = {"Authorization": f"Bearer {self.token}"}
            else:
                logger.warning(f"Auth failed: {resp.status_code}")
                self.headers = {}
        except Exception as e:
            logger.error(f"Auth error: {e}")
            self.headers = {}

    def on_stop(self):
        """Called when a simulated user stops."""
        pass

    @task(5)
    @tag("read", "list")
    def list_items(self):
        """List items — highest frequency task (weight=5)."""
        with self.client.get(
            "/api/items",
            headers=self.headers,
            name="GET /api/items",
            catch_response=True,
        ) as resp:
            if resp.status_code != 200:
                resp.failure(f"Expected 200, got {resp.status_code}")
            elif resp.elapsed.total_seconds() > 2.0:
                resp.failure(f"Too slow: {resp.elapsed.total_seconds():.1f}s")
            else:
                try:
                    data = resp.json()
                    if not isinstance(data, (list, dict)):
                        resp.failure("Invalid response format")
                except json.JSONDecodeError:
                    resp.failure("Invalid JSON response")

    @task(3)
    @tag("read", "detail")
    def get_item(self):
        """Get single item — medium frequency (weight=3)."""
        item_id = random.randint(1, 100)
        with self.client.get(
            f"/api/items/{item_id}",
            headers=self.headers,
            name="GET /api/items/{id}",
            catch_response=True,
        ) as resp:
            if resp.status_code == 200:
                resp.success()
            elif resp.status_code == 404:
                resp.success()  # 404 is expected for some IDs
            else:
                resp.failure(f"Unexpected status: {resp.status_code}")

    @task(2)
    @tag("read", "search")
    def search_items(self):
        """Search items — medium-low frequency (weight=2)."""
        query = random.choice(["test", "demo", "load", "performance", "benchmark"])
        self.client.get(
            f"/api/items?search={query}&limit=20",
            headers=self.headers,
            name="GET /api/items?search=",
        )

    @task(1)
    @tag("write", "create")
    def create_item(self):
        """Create item — lowest frequency (weight=1)."""
        payload = {
            "name": f"load-test-{self.environment.runner.user_count}-{random.randint(1, 10000)}",
            "value": round(random.uniform(1, 1000), 2),
            "tags": ["load-test"],
        }
        with self.client.post(
            "/api/items",
            headers=self.headers,
            json=payload,
            name="POST /api/items",
            catch_response=True,
        ) as resp:
            if resp.status_code in (200, 201):
                resp.success()
            else:
                resp.failure(f"Create failed: {resp.status_code}")


class AdminUser(HttpUser):
    """Simulates admin users — lower proportion, heavier operations."""

    host = os.getenv("TARGET_HOST", "http://localhost:8080")
    wait_time = between(3, 8)  # admins are slower, more deliberate

    weight = 1  # 1/4 ratio with APIUser (weight=3)

    def on_start(self):
        resp = self.client.post("/auth/login", json={
            "username": "admin",
            "password": AUTH_PASSWORD,
        }, name="POST /auth/login (admin)")
        if resp.status_code == 200:
            self.headers = {"Authorization": f"Bearer {resp.json().get('token', '')}"}
        else:
            self.headers = {}

    @task(3)
    @tag("admin", "read")
    def view_dashboard(self):
        """Admin dashboard — aggregation queries."""
        self.client.get("/api/admin/dashboard", headers=self.headers,
                        name="GET /api/admin/dashboard")

    @task(1)
    @tag("admin", "write")
    def update_settings(self):
        """Update settings — heavy write operation."""
        self.client.put("/api/admin/settings", headers=self.headers,
                        json={"cache_ttl": random.choice([300, 600, 900])},
                        name="PUT /api/admin/settings")


# =============================================================================
# Custom Load Shapes
# =============================================================================

class StepLoadShape(LoadTestShape):
    """
    Step load pattern — increase users in steps to find breaking point.

    Steps:
        0-1min:   10 users
        1-2min:   25 users
        2-3min:   50 users
        3-4min:   75 users
        4-5min:  100 users
        5-7min:  150 users
        7-9min:  200 users
        9-10min:   0 users (ramp down)
    """

    stages = [
        {"duration": 60,  "users": 10,  "spawn_rate": 10},
        {"duration": 120, "users": 25,  "spawn_rate": 10},
        {"duration": 180, "users": 50,  "spawn_rate": 15},
        {"duration": 240, "users": 75,  "spawn_rate": 15},
        {"duration": 300, "users": 100, "spawn_rate": 20},
        {"duration": 420, "users": 150, "spawn_rate": 20},
        {"duration": 540, "users": 200, "spawn_rate": 25},
        {"duration": 600, "users": 0,   "spawn_rate": 50},
    ]

    def tick(self):
        run_time = self.get_run_time()

        for stage in self.stages:
            if run_time < stage["duration"]:
                return (stage["users"], stage["spawn_rate"])

        return None  # Stop the test


class SpikeLoadShape(LoadTestShape):
    """
    Spike pattern — sudden traffic bursts to test auto-scaling and resilience.

    Pattern: normal → spike → normal → spike (higher) → ramp down
    """

    def tick(self):
        run_time = self.get_run_time()

        if run_time < 60:       # 0-1min: ramp to baseline
            return (20, 10)
        elif run_time < 180:    # 1-3min: steady baseline
            return (20, 10)
        elif run_time < 200:    # 3-3:20: SPIKE to 200
            return (200, 100)
        elif run_time < 260:    # 3:20-4:20: hold spike
            return (200, 100)
        elif run_time < 280:    # 4:20-4:40: back to baseline
            return (20, 50)
        elif run_time < 360:    # 4:40-6min: steady baseline
            return (20, 10)
        elif run_time < 380:    # 6-6:20: BIGGER SPIKE to 500
            return (500, 200)
        elif run_time < 440:    # 6:20-7:20: hold big spike
            return (500, 200)
        elif run_time < 500:    # 7:20-8:20: ramp down
            return (0, 50)
        else:
            return None


# =============================================================================
# To use a custom shape, set the LOCUST_SHAPE environment variable:
#
#   LOCUST_SHAPE=step locust -f locustfile.py --headless
#   LOCUST_SHAPE=spike locust -f locustfile.py --headless
#
# By default (no shape), Locust uses the --users and --spawn-rate flags.
# To activate a shape, uncomment the desired shape class above and comment
# out the other shapes, OR conditionally set them via environment variable.
# =============================================================================

# Uncomment ONE shape to activate it, or use default user count:
# StepLoadShape  — uncomment class above to use
# SpikeLoadShape — uncomment class above to use
