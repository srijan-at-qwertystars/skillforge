# Kafka CLI Tools — Quick Reference Guide

> Practical command reference for Apache Kafka's built-in shell tools.
> All examples assume `$KAFKA_HOME/bin` is on your `PATH`.

---

## Table of Contents

1. [kafka-topics.sh](#1-kafka-topicssh)
2. [kafka-console-producer.sh](#2-kafka-console-producersh)
3. [kafka-console-consumer.sh](#3-kafka-console-consumersh)
4. [kafka-consumer-groups.sh](#4-kafka-consumer-groupssh)
5. [kafka-configs.sh](#5-kafka-configssh)
6. [kafka-reassign-partitions.sh](#6-kafka-reassign-partitionssh)

---

## 1. kafka-topics.sh

Create, list, inspect, modify, and delete Kafka topics.

### Common Flags

| Flag | Description |
|------|-------------|
| `--bootstrap-server` | Broker connection string (`host:port`) |
| `--topic` | Target topic name |
| `--create` | Create a new topic |
| `--list` | List all topics |
| `--describe` | Show topic details (partitions, replicas, configs) |
| `--alter` | Modify an existing topic |
| `--delete` | Delete a topic |
| `--partitions` | Number of partitions (create or increase) |
| `--replication-factor` | Replication factor (create only) |
| `--config` | Set a topic-level config (`key=value`) |
| `--if-not-exists` | Suppress error if topic already exists |

### Examples

```bash
# Create a topic with 12 partitions and replication factor 3
kafka-topics.sh --bootstrap-server localhost:9092 \
  --create --topic orders \
  --partitions 12 \
  --replication-factor 3

# Create only if the topic does not already exist (idempotent)
kafka-topics.sh --bootstrap-server localhost:9092 \
  --create --topic orders \
  --partitions 12 \
  --replication-factor 3 \
  --if-not-exists

# Create with custom configs (7-day retention, snappy compression)
kafka-topics.sh --bootstrap-server localhost:9092 \
  --create --topic events \
  --partitions 6 \
  --replication-factor 3 \
  --config retention.ms=604800000 \
  --config compression.type=snappy \
  --config segment.bytes=1073741824

# List all topics in the cluster
kafka-topics.sh --bootstrap-server localhost:9092 --list

# Describe a specific topic (partitions, ISR, leader info)
kafka-topics.sh --bootstrap-server localhost:9092 \
  --describe --topic orders

# Describe all topics that have under-replicated partitions
kafka-topics.sh --bootstrap-server localhost:9092 \
  --describe --under-replicated-partitions

# Increase partitions from current count to 24
kafka-topics.sh --bootstrap-server localhost:9092 \
  --alter --topic orders \
  --partitions 24

# Delete a topic
kafka-topics.sh --bootstrap-server localhost:9092 \
  --delete --topic orders
```

---

## 2. kafka-console-producer.sh

Produce messages to a topic directly from the command line or a file.

### Common Flags

| Flag | Description |
|------|-------------|
| `--bootstrap-server` | Broker connection string |
| `--topic` | Target topic |
| `--property parse.key=true` | Enable key parsing from input |
| `--property key.separator=<sep>` | Delimiter between key and value (default: `\t`) |
| `--producer-property` | Inline producer config (`key=value`) |
| `--producer.config` | Path to a producer properties file |

### Examples

```bash
# Produce simple messages (type interactively, Ctrl-C to stop)
kafka-console-producer.sh --bootstrap-server localhost:9092 \
  --topic orders

# Produce messages with keys (tab-separated by default)
# Input format: key<TAB>value
kafka-console-producer.sh --bootstrap-server localhost:9092 \
  --topic orders \
  --property parse.key=true \
  --property key.separator="\t"

# Use a colon as the key separator
# Input format: user123:{"event":"click"}
kafka-console-producer.sh --bootstrap-server localhost:9092 \
  --topic events \
  --property parse.key=true \
  --property key.separator=":"

# Produce with custom headers
# Input format: key:value  (headers set via producer-property)
kafka-console-producer.sh --bootstrap-server localhost:9092 \
  --topic events \
  --property parse.key=true \
  --property key.separator=":" \
  --property parse.headers=true \
  --property headers.delimiter="\t" \
  --property headers.separator=","  \
  --property headers.key.separator=":"

# Produce messages from a file (one message per line)
kafka-console-producer.sh --bootstrap-server localhost:9092 \
  --topic orders < messages.txt

# Produce with acks=all and a 30-second timeout
kafka-console-producer.sh --bootstrap-server localhost:9092 \
  --topic orders \
  --producer-property acks=all \
  --producer-property request.timeout.ms=30000

# Produce using an external config file (e.g., with SSL/SASL settings)
kafka-console-producer.sh --bootstrap-server broker1:9093 \
  --topic secure-orders \
  --producer.config /etc/kafka/producer.properties

# Pipe JSON lines into a topic
cat events.jsonl | kafka-console-producer.sh \
  --bootstrap-server localhost:9092 \
  --topic raw-events
```

---

## 3. kafka-console-consumer.sh

Consume and display messages from a topic on the command line.

### Common Flags

| Flag | Description |
|------|-------------|
| `--bootstrap-server` | Broker connection string |
| `--topic` | Topic to consume from |
| `--from-beginning` | Start from the earliest available offset |
| `--group` | Consumer group ID |
| `--partition` | Consume from a specific partition only |
| `--offset` | Start offset (`earliest`, `latest`, or a number) |
| `--max-messages` | Stop after consuming N messages |
| `--property print.key=true` | Print the message key |
| `--property print.timestamp=true` | Print the message timestamp |
| `--property print.headers=true` | Print message headers |
| `--property print.partition=true` | Print the partition number |
| `--property print.offset=true` | Print the offset |
| `--formatter` | Custom formatter class |

### Examples

```bash
# Consume new messages (latest offset, no group)
kafka-console-consumer.sh --bootstrap-server localhost:9092 \
  --topic orders

# Consume all messages from the beginning
kafka-console-consumer.sh --bootstrap-server localhost:9092 \
  --topic orders \
  --from-beginning

# Consume as part of a named consumer group
kafka-console-consumer.sh --bootstrap-server localhost:9092 \
  --topic orders \
  --group order-processing-group

# Consume and print keys, timestamps, and partition info
kafka-console-consumer.sh --bootstrap-server localhost:9092 \
  --topic orders \
  --from-beginning \
  --property print.key=true \
  --property print.timestamp=true \
  --property print.partition=true \
  --property print.offset=true \
  --property key.separator=" | "

# Consume and print headers alongside key/value
kafka-console-consumer.sh --bootstrap-server localhost:9092 \
  --topic events \
  --from-beginning \
  --property print.key=true \
  --property print.headers=true

# Read from a specific partition at a specific offset
kafka-console-consumer.sh --bootstrap-server localhost:9092 \
  --topic orders \
  --partition 3 \
  --offset 1500

# Read exactly 10 messages and exit
kafka-console-consumer.sh --bootstrap-server localhost:9092 \
  --topic orders \
  --from-beginning \
  --max-messages 10

# Read the last 5 messages from partition 0
kafka-console-consumer.sh --bootstrap-server localhost:9092 \
  --topic orders \
  --partition 0 \
  --offset latest \
  --max-messages 5

# Use a custom formatter (e.g., for __consumer_offsets)
kafka-console-consumer.sh --bootstrap-server localhost:9092 \
  --topic __consumer_offsets \
  --formatter "kafka.coordinator.group.GroupMetadataManager\$OffsetsMessageFormatter" \
  --from-beginning
```

---

## 4. kafka-consumer-groups.sh

Inspect consumer group state, view lag, reset offsets, and manage membership.

### Common Flags

| Flag | Description |
|------|-------------|
| `--bootstrap-server` | Broker connection string |
| `--list` | List all consumer groups |
| `--describe` | Describe a consumer group |
| `--group` | Target consumer group ID |
| `--state` | Show group state (when used with `--list` or `--describe`) |
| `--members` | Show member/client details |
| `--reset-offsets` | Reset consumer group offsets |
| `--to-earliest` | Reset to earliest offset |
| `--to-latest` | Reset to latest offset |
| `--to-offset <n>` | Reset to a specific offset |
| `--shift-by <±n>` | Shift current offset forward or backward by N |
| `--to-datetime <ISO>` | Reset to offset at a given timestamp |
| `--by-duration <PnDTnHnMnS>` | Reset to offset by subtracting a duration |
| `--topic` | Scope reset to a specific topic (or `topic:partition`) |
| `--all-topics` | Apply reset to all topics the group consumed |
| `--dry-run` | Preview offset changes without applying |
| `--execute` | Apply offset changes |
| `--delete` | Delete a consumer group |

### Examples

```bash
# List all consumer groups
kafka-consumer-groups.sh --bootstrap-server localhost:9092 --list

# List consumer groups with their states
kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --list --state

# Describe a group: view partitions, current offset, log-end offset, lag
kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --describe --group order-processing-group

# Describe group state (Stable, Empty, Dead, etc.)
kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --describe --group order-processing-group --state

# Show group members and their assignments
kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --describe --group order-processing-group --members

# Show verbose member info including client IDs and partition assignments
kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --describe --group order-processing-group --members --verbose

# --- Offset Resets (group must be INACTIVE / all consumers stopped) ---

# Dry-run: preview resetting to earliest for all topics
kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --group order-processing-group \
  --reset-offsets --to-earliest --all-topics --dry-run

# Execute: reset to earliest for a specific topic
kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --group order-processing-group \
  --reset-offsets --to-earliest --topic orders --execute

# Reset to latest offset
kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --group order-processing-group \
  --reset-offsets --to-latest --topic orders --execute

# Reset to a specific offset on a specific partition
kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --group order-processing-group \
  --reset-offsets --to-offset 5000 --topic orders:3 --execute

# Shift offset backward by 100 (reprocess last 100 messages)
kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --group order-processing-group \
  --reset-offsets --shift-by -100 --topic orders --execute

# Reset to a specific datetime
kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --group order-processing-group \
  --reset-offsets --to-datetime "2024-01-15T08:00:00.000" \
  --topic orders --execute

# Reset by duration (go back 2 hours)
kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --group order-processing-group \
  --reset-offsets --by-duration PT2H --topic orders --execute

# Delete an inactive consumer group
kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --delete --group order-processing-group
```

---

## 5. kafka-configs.sh

View and modify dynamic configs for topics, brokers, users, and clients.

### Common Flags

| Flag | Description |
|------|-------------|
| `--bootstrap-server` | Broker connection string |
| `--entity-type` | Entity type: `topics`, `brokers`, `users`, `clients` |
| `--entity-name` | Name of the entity (topic name, broker ID, user principal, client ID) |
| `--entity-default` | Apply to the default entity (e.g., all brokers) |
| `--describe` | Show current dynamic configs |
| `--alter` | Modify configs |
| `--add-config` | Add or update config entries (`key=value`) |
| `--delete-config` | Remove config entries (comma-separated keys) |
| `--all` | Show all configs (static + dynamic) when describing |

### Examples

```bash
# --- Topic Configs ---

# Describe all overridden configs for a topic
kafka-configs.sh --bootstrap-server localhost:9092 \
  --entity-type topics --entity-name orders \
  --describe

# Set retention to 7 days and max message size to 10 MB
kafka-configs.sh --bootstrap-server localhost:9092 \
  --entity-type topics --entity-name orders \
  --alter \
  --add-config retention.ms=604800000,max.message.bytes=10485760

# Enable log compaction on a topic
kafka-configs.sh --bootstrap-server localhost:9092 \
  --entity-type topics --entity-name user-profiles \
  --alter \
  --add-config cleanup.policy=compact,min.cleanable.dirty.ratio=0.3

# Remove a config override (revert to broker default)
kafka-configs.sh --bootstrap-server localhost:9092 \
  --entity-type topics --entity-name orders \
  --alter \
  --delete-config retention.ms

# --- Broker Configs ---

# Describe dynamic configs for broker 0
kafka-configs.sh --bootstrap-server localhost:9092 \
  --entity-type brokers --entity-name 0 \
  --describe

# Describe all configs (static + dynamic) for broker 0
kafka-configs.sh --bootstrap-server localhost:9092 \
  --entity-type brokers --entity-name 0 \
  --describe --all

# Change log cleaner threads on a specific broker
kafka-configs.sh --bootstrap-server localhost:9092 \
  --entity-type brokers --entity-name 0 \
  --alter \
  --add-config log.cleaner.threads=3

# Set a cluster-wide default broker config
kafka-configs.sh --bootstrap-server localhost:9092 \
  --entity-type brokers --entity-default \
  --alter \
  --add-config log.retention.hours=72

# --- User / Client Quotas ---

# Set produce/consume quotas for a user (bytes/sec)
kafka-configs.sh --bootstrap-server localhost:9092 \
  --entity-type users --entity-name alice \
  --alter \
  --add-config producer_byte_rate=10485760,consumer_byte_rate=20971520

# Set request rate quota for a client ID
kafka-configs.sh --bootstrap-server localhost:9092 \
  --entity-type clients --entity-name analytics-app \
  --alter \
  --add-config request_percentage=25

# Describe quotas for a user
kafka-configs.sh --bootstrap-server localhost:9092 \
  --entity-type users --entity-name alice \
  --describe

# Remove quotas for a user
kafka-configs.sh --bootstrap-server localhost:9092 \
  --entity-type users --entity-name alice \
  --alter \
  --delete-config producer_byte_rate,consumer_byte_rate
```

---

## 6. kafka-reassign-partitions.sh

Move partition replicas between brokers. Useful for cluster rebalancing, broker decommissioning, and rack-aware placement.

### Common Flags

| Flag | Description |
|------|-------------|
| `--bootstrap-server` | Broker connection string |
| `--topics-to-move-json-file` | JSON file listing topics to move |
| `--broker-list` | Comma-separated destination broker IDs |
| `--generate` | Generate a reassignment plan |
| `--reassignment-json-file` | JSON file with the reassignment plan |
| `--execute` | Execute the reassignment plan |
| `--verify` | Check progress/completion of a reassignment |
| `--throttle` | Throttle replication traffic (bytes/sec) |

### Full Workflow

#### Step 1 — Define which topics to move

Create a JSON file listing the topics you want to reassign:

```bash
cat > topics-to-move.json << 'EOF'
{
  "version": 1,
  "topics": [
    { "topic": "orders" },
    { "topic": "events" }
  ]
}
EOF
```

#### Step 2 — Generate a reassignment plan

```bash
# Generate a plan to move the listed topics onto brokers 1, 2, and 3
kafka-reassign-partitions.sh --bootstrap-server localhost:9092 \
  --topics-to-move-json-file topics-to-move.json \
  --broker-list "1,2,3" \
  --generate
```

This outputs two JSON blocks:
- **Current partition replica assignment** — save this as your rollback plan.
- **Proposed partition reassignment** — save this for execution.

```bash
# Save the proposed plan to a file
cat > reassignment-plan.json << 'EOF'
{
  "version": 1,
  "partitions": [
    { "topic": "orders", "partition": 0, "replicas": [2, 3, 1], "log_dirs": ["any", "any", "any"] },
    { "topic": "orders", "partition": 1, "replicas": [3, 1, 2], "log_dirs": ["any", "any", "any"] },
    { "topic": "events", "partition": 0, "replicas": [1, 2, 3], "log_dirs": ["any", "any", "any"] }
  ]
}
EOF
```

#### Step 3 — Execute the reassignment

```bash
# Execute with a 50 MB/s replication throttle to limit impact
kafka-reassign-partitions.sh --bootstrap-server localhost:9092 \
  --reassignment-json-file reassignment-plan.json \
  --execute \
  --throttle 52428800
```

#### Step 4 — Verify completion

```bash
# Check the status of the reassignment (run until all partitions report success)
kafka-reassign-partitions.sh --bootstrap-server localhost:9092 \
  --reassignment-json-file reassignment-plan.json \
  --verify
```

> **Note:** `--verify` also removes any replication throttles once all reassignments are complete.
> Run `--verify` periodically until it reports that all partitions have been successfully reassigned.

#### Manual reassignment example

You can also hand-craft a reassignment plan to move a single partition:

```bash
# Move orders partition 0 to brokers 4, 5, 6
cat > manual-reassignment.json << 'EOF'
{
  "version": 1,
  "partitions": [
    { "topic": "orders", "partition": 0, "replicas": [4, 5, 6] }
  ]
}
EOF

kafka-reassign-partitions.sh --bootstrap-server localhost:9092 \
  --reassignment-json-file manual-reassignment.json \
  --execute

# Verify
kafka-reassign-partitions.sh --bootstrap-server localhost:9092 \
  --reassignment-json-file manual-reassignment.json \
  --verify
```

---

## Quick Tips

| Tip | Detail |
|-----|--------|
| **Multiple brokers** | Use comma-separated list: `--bootstrap-server b1:9092,b2:9092,b3:9092` |
| **SSL / SASL** | Pass `--command-config client.properties` (or `--consumer.config` / `--producer.config`) |
| **Dry-run offsets** | Always `--dry-run` before `--execute` when resetting consumer group offsets |
| **Throttle reassignments** | Use `--throttle` to avoid saturating inter-broker network during partition moves |
| **Idempotent creates** | Use `--if-not-exists` in automation scripts to avoid failures on re-runs |
| **Describe everything** | `kafka-topics.sh --describe` with no `--topic` flag describes all topics |
