#!/usr/bin/env python3
"""
Polars Data Exploration Starter Script

A structured template for interactive data exploration with Polars.
Use this as a starting point in Jupyter notebooks or interactive Python sessions.

Sections:
  1. Setup and Configuration
  2. Data Loading
  3. Initial Exploration
  4. Data Profiling
  5. Cleaning and Preparation
  6. Analysis and Aggregation
  7. Visualization (optional, with matplotlib/seaborn)
  8. Export Results

Usage:
    python jupyter-starter.py                     # run as script
    # Or copy sections into Jupyter notebook cells
"""

# ═══════════════════════════════════════════════════════════════════════
# Section 1: Setup and Configuration
# ═══════════════════════════════════════════════════════════════════════

import polars as pl
import polars.selectors as cs

# Configure Polars display
pl.Config.set_tbl_rows(20)
pl.Config.set_tbl_cols(15)
pl.Config.set_fmt_str_lengths(50)
pl.Config.set_tbl_width_chars(120)

# File paths — customize these
INPUT_PATH = "data/sample.parquet"    # or .csv, .ndjson
OUTPUT_PATH = "data/results.parquet"

print(f"Polars version: {pl.__version__}")


# ═══════════════════════════════════════════════════════════════════════
# Section 2: Data Loading
# ═══════════════════════════════════════════════════════════════════════

# --- Option A: Load from file ---
# df = pl.read_parquet(INPUT_PATH)
# df = pl.read_csv(INPUT_PATH)

# --- Option B: Generate sample data for exploration ---
import random
random.seed(42)

N = 10_000
df = pl.DataFrame({
    "id": range(N),
    "date": pl.date_range(pl.date(2023, 1, 1), pl.date(2024, 12, 31), eager=True).sample(N, seed=42),
    "category": [random.choice(["Electronics", "Clothing", "Food", "Books", "Sports"]) for _ in range(N)],
    "region": [random.choice(["North", "South", "East", "West"]) for _ in range(N)],
    "quantity": [random.randint(1, 50) for _ in range(N)],
    "unit_price": [round(random.uniform(5.0, 500.0), 2) for _ in range(N)],
    "discount": [round(random.choice([0, 0, 0, 0.05, 0.1, 0.15, 0.2]), 2) for _ in range(N)],
    "customer_id": [f"C{random.randint(1, 500):04d}" for _ in range(N)],
})

print(f"Loaded: {df.shape[0]:,} rows × {df.shape[1]} columns")
print(df.head(5))


# ═══════════════════════════════════════════════════════════════════════
# Section 3: Initial Exploration
# ═══════════════════════════════════════════════════════════════════════

# Schema
print("\n--- Schema ---")
for col, dtype in df.schema.items():
    print(f"  {col:20s} {dtype}")

# Basic stats
print("\n--- Describe ---")
print(df.describe())

# Shape and memory
print(f"\nShape: {df.shape}")
print(f"Memory: {df.estimated_size() / 1024**2:.2f} MB")

# Sample rows
print("\n--- Random Sample ---")
print(df.sample(5, seed=42))


# ═══════════════════════════════════════════════════════════════════════
# Section 4: Data Profiling
# ═══════════════════════════════════════════════════════════════════════

# Null analysis
print("\n--- Null Counts ---")
null_report = df.select(
    pl.all().null_count()
).unpivot(variable_name="column", value_name="null_count").filter(
    pl.col("null_count") > 0
)
if len(null_report) > 0:
    print(null_report)
else:
    print("  No nulls found!")

# Unique value counts
print("\n--- Unique Values ---")
for col in df.columns:
    n_unique = df[col].n_unique()
    print(f"  {col:20s} {n_unique:>8,} unique ({n_unique/len(df)*100:.1f}%)")

# Value distributions for categorical columns
print("\n--- Category Distribution ---")
for col in df.select(cs.string()).columns:
    print(f"\n  {col}:")
    vc = df[col].value_counts().sort("count", descending=True).head(10)
    for row in vc.iter_rows():
        print(f"    {row[0]:30s} {row[1]:>6,}")


# ═══════════════════════════════════════════════════════════════════════
# Section 5: Cleaning and Preparation
# ═══════════════════════════════════════════════════════════════════════

