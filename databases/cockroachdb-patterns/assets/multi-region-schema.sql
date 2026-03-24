-- Multi-Region Schema Example for CockroachDB
--
-- Prerequisites:
--   - 3+ regions configured with locality flags on nodes
--   - Enterprise license for multi-region features
--
-- Regions: us-east1 (primary), us-west2, eu-west1

-- ============================================================
-- Database Configuration
-- ============================================================

CREATE DATABASE IF NOT EXISTS commerce;
USE commerce;

ALTER DATABASE commerce PRIMARY REGION "us-east1";
ALTER DATABASE commerce ADD REGION "us-west2";
ALTER DATABASE commerce ADD REGION "eu-west1";

-- Survive an entire region going down
ALTER DATABASE commerce SURVIVE REGION FAILURE;

-- ============================================================
-- REGIONAL BY ROW Tables — per-row region placement
-- ============================================================

-- Users: each user is homed in their region for low-latency access
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email STRING NOT NULL,
    name STRING NOT NULL,
    country_code STRING(2) NOT NULL,
    profile JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE users SET LOCALITY REGIONAL BY ROW;
ALTER TABLE users ADD CONSTRAINT unique_email UNIQUE WITHOUT INDEX (email);
CREATE INDEX idx_users_email ON users (crdb_region, email);

-- Orders: co-located with the user who placed them
CREATE TABLE orders (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    status STRING NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'confirmed', 'shipped', 'delivered', 'cancelled')),
    subtotal DECIMAL(12,2) NOT NULL DEFAULT 0,
    tax DECIMAL(12,2) NOT NULL DEFAULT 0,
    total DECIMAL(12,2) NOT NULL DEFAULT 0,
    shipping_address JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT fk_orders_user FOREIGN KEY (user_id, crdb_region)
        REFERENCES users (id, crdb_region)
);
ALTER TABLE orders SET LOCALITY REGIONAL BY ROW;
CREATE INDEX idx_orders_user ON orders (crdb_region, user_id, created_at DESC);
CREATE INDEX idx_orders_status ON orders (crdb_region, status);

