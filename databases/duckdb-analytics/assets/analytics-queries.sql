-- ============================================================================
-- DuckDB Analytics Query Patterns
-- ============================================================================
-- Common analytical SQL patterns: cohort analysis, funnel analysis, retention,
-- sessionization, and moving averages. Copy/adapt for your tables.
-- ============================================================================

-- ────────────────────────────────────────────────────────────────────────────
-- 1. COHORT ANALYSIS
-- ────────────────────────────────────────────────────────────────────────────
-- Groups users by signup month, tracks behavior over subsequent months.

WITH user_cohort AS (
    SELECT user_id,
           date_trunc('month', min(event_date)) AS cohort_month
    FROM events
    GROUP BY user_id
),
user_activity AS (
    SELECT e.user_id,
           c.cohort_month,
           date_trunc('month', e.event_date) AS activity_month,
           datediff('month', c.cohort_month, date_trunc('month', e.event_date)) AS months_since_signup
    FROM events e
    JOIN user_cohort c USING (user_id)
)
SELECT cohort_month,
       months_since_signup,
       count(DISTINCT user_id) AS active_users,
       first_value(count(DISTINCT user_id)) OVER (
           PARTITION BY cohort_month ORDER BY months_since_signup
       ) AS cohort_size,
       round(100.0 * count(DISTINCT user_id) / first_value(count(DISTINCT user_id)) OVER (
           PARTITION BY cohort_month ORDER BY months_since_signup
       ), 1) AS retention_pct
FROM user_activity
GROUP BY cohort_month, months_since_signup
ORDER BY cohort_month, months_since_signup;


-- ────────────────────────────────────────────────────────────────────────────
-- 2. FUNNEL ANALYSIS
-- ────────────────────────────────────────────────────────────────────────────
-- Tracks conversion through a sequence of steps.

WITH funnel AS (
    SELECT user_id,
           max(CASE WHEN event_type = 'page_view' THEN 1 ELSE 0 END) AS step1_view,
           max(CASE WHEN event_type = 'add_to_cart' THEN 1 ELSE 0 END) AS step2_cart,
           max(CASE WHEN event_type = 'checkout_start' THEN 1 ELSE 0 END) AS step3_checkout,
           max(CASE WHEN event_type = 'purchase' THEN 1 ELSE 0 END) AS step4_purchase
    FROM events
    WHERE event_date BETWEEN '2024-01-01' AND '2024-03-31'
    GROUP BY user_id
)
SELECT 'Page View' AS step,
       sum(step1_view) AS users,
       100.0 AS pct_of_top
FROM funnel
UNION ALL
SELECT 'Add to Cart',
       sum(step2_cart),
       round(100.0 * sum(step2_cart) / NULLIF(sum(step1_view), 0), 1)
FROM funnel
UNION ALL
SELECT 'Checkout Start',
       sum(step3_checkout),
       round(100.0 * sum(step3_checkout) / NULLIF(sum(step1_view), 0), 1)
FROM funnel
UNION ALL
SELECT 'Purchase',
       sum(step4_purchase),
       round(100.0 * sum(step4_purchase) / NULLIF(sum(step1_view), 0), 1)
FROM funnel;


-- ────────────────────────────────────────────────────────────────────────────
-- 3. ORDERED FUNNEL (strict sequence with timestamps)
-- ────────────────────────────────────────────────────────────────────────────
-- Ensures each step happens AFTER the previous one.

WITH step1 AS (
    SELECT user_id, min(event_time) AS t1
    FROM events WHERE event_type = 'page_view'
    GROUP BY user_id
),
step2 AS (
    SELECT e.user_id, min(e.event_time) AS t2
    FROM events e JOIN step1 s ON e.user_id = s.user_id
    WHERE e.event_type = 'add_to_cart' AND e.event_time > s.t1
    GROUP BY e.user_id
),
step3 AS (
    SELECT e.user_id, min(e.event_time) AS t3
    FROM events e JOIN step2 s ON e.user_id = s.user_id
    WHERE e.event_type = 'purchase' AND e.event_time > s.t2
    GROUP BY e.user_id
)
SELECT
    (SELECT count(*) FROM step1) AS viewed,
    (SELECT count(*) FROM step2) AS added_to_cart,
    (SELECT count(*) FROM step3) AS purchased,
    round(100.0 * (SELECT count(*) FROM step3) /
          NULLIF((SELECT count(*) FROM step1), 0), 1) AS overall_conversion_pct;


-- ────────────────────────────────────────────────────────────────────────────
-- 4. RETENTION ANALYSIS (Day N retention)
-- ────────────────────────────────────────────────────────────────────────────

WITH first_seen AS (
    SELECT user_id, min(event_date) AS first_date
    FROM events GROUP BY user_id
),
retention AS (
    SELECT f.first_date AS cohort_date,
           datediff('day', f.first_date, e.event_date) AS day_n,
           count(DISTINCT e.user_id) AS returning_users
    FROM events e
    JOIN first_seen f USING (user_id)
    WHERE datediff('day', f.first_date, e.event_date) IN (0, 1, 3, 7, 14, 30)
    GROUP BY cohort_date, day_n
)
SELECT cohort_date,
       max(CASE WHEN day_n = 0 THEN returning_users END) AS day_0,
       max(CASE WHEN day_n = 1 THEN returning_users END) AS day_1,
       max(CASE WHEN day_n = 3 THEN returning_users END) AS day_3,
       max(CASE WHEN day_n = 7 THEN returning_users END) AS day_7,
       max(CASE WHEN day_n = 14 THEN returning_users END) AS day_14,
       max(CASE WHEN day_n = 30 THEN returning_users END) AS day_30