df_clean = (
    df
    # Add computed columns
    .with_columns(
        (pl.col("quantity") * pl.col("unit_price")).alias("gross_amount"),
        (pl.col("quantity") * pl.col("unit_price") * (1 - pl.col("discount"))).alias("net_amount"),
        pl.col("date").dt.year().alias("year"),
        pl.col("date").dt.month().alias("month"),
        pl.col("date").dt.weekday().alias("day_of_week"),  # Monday=1
    )
    # Fill nulls if any
    .fill_null(strategy="zero")
)

print(f"\nCleaned: {df_clean.shape[0]:,} rows × {df_clean.shape[1]} columns")
print(df_clean.head(3))


# ═══════════════════════════════════════════════════════════════════════
# Section 6: Analysis and Aggregation
# ═══════════════════════════════════════════════════════════════════════

# --- Revenue by category ---
print("\n--- Revenue by Category ---")
by_category = (
    df_clean
    .group_by("category")
    .agg(
        pl.col("net_amount").sum().alias("total_revenue"),
        pl.col("net_amount").mean().alias("avg_order"),
        pl.col("id").count().alias("order_count"),
        pl.col("customer_id").n_unique().alias("unique_customers"),
    )
    .sort("total_revenue", descending=True)
    .with_columns(
        (pl.col("total_revenue") / pl.col("total_revenue").sum() * 100).round(1).alias("revenue_pct"),
    )
)
print(by_category)

# --- Monthly trends ---
print("\n--- Monthly Revenue Trend ---")
monthly = (
    df_clean
    .group_by("year", "month")
    .agg(
        pl.col("net_amount").sum().alias("revenue"),
        pl.col("id").count().alias("orders"),
    )
    .sort("year", "month")
)
print(monthly)

# --- Top customers ---
print("\n--- Top 10 Customers ---")
top_customers = (
    df_clean
    .group_by("customer_id")
    .agg(
        pl.col("net_amount").sum().alias("total_spent"),
        pl.col("id").count().alias("order_count"),
        pl.col("category").n_unique().alias("categories_bought"),
    )
    .sort("total_spent", descending=True)
    .head(10)
)
print(top_customers)

# --- Category × Region cross-tab ---
print("\n--- Revenue: Category × Region ---")
cross_tab = (
    df_clean
    .group_by("category", "region")
    .agg(pl.col("net_amount").sum().alias("revenue"))
    .pivot(on="region", index="category", values="revenue", aggregate_function="first")
    .fill_null(0)
    .sort("category")
)
print(cross_tab)

# --- Window functions: rank within category ---
print("\n--- Top 3 Orders per Category ---")
ranked = (
    df_clean
    .with_columns(
        pl.col("net_amount")
          .rank(descending=True)
          .over("category")
          .alias("rank"),
    )
    .filter(pl.col("rank") <= 3)
    .sort("category", "rank")
    .select("category", "rank", "id", "net_amount", "customer_id")
)
print(ranked)


# ═══════════════════════════════════════════════════════════════════════
# Section 7: Visualization (Optional)
# ═══════════════════════════════════════════════════════════════════════

# Uncomment if matplotlib is available:
#
# import matplotlib.pyplot as plt
#
# # Revenue by category bar chart
# cat_data = by_category.to_pandas()
# fig, ax = plt.subplots(figsize=(10, 5))
# ax.barh(cat_data["category"], cat_data["total_revenue"])
# ax.set_xlabel("Total Revenue")
# ax.set_title("Revenue by Category")
# plt.tight_layout()
# plt.savefig("revenue_by_category.png", dpi=150)
# plt.show()
#
# # Monthly trend line chart
# monthly_data = monthly.to_pandas()
# monthly_data["period"] = monthly_data["year"].astype(str) + "-" + monthly_data["month"].astype(str).str.zfill(2)
# fig, ax = plt.subplots(figsize=(12, 5))
# ax.plot(monthly_data["period"], monthly_data["revenue"], marker="o")
# ax.set_xlabel("Month")
# ax.set_ylabel("Revenue")
# ax.set_title("Monthly Revenue Trend")
# plt.xticks(rotation=45)
# plt.tight_layout()
# plt.savefig("monthly_trend.png", dpi=150)
# plt.show()

print("\n(Uncomment Section 7 for matplotlib visualizations)")


# ═══════════════════════════════════════════════════════════════════════
# Section 8: Export Results
# ═══════════════════════════════════════════════════════════════════════

# Export to various formats:
# df_clean.write_parquet(OUTPUT_PATH, compression="zstd")
# df_clean.write_csv("results.csv")
# by_category.write_csv("category_summary.csv")

print("\n(Uncomment Section 8 export lines to save results)")
print("\n✓ Exploration complete!")