-- Order items: co-located with order
CREATE TABLE order_items (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id UUID NOT NULL,
    product_id UUID NOT NULL,
    quantity INT NOT NULL DEFAULT 1 CHECK (quantity > 0),
    unit_price DECIMAL(10,2) NOT NULL,
    total_price DECIMAL(10,2) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE order_items SET LOCALITY REGIONAL BY ROW;
CREATE INDEX idx_order_items_order ON order_items (crdb_region, order_id);

-- User sessions: regional for fast auth checks
CREATE TABLE user_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL,
    token STRING NOT NULL,
    ip_address INET,
    user_agent STRING,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE user_sessions SET LOCALITY REGIONAL BY ROW;
CREATE INDEX idx_sessions_token ON user_sessions (crdb_region, token);
CREATE INDEX idx_sessions_user ON user_sessions (crdb_region, user_id);
CREATE INDEX idx_sessions_expiry ON user_sessions (crdb_region, expires_at);

-- ============================================================
-- GLOBAL Tables — fast reads everywhere, slow writes
-- ============================================================

-- Products: catalog data read from all regions, updated infrequently
CREATE TABLE products (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sku STRING UNIQUE NOT NULL,
    name STRING NOT NULL,
    description STRING,
    base_price DECIMAL(10,2) NOT NULL,
    currency STRING(3) NOT NULL DEFAULT 'USD',
    category STRING NOT NULL,
    attributes JSONB DEFAULT '{}',
    active BOOL NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE products SET LOCALITY GLOBAL;
CREATE INDEX idx_products_category ON products (category) WHERE active = true;
CREATE INDEX idx_products_attrs ON products USING GIN (attributes);

-- Currencies: reference data
CREATE TABLE currencies (
    code STRING(3) PRIMARY KEY,
    name STRING NOT NULL,
    symbol STRING(5) NOT NULL,
    exchange_rate_to_usd DECIMAL(12,6) NOT NULL DEFAULT 1.0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE currencies SET LOCALITY GLOBAL;

-- Countries: reference data
CREATE TABLE countries (
    code STRING(2) PRIMARY KEY,
    name STRING NOT NULL,
    default_currency STRING(3) NOT NULL REFERENCES currencies(code),
    default_region crdb_internal_region,
    active BOOL NOT NULL DEFAULT true
);
ALTER TABLE countries SET LOCALITY GLOBAL;

-- Feature flags: application config read from all regions
CREATE TABLE feature_flags (
    key STRING PRIMARY KEY,
    value JSONB NOT NULL DEFAULT 'false',
    description STRING,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by STRING
);
ALTER TABLE feature_flags SET LOCALITY GLOBAL;

-- Tax rates: regional tax rules, read globally
CREATE TABLE tax_rates (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    country_code STRING(2) NOT NULL REFERENCES countries(code),
    region_code STRING(10),
    rate DECIMAL(5,4) NOT NULL,
    category STRING NOT NULL DEFAULT 'standard',
    effective_from DATE NOT NULL,
    effective_to DATE,
    UNIQUE (country_code, region_code, category, effective_from)
);
ALTER TABLE tax_rates SET LOCALITY GLOBAL;

-- ============================================================
-- REGIONAL BY TABLE — entire table in one region
-- ============================================================

-- Audit log: compliance data pinned to EU region
CREATE TABLE eu_audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entity_type STRING NOT NULL,
    entity_id UUID NOT NULL,
    action STRING NOT NULL,
    actor_id UUID,
    old_value JSONB,
    new_value JSONB,
    ip_address INET,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE eu_audit_log SET LOCALITY REGIONAL BY TABLE IN "eu-west1";
CREATE INDEX idx_audit_entity ON eu_audit_log (entity_type, entity_id, created_at DESC);
CREATE INDEX idx_audit_actor ON eu_audit_log (actor_id, created_at DESC)
    WHERE actor_id IS NOT NULL;

-- Analytics events: high-write table in primary region
CREATE TABLE analytics_events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type STRING NOT NULL,
    user_id UUID,
    properties JSONB DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE analytics_events SET LOCALITY REGIONAL BY TABLE IN "us-east1";
CREATE INDEX idx_analytics_type_ts
    ON analytics_events (event_type, created_at DESC)
    USING HASH WITH (bucket_count = 8);

-- ============================================================
-- Sample Data
-- ============================================================

-- Insert reference data
INSERT INTO currencies (code, name, symbol, exchange_rate_to_usd) VALUES
    ('USD', 'US Dollar', '$', 1.000000),
    ('EUR', 'Euro', '€', 0.920000),
    ('GBP', 'British Pound', '£', 0.790000);

INSERT INTO countries (code, name, default_currency, default_region) VALUES
    ('US', 'United States', 'USD', 'us-east1'),
    ('DE', 'Germany', 'EUR', 'eu-west1'),
    ('GB', 'United Kingdom', 'GBP', 'eu-west1');

INSERT INTO feature_flags (key, value, description) VALUES
    ('dark_mode', 'true', 'Enable dark mode UI'),
    ('new_checkout', 'false', 'New checkout flow (beta)'),
    ('max_cart_items', '50', 'Maximum items in shopping cart');

-- Insert sample users in different regions
INSERT INTO users (email, name, country_code, crdb_region) VALUES
    ('alice@example.com', 'Alice Smith', 'US', 'us-east1'),
    ('bob@example.com', 'Bob Johnson', 'US', 'us-west2'),
    ('claire@example.de', 'Claire Mueller', 'DE', 'eu-west1');

INSERT INTO products (sku, name, description, base_price, category) VALUES
    ('WIDGET-001', 'Standard Widget', 'A reliable widget', 29.99, 'widgets'),
    ('GADGET-001', 'Super Gadget', 'An amazing gadget', 149.99, 'gadgets'),
    ('DOOHICKEY-001', 'Premium Doohickey', 'Top-tier doohickey', 79.99, 'doohickeys');
