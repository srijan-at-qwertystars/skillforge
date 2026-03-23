"""
Jupyter Notebook Setup for DuckDB
==================================
Run this cell at the top of any DuckDB-powered Jupyter notebook.
Sets up: DuckDB connection, SQL magic commands, display helpers,
and visualization utilities.

Usage in Jupyter:
    %run jupyter-setup.py
    # or copy-paste cells into your notebook

Requires: pip install duckdb jupysql duckdb-engine pandas matplotlib
Optional: pip install plotly seaborn pyarrow polars
"""

import duckdb
import pandas as pd
import warnings
from pathlib import Path

warnings.filterwarnings("ignore", category=DeprecationWarning)

# ── DuckDB Connection ────────────────────────────────────

# Change to a file path for persistent storage: duckdb.connect('notebook.duckdb')
DB_PATH = ":memory:"
con = duckdb.connect(DB_PATH)

# Configure for interactive use
con.execute("SET enable_progress_bar = true")
con.execute("SET enable_progress_bar_print = true")
con.execute("SET autoinstall_known_extensions = true")
con.execute("SET autoload_known_extensions = true")
con.execute("SET enable_object_cache = true")

print(f"DuckDB {duckdb.__version__} connected ({DB_PATH})")


# ── Helper Functions ─────────────────────────────────────

def sql(query: str, params: list = None) -> pd.DataFrame:
    """Execute SQL and return a pandas DataFrame.

    Usage:
        df = sql("SELECT * FROM my_table WHERE id = ?", [42])
        sql("SUMMARIZE my_table")
    """
    if params:
        return con.execute(query, params).df()
    return con.sql(query).df()


def sql_show(query: str, max_rows: int = 50):
    """Execute SQL and display the result (no variable assignment needed).

    Usage:
        sql_show("SELECT * FROM my_table LIMIT 10")
    """
    df = sql(query)
    with pd.option_context("display.max_rows", max_rows, "display.max_columns", None):
        from IPython.display import display
        display(df)


def load_file(path: str, table_name: str = None) -> str:
    """Load a file (Parquet/CSV/JSON) into a DuckDB table.

    Returns the table name.

    Usage:
        load_file('data.parquet')
        load_file('sales.csv', 'sales')
    """
    p = Path(path)
    name = table_name or p.stem.replace("-", "_").replace(".", "_")

    ext = p.suffix.lower()
    if ext in (".parquet", ".pq"):
        reader = f"read_parquet('{path}')"
    elif ext in (".csv", ".tsv"):
        reader = f"read_csv_auto('{path}')"
    elif ext in (".json", ".jsonl", ".ndjson"):
        reader = f"read_json_auto('{path}')"
    else:
        reader = f"read_csv_auto('{path}')"

    con.execute(f"CREATE OR REPLACE TABLE {name} AS SELECT * FROM {reader}")
    row_count = con.execute(f"SELECT count(*) FROM {name}").fetchone()[0]
    col_count = len(con.execute(f"DESCRIBE {name}").df())
    print(f"Loaded '{name}': {row_count:,} rows × {col_count} columns")
    return name


def profile(table_name: str) -> pd.DataFrame:
    """Profile a table: types, nulls, unique counts, min/max, stats.

    Usage:
        profile('my_table')
    """
    return sql(f"SUMMARIZE {table_name}")


def tables() -> pd.DataFrame:
    """List all tables in the current database."""
    return sql("""
        SELECT table_name, column_count, estimated_size
        FROM duckdb_tables()
        ORDER BY table_name
    """)


def schema(table_name: str) -> pd.DataFrame:
    """Show schema for a table."""
    return sql(f"DESCRIBE {table_name}")


# ── Visualization Helpers ────────────────────────────────

