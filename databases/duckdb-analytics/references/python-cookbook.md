# DuckDB Python Cookbook

## Table of Contents

- [Pandas DataFrame Analysis](#pandas-dataframe-analysis)
- [Polars Integration](#polars-integration)
- [Arrow Tables](#arrow-tables)
- [Jupyter Notebook Patterns](#jupyter-notebook-patterns)
- [SQLAlchemy Integration](#sqlalchemy-integration)
- [Ibis Framework](#ibis-framework)
- [Streaming Large Result Sets](#streaming-large-result-sets)
- [Connection Pooling Patterns](#connection-pooling-patterns)
- [Embedding in Flask](#embedding-in-flask)
- [Embedding in FastAPI](#embedding-in-fastapi)
- [Python UDFs](#python-udfs)
- [Testing Patterns](#testing-patterns)

---

## Pandas DataFrame Analysis

### Query DataFrames Directly

DuckDB auto-detects pandas DataFrames in the local Python scope by variable name.

```python
import duckdb
import pandas as pd

sales = pd.DataFrame({
    'date': pd.date_range('2024-01-01', periods=1000, freq='h'),
    'product': ['A', 'B', 'C', 'D'] * 250,
    'revenue': [round(x, 2) for x in __import__('random').sample(
        [i * 0.5 for i in range(1, 2001)], 1000)],
    'quantity': [__import__('random').randint(1, 100) for _ in range(1000)]
})

# Query the DataFrame as if it were a table
result = duckdb.sql("""
    SELECT product,
           date_trunc('day', date) AS day,
           sum(revenue) AS daily_revenue,
           sum(quantity) AS units_sold
    FROM sales
    WHERE product IN ('A', 'B')
    GROUP BY product, day
    ORDER BY day, product
""").df()
```

### Replace Pandas GroupBy with SQL

```python
# Pandas way (slow for complex aggregations)
grouped = sales.groupby('product').agg(
    total_revenue=('revenue', 'sum'),
    avg_quantity=('quantity', 'mean'),
    num_orders=('quantity', 'count')
).reset_index()

# DuckDB way (faster, more expressive)
grouped = duckdb.sql("""
    SELECT product,
           sum(revenue) AS total_revenue,
           avg(quantity) AS avg_quantity,
           count(*) AS num_orders,
           approx_quantile(revenue, 0.95) AS p95_revenue
    FROM sales
    GROUP BY product
""").df()
```

### Window Functions on DataFrames

```python
enriched = duckdb.sql("""
    SELECT *,
        row_number() OVER (PARTITION BY product ORDER BY revenue DESC) AS rank,
        revenue / sum(revenue) OVER (PARTITION BY product) AS pct_of_product,
        avg(revenue) OVER (
            PARTITION BY product
            ORDER BY date
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ) AS rolling_7_avg
    FROM sales
""").df()
```

### Cross-DataFrame Joins

```python
products = pd.DataFrame({
    'product': ['A', 'B', 'C', 'D'],
    'category': ['Electronics', 'Electronics', 'Books', 'Books'],
    'margin': [0.3, 0.25, 0.4, 0.35]
})

report = duckdb.sql("""
    SELECT p.category,
           sum(s.revenue) AS total_revenue,
           sum(s.revenue * p.margin) AS total_profit
    FROM sales s
    JOIN products p USING (product)
    GROUP BY p.category
    ORDER BY total_profit DESC
""").df()
```

---

## Polars Integration

### Direct Querying

```python
import polars as pl
import duckdb

orders = pl.DataFrame({
    'order_id': range(1, 10001),
    'customer_id': [i % 500 for i in range(10000)],
    'amount': [round(i * 0.73, 2) for i in range(10000)],
    'status': ['completed', 'pending', 'shipped', 'cancelled'] * 2500
})

# Query Polars DataFrame, return as Polars
result = duckdb.sql("""
    SELECT customer_id,
           count(*) AS order_count,
           sum(amount) AS total_spent,
           list(DISTINCT status) AS statuses
    FROM orders
    WHERE status != 'cancelled'
    GROUP BY customer_id
    HAVING total_spent > 100
    ORDER BY total_spent DESC
""").pl()
```

### Polars → DuckDB → Polars Pipeline

```python
# Use DuckDB for the heavy SQL, Polars for the rest
raw = pl.read_parquet('events.parquet')

aggregated = duckdb.sql("""
    SELECT date_trunc('hour', timestamp) AS hour,
           event_type,
           count(*) AS cnt,
           approx_count_distinct(user_id) AS unique_users
    FROM raw
    GROUP BY ALL
""").pl()

# Continue processing in Polars
final = (
    aggregated
    .with_columns(pl.col('cnt').rolling_mean(window_size=24).alias('rolling_avg'))
    .filter(pl.col('unique_users') > 10)
)
```

### Polars LazyFrame Integration

```python
# Scan Parquet with Polars lazy API, then hand off to DuckDB for SQL
lf = pl.scan_parquet('data/**/*.parquet')
df = lf.collect()  # Materialize for DuckDB

result = duckdb.sql("""
    SELECT * FROM df
    WHERE category = 'premium'
    ORDER BY created_at DESC
    LIMIT 1000
""").pl()
```

---

## Arrow Tables

### Zero-Copy Interop

DuckDB uses Apache Arrow as its internal data exchange format. Arrow conversions are fast, often zero-copy.

```python
import pyarrow as pa
import pyarrow.parquet as pq
import duckdb

# Read Parquet → Arrow → DuckDB (minimal copies)
arrow_table = pq.read_table('data.parquet')
result = duckdb.sql("SELECT col1, sum(col2) FROM arrow_table GROUP BY col1").arrow()

# Arrow → Pandas (via DuckDB, often faster than direct)
df = duckdb.sql("SELECT * FROM arrow_table WHERE value > 100").df()
```

### Arrow RecordBatch Reader (Streaming)

```python
# Stream results as Arrow batches for memory-efficient processing
con = duckdb.connect()
reader = con.execute("""
    SELECT * FROM read_parquet('huge_file.parquet')
    WHERE category = 'A'
""").fetch_record_batch(rows_per_batch=50000)

for batch in reader:
    # Process each batch (pyarrow.RecordBatch)
    # Each batch is ~50K rows
    process(batch.to_pandas())
```

### Arrow Dataset Integration

```python
import pyarrow.dataset as ds

# Register Arrow Dataset with DuckDB
dataset = ds.dataset('data/', format='parquet', partitioning='hive')
arrow_table = dataset.to_table(filter=ds.field('year') == 2024)

con = duckdb.connect()
result = con.sql("SELECT * FROM arrow_table WHERE month = 6").arrow()
```

### Arrow Flight (for Distributed Workflows)

```python
# Write DuckDB results to Arrow Flight server
import pyarrow.flight as flight

con = duckdb.connect()
result = con.execute("SELECT * FROM analytics").arrow()

client = flight.FlightClient("grpc://arrow-server:8815")
writer, _ = client.do_put(
    flight.FlightDescriptor.for_path("analytics_results"),
    result.schema
)
writer.write_table(result)
writer.close()
```

---

## Jupyter Notebook Patterns

### Cell 1: Setup

```python
import duckdb
import pandas as pd
import matplotlib.pyplot as plt

# Use persistent DB for cross-session work
con = duckdb.connect('notebook.duckdb')

# Or in-memory for throwaway analysis
# con = duckdb.connect()

# Helper: display SQL results as formatted DataFrame
def sql(query):
    return con.sql(query).df()
```

### Cell 2: Data Loading

```python
# Load once, query many times
con.execute("""
    CREATE TABLE IF NOT EXISTS events AS
    SELECT * FROM read_parquet('s3://data-lake/events/2024/**/*.parquet',
                               hive_partitioning=true)
""")

# Quick sanity check
sql("SELECT count(*), min(event_date), max(event_date) FROM events")
```

### Cell 3: Exploration

```python
# Profile the data
sql("""
    SELECT column_name, column_type, null_percentage, approx_unique, avg, min, max
    FROM (SUMMARIZE events)
""")
```

### Cell 4: Analysis + Visualization

```python
monthly = sql("""
    SELECT date_trunc('month', event_date) AS month,
           event_type,
           count(*) AS cnt
    FROM events
    GROUP BY ALL ORDER BY month
""")

fig, ax = plt.subplots(figsize=(12, 6))
for event_type in monthly['event_type'].unique():
    subset = monthly[monthly['event_type'] == event_type]
    ax.plot(subset['month'], subset['cnt'], label=event_type)
ax.legend()
ax.set_title('Events by Month')
plt.tight_layout()
```

### Cell 5: Export Results

```python
# Export query results to Parquet
con.execute("""
    COPY (
        SELECT * FROM events WHERE event_type = 'purchase'
    ) TO 'purchases_2024.parquet' (FORMAT parquet, COMPRESSION zstd)
""")
```

### Magic Commands (with jupysql)

```python
# pip install jupysql duckdb-engine
%load_ext sql
%sql duckdb:///notebook.duckdb

# Now use %%sql magic in cells
%%sql
SELECT product, sum(revenue) AS total
FROM sales
GROUP BY product
ORDER BY total DESC
LIMIT 10
```

---

## SQLAlchemy Integration

### Setup

```bash
pip install duckdb-engine sqlalchemy
```

### Basic Usage

```python
from sqlalchemy import create_engine, text
import pandas as pd

# File-backed database
engine = create_engine('duckdb:///analytics.duckdb')

# In-memory
engine = create_engine('duckdb:///:memory:')

# Read with pandas
df = pd.read_sql("SELECT * FROM sales WHERE year = 2024", engine)

# Write DataFrame to DuckDB table
df.to_sql('new_table', engine, if_exists='replace', index=False)

# Raw SQL execution
with engine.connect() as conn:
    conn.execute(text("CREATE TABLE t (id INT, name VARCHAR)"))
    conn.execute(text("INSERT INTO t VALUES (1, 'Alice'), (2, 'Bob')"))
    conn.commit()
```

### ORM Usage

```python
from sqlalchemy import Column, Integer, String, Float
from sqlalchemy.orm import declarative_base, Session

Base = declarative_base()

class Product(Base):
    __tablename__ = 'products'
    id = Column(Integer, primary_key=True)
    name = Column(String)
    price = Column(Float)

# Create tables
Base.metadata.create_all(engine)

# Insert
with Session(engine) as session:
    session.add(Product(id=1, name='Widget', price=9.99))
    session.commit()

# Query
with Session(engine) as session:
    products = session.query(Product).filter(Product.price < 100).all()
```

### With Alembic Migrations

```python
# alembic.ini:
# sqlalchemy.url = duckdb:///analytics.duckdb

# Standard Alembic workflow works:
# alembic init migrations
# alembic revision --autogenerate -m "add_products"
# alembic upgrade head
```

---

## Ibis Framework

Ibis lets you write pandas-like expressions that compile to DuckDB SQL.

### Setup

```bash
pip install ibis-framework[duckdb]
```

### Basic Usage

```python
import ibis

# Connect to DuckDB
con = ibis.duckdb.connect('analytics.duckdb')

# Or in-memory with Parquet
con = ibis.duckdb.connect()
con.read_parquet('sales.parquet', table_name='sales')

# Build expressions (lazy - no execution yet)
sales = con.table('sales')
result = (
    sales
    .filter(sales.year == 2024)
    .group_by('product')
    .agg(
        total_revenue=sales.revenue.sum(),
        avg_price=sales.price.mean(),
        order_count=sales.revenue.count()
    )
    .order_by(ibis.desc('total_revenue'))
)

# Execute (compiles to SQL and runs on DuckDB)
df = result.to_pandas()

# See the generated SQL
print(ibis.to_sql(result))
```

### Complex Analytics with Ibis

```python
# Window functions
sales = con.table('sales')
enriched = sales.mutate(
    rank=ibis.row_number().over(
        ibis.window(group_by='product', order_by=ibis.desc('revenue'))
    ),
    pct_of_total=sales.revenue / sales.revenue.sum().over(
        ibis.window(group_by='product')
    )
)

# Self-joins for period-over-period comparison
current = sales.filter(sales.year == 2024)
previous = sales.filter(sales.year == 2023)
comparison = current.join(
    previous,
    current.product == previous.product
).select(
    product=current.product,
    current_revenue=current.revenue,
    previous_revenue=previous.revenue,
    growth=current.revenue - previous.revenue
)
```

### Why Ibis over Raw SQL

- Type-safe expressions catch errors before execution.
- Backend-portable: switch from DuckDB to BigQuery/Spark by changing the connection.
- Composable: build queries programmatically without string concatenation.
- Integrates with pandas/plotting directly.

---

## Streaming Large Result Sets

### Arrow RecordBatch Streaming

```python
import duckdb

con = duckdb.connect()

# Fetch results in batches (constant memory)
result = con.execute("""
    SELECT * FROM read_parquet('huge_dataset.parquet')
    WHERE category = 'electronics'
""")

total_rows = 0
batch_num = 0
while True:
    batch = result.fetchmany(size=10000)
    if not batch:
        break
    batch_num += 1
    total_rows += len(batch)
    process_batch(batch)

print(f"Processed {total_rows} rows in {batch_num} batches")
```

### Arrow-Native Streaming

```python
# Most memory-efficient: Arrow RecordBatch reader
reader = con.execute("""
    SELECT * FROM read_parquet('100gb_file.parquet')
""").fetch_record_batch(rows_per_batch=100000)

import pyarrow.parquet as pq

# Stream directly to output Parquet file
writer = None
for batch in reader:
    if writer is None:
        writer = pq.ParquetWriter('output.parquet', batch.schema)
    writer.write_batch(batch)
if writer:
    writer.close()
```

### Chunked CSV Export

```python
# Process and export large results chunk by chunk
con = duckdb.connect()

reader = con.execute("""
    SELECT * FROM read_parquet('massive.parquet')
    WHERE value > threshold
""").fetch_record_batch(rows_per_batch=50000)

import csv

with open('output.csv', 'w', newline='') as f:
    writer = None
    for batch in reader:
        df_chunk = batch.to_pandas()
        if writer is None:
            df_chunk.to_csv(f, index=False)
        else:
            df_chunk.to_csv(f, index=False, header=False)
        writer = True
```

---

## Connection Pooling Patterns

DuckDB is embedded (no server), so traditional connection pooling doesn't apply the same way. Instead, manage connection lifecycle carefully.

### Thread-Safe Read Pool

```python
import duckdb
import threading
from contextlib import contextmanager

class DuckDBPool:
    """Manages read-only connections for multi-threaded access."""

    def __init__(self, db_path: str, pool_size: int = 4):
        self.db_path = db_path
        self._pool = []
        self._lock = threading.Lock()
        for _ in range(pool_size):
            self._pool.append(duckdb.connect(db_path, read_only=True))

    @contextmanager
    def connection(self):
        conn = None
        with self._lock:
            if self._pool:
                conn = self._pool.pop()
        if conn is None:
            conn = duckdb.connect(self.db_path, read_only=True)
        try:
            yield conn
        finally:
            with self._lock:
                self._pool.append(conn)

    def close_all(self):
        with self._lock:
            for conn in self._pool:
                conn.close()
            self._pool.clear()

# Usage
pool = DuckDBPool('analytics.duckdb', pool_size=8)

def handle_request(query):
    with pool.connection() as con:
        return con.execute(query).df()
```

### Cursor-Per-Thread Pattern

```python
import duckdb
from concurrent.futures import ThreadPoolExecutor

# Single connection, cursor per thread
con = duckdb.connect('data.duckdb', read_only=True)

def run_query(query):
    cursor = con.cursor()
    try:
        return cursor.execute(query).df()
    finally:
        cursor.close()

with ThreadPoolExecutor(max_workers=8) as executor:
    results = list(executor.map(run_query, queries))
```

### Write Serialization

```python
import queue
import threading

class DuckDBWriter:
    """Serializes all writes through a single connection."""

    def __init__(self, db_path: str):
        self._con = duckdb.connect(db_path)
        self._queue = queue.Queue()
        self._thread = threading.Thread(target=self._worker, daemon=True)
        self._thread.start()

    def _worker(self):
        while True:
            item = self._queue.get()
            if item is None:
                break
            query, params, event, result_holder = item
            try:
                result_holder['result'] = self._con.execute(query, params).df()
            except Exception as e:
                result_holder['error'] = e
            finally:
                event.set()

    def execute(self, query, params=None):
        event = threading.Event()
        result_holder = {}
        self._queue.put((query, params or [], event, result_holder))
        event.wait()
        if 'error' in result_holder:
            raise result_holder['error']
        return result_holder.get('result')

    def close(self):
        self._queue.put(None)
        self._thread.join()
        self._con.close()
```

---

## Embedding in Flask

```python
import duckdb
from flask import Flask, jsonify, request, g

app = Flask(__name__)
DB_PATH = 'analytics.duckdb'

def get_db():
    if 'db' not in g:
        g.db = duckdb.connect(DB_PATH, read_only=True)
    return g.db

@app.teardown_appcontext
def close_db(exception):
    db = g.pop('db', None)
    if db is not None:
        db.close()

@app.route('/api/summary')
def summary():
    con = get_db()
    start = request.args.get('start', '2024-01-01')
    end = request.args.get('end', '2024-12-31')

    result = con.execute("""
        SELECT date_trunc('month', event_date) AS month,
               count(*) AS events,
               approx_count_distinct(user_id) AS unique_users
        FROM events
        WHERE event_date BETWEEN ?::DATE AND ?::DATE
        GROUP BY 1 ORDER BY 1
    """, [start, end]).df()

    return jsonify(result.to_dict(orient='records'))

@app.route('/api/search')
def search():
    con = get_db()
    q = request.args.get('q', '')
    limit = int(request.args.get('limit', 20))

    result = con.execute("""
        SELECT id, title, snippet(body, 50) AS excerpt
        FROM documents
        WHERE body ILIKE '%' || ? || '%'
        LIMIT ?
    """, [q, limit]).df()

    return jsonify(result.to_dict(orient='records'))

if __name__ == '__main__':
    app.run(debug=True)
```

---

## Embedding in FastAPI

```python
import duckdb
from fastapi import FastAPI, Depends, Query, HTTPException
from contextlib import asynccontextmanager
from typing import Optional
import threading

DB_PATH = 'analytics.duckdb'

# Thread-local connections for read access
_local = threading.local()

def get_read_connection() -> duckdb.DuckDBPyConnection:
    if not hasattr(_local, 'con'):
        _local.con = duckdb.connect(DB_PATH, read_only=True)
    return _local.con

# Single write connection
_write_lock = threading.Lock()
_write_con: Optional[duckdb.DuckDBPyConnection] = None

@asynccontextmanager
async def lifespan(app: FastAPI):
    global _write_con
    _write_con = duckdb.connect(DB_PATH)
    yield
    _write_con.close()

app = FastAPI(lifespan=lifespan)

@app.get("/api/metrics")
def get_metrics(
    metric: str = Query(...),
    start: str = Query('2024-01-01'),
    end: str = Query('2024-12-31'),
    con: duckdb.DuckDBPyConnection = Depends(get_read_connection)
):
    result = con.execute("""
        SELECT date, value
        FROM metrics
        WHERE metric_name = ? AND date BETWEEN ?::DATE AND ?::DATE
        ORDER BY date
    """, [metric, start, end]).df()

    return result.to_dict(orient='records')

@app.post("/api/events")
def ingest_event(event: dict):
    with _write_lock:
        _write_con.execute("""
            INSERT INTO events (event_type, user_id, timestamp, data)
            VALUES (?, ?, current_timestamp, ?)
        """, [event['type'], event['user_id'], str(event.get('data', {}))])
    return {"status": "ok"}

@app.get("/api/query")
def run_query(
    q: str = Query(..., description="SQL query (SELECT only)"),
    con: duckdb.DuckDBPyConnection = Depends(get_read_connection)
):
    if not q.strip().upper().startswith('SELECT'):
        raise HTTPException(400, "Only SELECT queries allowed")
    try:
        result = con.execute(q).df()
        return result.head(1000).to_dict(orient='records')
    except Exception as e:
        raise HTTPException(400, str(e))
```

---

## Python UDFs

### Scalar UDFs

```python
import duckdb

con = duckdb.connect()

# Register a Python function as a DuckDB scalar UDF
def normalize_email(email: str) -> str:
    if email is None:
        return None
    return email.strip().lower()

con.create_function('normalize_email', normalize_email,
                    parameters=[duckdb.typing.VARCHAR],
                    return_type=duckdb.typing.VARCHAR)

con.execute("""
    SELECT normalize_email(email) AS clean_email
    FROM (VALUES ('Alice@Example.COM'), (' bob@test.org ')) AS t(email)
""").df()
```

### Vectorized UDFs (Faster)

```python
import pyarrow as pa

# Vectorized UDF operates on Arrow arrays (much faster than row-by-row)
def vec_double(values: pa.Array) -> pa.Array:
    return pa.compute.multiply(values, 2)

con.create_function('vec_double', vec_double,
                    parameters=[duckdb.typing.BIGINT],
                    return_type=duckdb.typing.BIGINT,
                    type='arrow')

con.execute("SELECT vec_double(i) FROM range(1000000) t(i)").df()
```

### Aggregate UDFs

```python
# Custom aggregate: weighted average
class WeightedAvg:
    def __init__(self):
        self.sum_wx = 0.0
        self.sum_w = 0.0

    def step(self, value, weight):
        if value is not None and weight is not None:
            self.sum_wx += value * weight
            self.sum_w += weight

    def finalize(self):
        return self.sum_wx / self.sum_w if self.sum_w else None

    def combine(self, other):
        self.sum_wx += other.sum_wx
        self.sum_w += other.sum_w

con.create_aggregate_function('weighted_avg', WeightedAvg)
con.execute("""
    SELECT product, weighted_avg(price, quantity) AS wavg_price
    FROM sales GROUP BY product
""").df()
```

---

## Testing Patterns

### Pytest Fixtures

```python
import pytest
import duckdb

@pytest.fixture
def db():
    """Fresh in-memory DuckDB for each test."""
    con = duckdb.connect()
    con.execute("""
        CREATE TABLE users (id INT, name VARCHAR, email VARCHAR);
        INSERT INTO users VALUES
            (1, 'Alice', 'alice@example.com'),
            (2, 'Bob', 'bob@example.com'),
            (3, 'Charlie', 'charlie@example.com');
    """)
    yield con
    con.close()

def test_user_count(db):
    result = db.execute("SELECT count(*) FROM users").fetchone()
    assert result[0] == 3

def test_email_lookup(db):
    result = db.execute(
        "SELECT name FROM users WHERE email = ?",
        ['alice@example.com']
    ).fetchone()
    assert result[0] == 'Alice'
```

### Testing ETL Pipelines

```python
import tempfile
import os

@pytest.fixture
def etl_env(tmp_path):
    """Set up temp files for ETL testing."""
    # Create test Parquet
    con = duckdb.connect()
    con.execute(f"""
        COPY (
            SELECT i AS id, 'item_' || i AS name, random() * 100 AS price
            FROM range(1000) t(i)
        ) TO '{tmp_path}/input.parquet' (FORMAT parquet)
    """)
    return con, tmp_path

def test_etl_transform(etl_env):
    con, tmp_path = etl_env
    input_path = f'{tmp_path}/input.parquet'
    output_path = f'{tmp_path}/output.parquet'

    # Run ETL
    con.execute(f"""
        COPY (
            SELECT id, name, round(price * 1.1, 2) AS price_with_tax
            FROM read_parquet('{input_path}')
            WHERE price > 10
        ) TO '{output_path}' (FORMAT parquet)
    """)

    # Verify output
    result = con.execute(f"""
        SELECT count(*), min(price_with_tax), max(price_with_tax)
        FROM read_parquet('{output_path}')
    """).fetchone()

    assert result[0] > 0
    assert result[1] > 11.0  # 10 * 1.1
```

### Testing SQL Macros

```python
def test_macro(db):
    db.execute("CREATE MACRO pct(a, b) AS round(a * 100.0 / b, 2)")
    result = db.execute("SELECT pct(25, 200)").fetchone()
    assert result[0] == 12.5

    result = db.execute("SELECT pct(0, 100)").fetchone()
    assert result[0] == 0.0
```
