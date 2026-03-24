/**
 * Kafka Streams Topology Template
 *
 * Features:
 *   - Windowed aggregation with state store
 *   - Custom RocksDB configuration
 *   - Exactly-once semantics (EOS v2)
 *   - Deserialization and production error handling
 *   - Graceful shutdown with JVM hook
 *   - Interactive query support
 *
 * Dependencies (Maven):
 *   <dependency>
 *     <groupId>org.apache.kafka</groupId>
 *     <artifactId>kafka-streams</artifactId>
 *     <version>3.9.0</version>
 *   </dependency>
 *
 * Usage:
 *   javac -cp kafka-streams-3.9.0.jar StreamsTemplate.java
 *   java -cp .:kafka-streams-3.9.0.jar StreamsTemplate
 */

import java.time.Duration;
import java.util.Map;
import java.util.Properties;
import java.util.concurrent.CountDownLatch;

import org.apache.kafka.clients.consumer.ConsumerConfig;
import org.apache.kafka.common.serialization.Serdes;
import org.apache.kafka.common.utils.Bytes;
import org.apache.kafka.streams.KafkaStreams;
import org.apache.kafka.streams.StreamsBuilder;
import org.apache.kafka.streams.StreamsConfig;
import org.apache.kafka.streams.Topology;
import org.apache.kafka.streams.errors.StreamsUncaughtExceptionHandler;
import org.apache.kafka.streams.kstream.Consumed;
import org.apache.kafka.streams.kstream.Grouped;
import org.apache.kafka.streams.kstream.KStream;
import org.apache.kafka.streams.kstream.KTable;
import org.apache.kafka.streams.kstream.Materialized;
import org.apache.kafka.streams.kstream.Named;
import org.apache.kafka.streams.kstream.Produced;
import org.apache.kafka.streams.kstream.Suppressed;
import org.apache.kafka.streams.kstream.TimeWindows;
import org.apache.kafka.streams.kstream.Windowed;
import org.apache.kafka.streams.state.KeyValueStore;
import org.apache.kafka.streams.state.ReadOnlyWindowStore;
import org.apache.kafka.streams.state.StoreBuilder;
import org.apache.kafka.streams.state.Stores;
import org.apache.kafka.streams.state.WindowStore;
import org.apache.kafka.streams.StoreQueryParameters;
import org.apache.kafka.streams.state.QueryableStoreTypes;

import org.rocksdb.BlockBasedTableConfig;
import org.rocksdb.Options;

public class StreamsTemplate {

    // -----------------------------------------------------------------------
    // Configuration
    // -----------------------------------------------------------------------

    static final String INPUT_TOPIC = "events";
    static final String OUTPUT_TOPIC = "event-counts";
    static final String DLQ_TOPIC = "events-dlq";
    static final String STATE_STORE_NAME = "windowed-event-counts";

    static Properties buildConfig() {
        Properties props = new Properties();
        props.put(StreamsConfig.APPLICATION_ID_CONFIG, "event-counter-app");
        props.put(StreamsConfig.BOOTSTRAP_SERVERS_CONFIG, "localhost:9092");
        props.put(StreamsConfig.DEFAULT_KEY_SERDE_CLASS_CONFIG, Serdes.StringSerde.class);
        props.put(StreamsConfig.DEFAULT_VALUE_SERDE_CLASS_CONFIG, Serdes.StringSerde.class);

        // Exactly-once v2
        props.put(StreamsConfig.PROCESSING_GUARANTEE_CONFIG, StreamsConfig.EXACTLY_ONCE_V2);

        // State store directory
        props.put(StreamsConfig.STATE_DIR_CONFIG, "/tmp/kafka-streams");

        // Commit interval (lower = more frequent commits = lower latency)
        props.put(StreamsConfig.COMMIT_INTERVAL_MS_CONFIG, 1000);

        // Standby replicas for faster failover
        props.put(StreamsConfig.NUM_STANDBY_REPLICAS_CONFIG, 1);

        // Replication for changelog and repartition topics
        props.put(StreamsConfig.REPLICATION_FACTOR_CONFIG, 1); // Set to 3 for production

        // Interactive queries: expose this instance's host:port
        props.put(StreamsConfig.APPLICATION_SERVER_CONFIG, "localhost:8080");

        // Tune consumer
        props.put(ConsumerConfig.AUTO_OFFSET_RESET_CONFIG, "earliest");

        // RocksDB tuning
        props.put(StreamsConfig.ROCKSDB_CONFIG_SETTER_CLASS_CONFIG,
            CustomRocksDBConfig.class.getName());

        return props;
    }

    // -----------------------------------------------------------------------
    // RocksDB configuration
    // -----------------------------------------------------------------------

    public static class CustomRocksDBConfig
            implements org.apache.kafka.streams.state.RocksDBConfigSetter {

        @Override
        public void setConfig(String storeName, Options options,
                Map<String, Object> configs) {
            BlockBasedTableConfig tableConfig = (BlockBasedTableConfig)
                options.tableFormatConfig();
            tableConfig.setBlockCacheSize(64 * 1024 * 1024L);  // 64MB cache
            tableConfig.setBlockSize(16 * 1024);                // 16KB blocks
            options.setTableFormatConfig(tableConfig);
            options.setMaxWriteBufferNumber(3);
            options.setWriteBufferSize(16 * 1024 * 1024);       // 16MB
        }

        @Override
        public void close(String storeName, Options options) {
            // no-op
        }
    }