def plot_timeseries(query: str, x: str, y: str, title: str = "",
                    figsize: tuple = (12, 5)):
    """Plot a time series from a SQL query.

    Usage:
        plot_timeseries(
            "SELECT date, revenue FROM daily_metrics ORDER BY date",
            x='date', y='revenue', title='Daily Revenue'
        )
    """
    import matplotlib.pyplot as plt

    df = sql(query)
    fig, ax = plt.subplots(figsize=figsize)
    ax.plot(df[x], df[y])
    ax.set_title(title or f"{y} over {x}")
    ax.set_xlabel(x)
    ax.set_ylabel(y)
    fig.autofmt_xdate()
    plt.tight_layout()
    plt.show()


def plot_bar(query: str, x: str, y: str, title: str = "",
             figsize: tuple = (10, 5), horizontal: bool = False):
    """Plot a bar chart from a SQL query.

    Usage:
        plot_bar(
            "SELECT product, sum(revenue) AS total FROM sales GROUP BY product",
            x='product', y='total'
        )
    """
    import matplotlib.pyplot as plt

    df = sql(query)
    fig, ax = plt.subplots(figsize=figsize)
    if horizontal:
        ax.barh(df[x], df[y])
    else:
        ax.bar(df[x], df[y])
    ax.set_title(title or f"{y} by {x}")
    ax.set_xlabel(x if not horizontal else y)
    ax.set_ylabel(y if not horizontal else x)
    plt.xticks(rotation=45, ha="right")
    plt.tight_layout()
    plt.show()


def plot_distribution(query: str, column: str, bins: int = 50,
                      title: str = "", figsize: tuple = (10, 5)):
    """Plot histogram from a SQL query.

    Usage:
        plot_distribution("SELECT price FROM products", 'price', bins=30)
    """
    import matplotlib.pyplot as plt

    df = sql(query)
    fig, ax = plt.subplots(figsize=figsize)
    ax.hist(df[column].dropna(), bins=bins, edgecolor="white", alpha=0.8)
    ax.set_title(title or f"Distribution of {column}")
    ax.set_xlabel(column)
    ax.set_ylabel("Count")
    plt.tight_layout()
    plt.show()


# ── SQL Magic (jupysql) ─────────────────────────────────

def setup_sql_magic():
    """Enable %%sql magic cells. Call once per notebook.

    After setup, use:
        %%sql
        SELECT * FROM my_table LIMIT 10
    """
    try:
        from IPython import get_ipython
        ipython = get_ipython()
        if ipython is None:
            print("Not in IPython/Jupyter. SQL magic not available.")
            return

        ipython.run_line_magic("load_ext", "sql")

        connection_string = f"duckdb:///{DB_PATH}" if DB_PATH != ":memory:" else "duckdb:///:memory:"
        ipython.run_line_magic("sql", connection_string)

        # Configure jupysql display
        ipython.run_line_magic("config", "SqlMagic.displaylimit = 50")
        ipython.run_line_magic("config", "SqlMagic.autolimit = 100")

        print("SQL magic enabled. Use %%sql in cells.")
    except ImportError:
        print("jupysql not installed. Run: pip install jupysql duckdb-engine")
    except Exception as e:
        print(f"SQL magic setup failed: {e}")


# ── Quick Reference ──────────────────────────────────────

QUICK_REF = """
╔══════════════════════════════════════════════════════════════╗
║  DuckDB Jupyter Quick Reference                             ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  sql("SELECT ...")           → pandas DataFrame              ║
║  sql_show("SELECT ...")      → display inline                ║
║  load_file('data.parquet')   → load into table               ║
║  profile('table_name')       → column stats & types          ║
║  schema('table_name')        → column names & types          ║
║  tables()                    → list all tables               ║
║                                                              ║
║  plot_timeseries(q, x, y)    → line chart                    ║
║  plot_bar(q, x, y)           → bar chart                     ║
║  plot_distribution(q, col)   → histogram                     ║
║                                                              ║
║  setup_sql_magic()           → enable %%sql cells            ║
║  con.sql("...").df()         → direct DuckDB query           ║
║  con.sql("...").pl()         → return as Polars DataFrame    ║
║  con.sql("...").arrow()      → return as Arrow Table         ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
"""
print(QUICK_REF)
