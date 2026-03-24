# Review: elk-stack

Accuracy: 4/5
Completeness: 5/5
Actionability: 4/5
Trigger quality: 5/5
Overall: 4.5/5

Issues:
- JSON code blocks in Query DSL section contain `//` comments (lines 110-127) which are invalid JSON; copy-paste will fail in ES Dev Tools or curl. Use separate blocks or move comments outside.
- ILM inline example (line 69) uses deprecated `max_size` rollover parameter; should use `max_primary_shard_size` (as correctly done in assets/elasticsearch/ilm-policy.json).
- ECK install URLs reference version 2.14.0 (line 425-426); ECK is now at 3.x. Version-specific URLs will break for new setups.
- ILM asset file (ilm-policy.json) has `readonly: {}` in the hot phase alongside `rollover`, which is redundant since rolled-over indices are automatically write-blocked.
- Missing `vm.max_map_count >= 262144` sysctl gotcha in the main SKILL.md Docker section (covered in deployment-guide.md but not surfaced in primary doc).

Strengths:
- Exceptionally comprehensive: covers architecture, queries, aggregations, ILM, data streams, Logstash, Filebeat, Metricbeat, Kibana, security, cluster ops, APM, alerting, and K8s deployment in 462 lines.
- All key technical claims verified: JVM 31 GB compressed oops limit ✓, 20-40 GB shard sizing ✓, ILM phase order ✓, KQL syntax ✓, data stream POST API ✓.
- Excellent trigger description with specific positive triggers (12+ use cases) and clear negative triggers (Prometheus, Grafana-only, Splunk, Datadog, Loki).
- Production-quality helper scripts with proper error handling, argument parsing, and --help flags.
- Three deep-dive reference docs (2,387 lines total) provide thorough coverage of advanced patterns, troubleshooting, and deployment.
- Asset templates (docker-compose, pipeline.conf, filebeat.yml, ILM policy) are immediately usable.
- Imperative voice throughout; clear input/output examples in every section.