    // -----------------------------------------------------------------------
    // Topology
    // -----------------------------------------------------------------------

    static Topology buildTopology() {
        StreamsBuilder builder = new StreamsBuilder();

        // Source stream
        KStream<String, String> events = builder.stream(
            INPUT_TOPIC,
            Consumed.with(Serdes.String(), Serdes.String())
                .withName("source-events")
        );

        // Branch: valid vs invalid events
        KStream<String, String>[] branches = events.branch(
            Named.as("branch-"),
            (key, value) -> isValid(key, value),  // valid
            (key, value) -> true                    // invalid → DLQ
        );

        KStream<String, String> validEvents = branches[0];
        KStream<String, String> invalidEvents = branches[1];

        // Route invalid events to DLQ
        invalidEvents.to(
            DLQ_TOPIC,
            Produced.with(Serdes.String(), Serdes.String())
                .withName("sink-dlq")
        );

        // Windowed aggregation: count events per key in 5-minute tumbling windows
        KTable<Windowed<String>, Long> windowedCounts = validEvents
            .groupByKey(Grouped.as("group-by-event-key"))
            .windowedBy(
                TimeWindows.ofSizeAndGrace(
                    Duration.ofMinutes(5),
                    Duration.ofMinutes(1)  // accept 1 min late arrivals
                )
            )
            .count(
                Named.as("windowed-count"),
                Materialized.<String, Long, WindowStore<Bytes, byte[]>>as(STATE_STORE_NAME)
                    .withKeySerde(Serdes.String())
                    .withValueSerde(Serdes.Long())
                    .withRetention(Duration.ofHours(24))
            );

        // Suppress intermediate results — emit only final window count
        windowedCounts
            .suppress(Suppressed.untilWindowCloses(
                Suppressed.BufferConfig.unbounded()
                    .withMaxRecords(100_000)
            ))
            .toStream()
            .selectKey((windowedKey, count) -> windowedKey.key())
            .mapValues((key, count) -> String.format(
                "{\"key\":\"%s\",\"count\":%d}", key, count))
            .to(
                OUTPUT_TOPIC,
                Produced.with(Serdes.String(), Serdes.String())
                    .withName("sink-counts")
            );

        return builder.build();
    }

    static boolean isValid(String key, String value) {
        return key != null && !key.isEmpty() && value != null && !value.isEmpty();
    }

    // -----------------------------------------------------------------------
    // Error handling
    // -----------------------------------------------------------------------

    static void configureErrorHandling(KafkaStreams streams) {
        streams.setUncaughtExceptionHandler(exception -> {
            System.err.println("Uncaught exception in stream thread: " + exception.getMessage());
            exception.printStackTrace();

            if (isRecoverable(exception)) {
                System.err.println("Replacing failed thread...");
                return StreamsUncaughtExceptionHandler.StreamThreadExceptionResponse
                    .REPLACE_THREAD;
            }
            System.err.println("Shutting down application...");
            return StreamsUncaughtExceptionHandler.StreamThreadExceptionResponse
                .SHUTDOWN_APPLICATION;
        });

        streams.setStateListener((newState, oldState) -> {
            System.out.printf("State change: %s → %s%n", oldState, newState);
            if (newState == KafkaStreams.State.ERROR) {
                System.err.println("Streams entered ERROR state");
            }
        });
    }

    static boolean isRecoverable(Throwable t) {
        // Customize: classify exceptions as recoverable or fatal
        return t instanceof org.apache.kafka.common.errors.TimeoutException
            || t instanceof org.apache.kafka.common.errors.RetriableException;
    }

    // -----------------------------------------------------------------------
    // Interactive queries example
    // -----------------------------------------------------------------------

    static void queryWindowStore(KafkaStreams streams, String key) {
        if (streams.state() != KafkaStreams.State.RUNNING) {
            System.out.println("Streams not running — cannot query");
            return;
        }
        try {
            ReadOnlyWindowStore<String, Long> store = streams.store(
                StoreQueryParameters.fromNameAndType(
                    STATE_STORE_NAME,
                    QueryableStoreTypes.windowStore()
                )
            );
            var iter = store.fetchAll(
                java.time.Instant.now().minus(Duration.ofHours(1)),
                java.time.Instant.now()
            );
            while (iter.hasNext()) {
                var entry = iter.next();
                System.out.printf("Window [%s - %s] key=%s count=%d%n",
                    entry.key.window().startTime(),
                    entry.key.window().endTime(),
                    entry.key.key(),
                    entry.value);
            }
            iter.close();
        } catch (Exception e) {
            System.err.println("Query failed: " + e.getMessage());
        }
    }

    // -----------------------------------------------------------------------
    // Main
    // -----------------------------------------------------------------------

    public static void main(String[] args) {
        Properties config = buildConfig();
        Topology topology = buildTopology();

        System.out.println("Topology:");
        System.out.println(topology.describe());

        KafkaStreams streams = new KafkaStreams(topology, config);
        configureErrorHandling(streams);

        // Graceful shutdown
        CountDownLatch latch = new CountDownLatch(1);
        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            System.out.println("Shutting down streams...");
            streams.close(Duration.ofSeconds(30));
            latch.countDown();
        }, "streams-shutdown-hook"));

        try {
            streams.start();
            System.out.println("Streams application started");
            latch.await();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        } catch (Exception e) {
            System.err.println("Fatal error: " + e.getMessage());
            e.printStackTrace();
            System.exit(1);
        }
    }
}
