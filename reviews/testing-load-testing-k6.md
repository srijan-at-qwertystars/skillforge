# Review: load-testing-k6

Accuracy: 5/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 5/5
Overall: 5.0/5

Issues: Minor formatting bug at line 132 — heading and code fence merged (`### constant-vus```javascript`). Not material.

Excellent k6 load testing guide. Standard description format. Covers script structure (init/setup/VU/teardown lifecycle), HTTP requests (GET/POST/file upload/response parsing), checks and thresholds (SLO enforcement, abort on breach, per-endpoint thresholds), scenarios (constant-vus, ramping-vus, constant-arrival-rate, shared-iterations, externally-controlled, multiple scenarios with exec), test types (smoke/load/stress/spike/soak with concrete configs), data parameterization (SharedArray, CSV via papaparse, env vars), groups and tags with tag-scoped thresholds, custom metrics (Counter/Gauge/Rate/Trend), k6 browser module (Chromium, LCP/CLS, hybrid protocol+browser testing), protocol support (WebSocket, gRPC), CI/CD integration (GitHub Actions with grafana/setup-k6-action), results output (JSON/CSV/InfluxDB/Grafana Cloud), common patterns (correlation, think time, batch, dynamic URLs), and anti-patterns (no thresholds, missing sleep, SharedArray mutations, averages over percentiles).