FROM retention
GROUP BY cohort_date
ORDER BY cohort_date;


-- ────────────────────────────────────────────────────────────────────────────
-- 5. SESSIONIZATION
-- ────────────────────────────────────────────────────────────────────────────
-- Groups events into sessions with a 30-minute inactivity timeout.

WITH ordered_events AS (
    SELECT *,
           lag(event_time) OVER (PARTITION BY user_id ORDER BY event_time) AS prev_time
    FROM events
),
session_starts AS (
    SELECT *,
           CASE WHEN prev_time IS NULL
                     OR event_time - prev_time > INTERVAL '30 minutes'
                THEN 1 ELSE 0 END AS is_new_session
    FROM ordered_events
),
sessions AS (
    SELECT *,
           sum(is_new_session) OVER (
               PARTITION BY user_id ORDER BY event_time
           ) AS session_id
    FROM session_starts
)
SELECT user_id,
       session_id,
       min(event_time) AS session_start,
       max(event_time) AS session_end,
       age(max(event_time), min(event_time)) AS session_duration,
       count(*) AS events_in_session,
       list(DISTINCT event_type) AS event_types
FROM sessions
GROUP BY user_id, session_id
ORDER BY user_id, session_start;


-- ────────────────────────────────────────────────────────────────────────────
-- 6. MOVING AVERAGES AND TIME SERIES
-- ────────────────────────────────────────────────────────────────────────────

-- 7-day moving average
SELECT date,
       revenue,
       avg(revenue) OVER (
           ORDER BY date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
       ) AS ma_7d,
       avg(revenue) OVER (
           ORDER BY date ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
       ) AS ma_30d
FROM daily_revenue
ORDER BY date;

-- Exponential weighted moving average (approximation)
WITH numbered AS (
    SELECT date, revenue, row_number() OVER (ORDER BY date) AS rn
    FROM daily_revenue
)
SELECT date, revenue,
       sum(revenue * power(0.9, rn_max - rn)) / sum(power(0.9, rn_max - rn)) AS ewma
FROM numbered, (SELECT max(rn) AS rn_max FROM numbered)
GROUP BY date, revenue
ORDER BY date;

-- Period-over-period comparison
SELECT date,
       revenue,
       lag(revenue, 7) OVER (ORDER BY date) AS revenue_7d_ago,
       revenue - lag(revenue, 7) OVER (ORDER BY date) AS wow_change,
       round(100.0 * (revenue - lag(revenue, 7) OVER (ORDER BY date)) /
             NULLIF(lag(revenue, 7) OVER (ORDER BY date), 0), 1) AS wow_pct_change
FROM daily_revenue;

-- Cumulative sum with reset per month
SELECT date, revenue,
       sum(revenue) OVER (
           PARTITION BY date_trunc('month', date) ORDER BY date
       ) AS mtd_revenue
FROM daily_revenue;


-- ────────────────────────────────────────────────────────────────────────────
-- 7. TOP-N PER GROUP
-- ────────────────────────────────────────────────────────────────────────────

-- Top 3 products per category by revenue
SELECT * FROM (
    SELECT category, product, revenue,
           row_number() OVER (PARTITION BY category ORDER BY revenue DESC) AS rn
    FROM products
) QUALIFY rn <= 3;


-- ────────────────────────────────────────────────────────────────────────────
-- 8. GAPS AND ISLANDS
-- ────────────────────────────────────────────────────────────────────────────
-- Find consecutive ranges in data (e.g., uptime streaks, login streaks).

WITH numbered AS (
    SELECT user_id, login_date,
           login_date - INTERVAL (row_number() OVER (
               PARTITION BY user_id ORDER BY login_date
           )) DAY AS grp
    FROM daily_logins
)
SELECT user_id,
       min(login_date) AS streak_start,
       max(login_date) AS streak_end,
       datediff('day', min(login_date), max(login_date)) + 1 AS streak_days
FROM numbered
GROUP BY user_id, grp
HAVING streak_days >= 3
ORDER BY streak_days DESC;


-- ────────────────────────────────────────────────────────────────────────────
-- 9. PERCENTILE ANALYSIS
-- ────────────────────────────────────────────────────────────────────────────

SELECT category,
       count(*) AS n,
       approx_quantile(price, 0.25) AS p25,
       approx_quantile(price, 0.50) AS median,
       approx_quantile(price, 0.75) AS p75,
       approx_quantile(price, 0.90) AS p90,
       approx_quantile(price, 0.95) AS p95,
       approx_quantile(price, 0.99) AS p99,
       approx_quantile(price, 0.75) - approx_quantile(price, 0.25) AS iqr
FROM products
GROUP BY category;


-- ────────────────────────────────────────────────────────────────────────────
-- 10. CHANGE DATA CAPTURE (CDC) / SCD TYPE 2
-- ────────────────────────────────────────────────────────────────────────────

WITH changes AS (
    SELECT *,
           lag(value) OVER (PARTITION BY entity_id ORDER BY updated_at) AS prev_value,
           lead(updated_at) OVER (PARTITION BY entity_id ORDER BY updated_at) AS next_update
    FROM entity_history
)
SELECT entity_id,
       value,
       updated_at AS valid_from,
       COALESCE(next_update, '9999-12-31'::TIMESTAMP) AS valid_to,
       value != prev_value OR prev_value IS NULL AS is_change
FROM changes
WHERE value != prev_value OR prev_value IS NULL;
