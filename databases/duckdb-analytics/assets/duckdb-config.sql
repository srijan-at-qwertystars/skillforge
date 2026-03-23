-- ============================================================================
-- DuckDB Configuration Settings
-- ============================================================================
-- Recommended settings for different environments. Run the relevant block
-- at the start of your DuckDB session or put in ~/.duckdbrc.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- LAPTOP / LOCAL DEVELOPMENT
-- ────────────────────────────────────────────────────────────────────────────
-- Balanced for interactive use: responsive, uses moderate resources.

SET memory_limit = '4GB';
SET threads = 4;
SET temp_directory = '/tmp/duckdb_local';

-- Speed up exploratory queries
SET preserve_insertion_order = false;

-- Enable auto-extensions
SET autoinstall_known_extensions = true;
SET autoload_known_extensions = true;

-- Progress bar for long queries
SET enable_progress_bar = true;
SET enable_progress_bar_print = true;

-- Helpful for development
SET enable_object_cache = true;


-- ────────────────────────────────────────────────────────────────────────────
-- SERVER / PRODUCTION ETL
-- ────────────────────────────────────────────────────────────────────────────
-- Max throughput for large-scale batch processing.

SET memory_limit = '32GB';          -- Adjust to ~75% of available RAM
SET threads = 16;                   -- Match available CPU cores
SET temp_directory = '/data/duckdb_temp';

-- Performance optimizations
SET preserve_insertion_order = false;
SET checkpoint_threshold = '4GB';   -- Less frequent checkpoints
SET force_compression = 'auto';

-- Disable progress bar in automated pipelines
SET enable_progress_bar = false;

-- Extensions
SET autoinstall_known_extensions = true;
SET autoload_known_extensions = true;


-- ────────────────────────────────────────────────────────────────────────────
-- CI / TESTING
-- ────────────────────────────────────────────────────────────────────────────
-- Constrained resources, reproducible behavior.

SET memory_limit = '1GB';
SET threads = 2;
SET temp_directory = '/tmp/duckdb_ci';

-- Deterministic behavior
SET preserve_insertion_order = true;

-- Disable network extensions in CI
SET autoinstall_known_extensions = false;
SET autoload_known_extensions = false;

-- Fail fast
SET enable_progress_bar = false;


-- ────────────────────────────────────────────────────────────────────────────
-- JUPYTER / INTERACTIVE ANALYSIS
-- ────────────────────────────────────────────────────────────────────────────
-- Optimized for notebook experience.

SET memory_limit = '8GB';
SET threads = 4;
SET temp_directory = '/tmp/duckdb_jupyter';

SET preserve_insertion_order = true;  -- Consistent output for notebooks
SET autoinstall_known_extensions = true;
SET autoload_known_extensions = true;

SET enable_progress_bar = true;
SET enable_progress_bar_print = true;
SET enable_object_cache = true;


-- ────────────────────────────────────────────────────────────────────────────
-- S3 / CLOUD STORAGE
-- ────────────────────────────────────────────────────────────────────────────
-- Settings for querying data in cloud object stores.

INSTALL httpfs; LOAD httpfs;
INSTALL aws;    LOAD aws;

-- Use credential chain (env vars, ~/.aws/credentials, instance profile)
CREATE SECRET IF NOT EXISTS aws_default (
    TYPE s3,
    PROVIDER credential_chain
);

-- Performance tuning for remote reads
SET http_keep_alive = true;
SET http_retries = 5;
SET http_retry_wait_ms = 1000;


-- ────────────────────────────────────────────────────────────────────────────
-- LARGE DATASET / OUT-OF-CORE
-- ────────────────────────────────────────────────────────────────────────────
-- When dataset exceeds available RAM.

SET memory_limit = '4GB';           -- Keep conservative
SET temp_directory = '/data/duckdb_spill';  -- Use fast SSD
SET threads = 4;                    -- Fewer threads = less concurrent memory

SET preserve_insertion_order = false;

-- Monitor memory usage
-- SELECT * FROM pragma_database_size();
-- SELECT * FROM duckdb_temporary_files();


-- ────────────────────────────────────────────────────────────────────────────
-- USEFUL DIAGNOSTIC QUERIES (not settings, but reference)
-- ────────────────────────────────────────────────────────────────────────────
-- SELECT * FROM duckdb_settings();
-- SELECT current_setting('memory_limit');
-- SELECT current_setting('threads');
-- SELECT * FROM duckdb_extensions() WHERE installed;
-- SELECT * FROM pragma_database_size();
-- PRAGMA version;
