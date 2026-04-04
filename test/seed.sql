-- seed.sql — Generate ~10GB of test data
-- Targets: users (~200MB), products (~100MB), orders (~2GB), order_items (~3GB),
--          events (~3GB), audit_log (~2GB)

BEGIN;

-- =========================================================================
-- Schema
-- =========================================================================

CREATE TABLE users (
    id          bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    email       text NOT NULL UNIQUE,
    name        text NOT NULL,
    bio         text,
    metadata    jsonb DEFAULT '{}',
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE products (
    id          bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    sku         text NOT NULL UNIQUE,
    name        text NOT NULL,
    description text,
    price       numeric(10,2) NOT NULL,
    category    text NOT NULL,
    tags        text[],
    attributes  jsonb DEFAULT '{}',
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE orders (
    id          bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    user_id     bigint NOT NULL REFERENCES users(id),
    status      text NOT NULL DEFAULT 'pending',
    total       numeric(12,2) NOT NULL,
    currency    text NOT NULL DEFAULT 'USD',
    notes       text,
    shipping    jsonb,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE order_items (
    id          bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    order_id    bigint NOT NULL REFERENCES orders(id),
    product_id  bigint NOT NULL REFERENCES products(id),
    quantity    int NOT NULL DEFAULT 1,
    unit_price  numeric(10,2) NOT NULL,
    subtotal    numeric(12,2) NOT NULL,
    metadata    jsonb DEFAULT '{}'
);

CREATE TABLE events (
    id          bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    user_id     bigint REFERENCES users(id),
    event_type  text NOT NULL,
    payload     jsonb NOT NULL DEFAULT '{}',
    ip_address  inet,
    user_agent  text,
    session_id  uuid,
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE audit_log (
    id          bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    table_name  text NOT NULL,
    record_id   bigint NOT NULL,
    action      text NOT NULL,
    old_data    jsonb,
    new_data    jsonb,
    performed_by bigint REFERENCES users(id),
    created_at  timestamptz NOT NULL DEFAULT now()
);

COMMIT;

-- =========================================================================
-- Data — each INSERT runs outside the big transaction for progress visibility
-- =========================================================================

-- users: 500K rows, ~200MB
-- (~400 bytes/row)
\echo '>>> Inserting users (500K rows, ~200MB)...'
INSERT INTO users (email, name, bio, metadata, created_at, updated_at)
SELECT
    'user' || g || '@example.com',
    'User ' || g || ' ' || substr(md5(g::text), 1, 8),
    repeat(substr(md5(g::text), 1, 16), 10),                         -- ~160 chars bio
    jsonb_build_object(
        'plan', (ARRAY['free','starter','pro','enterprise'])[1 + (g % 4)],
        'region', (ARRAY['us-east','us-west','eu-west','ap-south'])[1 + (g % 4)],
        'signup_source', (ARRAY['organic','referral','ad','partner'])[1 + (g % 4)],
        'preferences', jsonb_build_object('theme', CASE WHEN g % 2 = 0 THEN 'dark' ELSE 'light' END)
    ),
    now() - (random() * interval '730 days'),
    now() - (random() * interval '30 days')
FROM generate_series(1, 500000) g;

\echo '>>> Inserting products (100K rows, ~100MB)...'
INSERT INTO products (sku, name, description, price, category, tags, attributes, created_at)
SELECT
    'SKU-' || lpad(g::text, 8, '0'),
    'Product ' || g || ' ' || substr(md5(g::text), 1, 6),
    repeat(substr(md5((g * 7)::text), 1, 20), 20),                   -- ~400 chars description
    (random() * 999 + 1)::numeric(10,2),
    (ARRAY['electronics','clothing','home','sports','books','food','toys','health'])[1 + (g % 8)],
    ARRAY[
        (ARRAY['sale','new','popular','limited','eco'])[1 + (g % 5)],
        (ARRAY['featured','clearance','seasonal','exclusive','bundle'])[1 + (g % 5)]
    ],
    jsonb_build_object(
        'weight_kg', (random() * 20)::numeric(4,2),
        'color', (ARRAY['red','blue','green','black','white'])[1 + (g % 5)],
        'brand', 'Brand' || (g % 200)
    ),
    now() - (random() * interval '365 days')
FROM generate_series(1, 100000) g;

-- orders: 5M rows, ~2GB
-- (~400 bytes/row with jsonb shipping)
\echo '>>> Inserting orders (5M rows, ~2GB)...'
INSERT INTO orders (user_id, status, total, currency, notes, shipping, created_at, updated_at)
SELECT
    1 + (g % 500000),
    (ARRAY['pending','confirmed','shipped','delivered','cancelled','refunded'])[1 + (g % 6)],
    (random() * 5000 + 10)::numeric(12,2),
    (ARRAY['USD','EUR','GBP','JPY','CAD'])[1 + (g % 5)],
    CASE WHEN g % 3 = 0 THEN 'Note for order ' || g || ': ' || repeat(substr(md5(g::text), 1, 10), 5) ELSE NULL END,
    jsonb_build_object(
        'street', g || ' Main St',
        'city', (ARRAY['New York','London','Tokyo','Berlin','Toronto','Sydney','Paris','Mumbai'])[1 + (g % 8)],
        'zip', lpad((g % 99999)::text, 5, '0'),
        'country', (ARRAY['US','UK','JP','DE','CA','AU','FR','IN'])[1 + (g % 8)]
    ),
    now() - (random() * interval '730 days'),
    now() - (random() * interval '30 days')
FROM generate_series(1, 5000000) g;

-- order_items: 10M rows, ~3GB
-- (~300 bytes/row with metadata jsonb)
\echo '>>> Inserting order_items (10M rows, ~3GB)...'
INSERT INTO order_items (order_id, product_id, quantity, unit_price, subtotal, metadata)
SELECT
    1 + (g % 5000000),
    1 + (g % 100000),
    1 + (g % 5),
    (random() * 500 + 5)::numeric(10,2),
    ((1 + (g % 5)) * (random() * 500 + 5))::numeric(12,2),
    jsonb_build_object(
        'variant', (ARRAY['default','large','small','xl','xxl'])[1 + (g % 5)],
        'gift_wrap', g % 10 = 0,
        'discount_pct', CASE WHEN g % 7 = 0 THEN (random() * 30)::int ELSE 0 END
    )
FROM generate_series(1, 10000000) g;

-- events: 8M rows, ~3GB
-- (~380 bytes/row)
\echo '>>> Inserting events (8M rows, ~3GB)...'
INSERT INTO events (user_id, event_type, payload, ip_address, user_agent, session_id, created_at)
SELECT
    1 + (g % 500000),
    (ARRAY['page_view','click','purchase','signup','login','logout','search','add_to_cart','remove_from_cart','checkout'])[1 + (g % 10)],
    jsonb_build_object(
        'page', '/page/' || (g % 5000),
        'duration_ms', (random() * 30000)::int,
        'referrer', CASE WHEN g % 3 = 0 THEN 'https://google.com/search?q=' || substr(md5(g::text), 1, 8) ELSE NULL END,
        'utm_source', CASE WHEN g % 5 = 0 THEN (ARRAY['google','facebook','twitter','email','direct'])[1 + (g % 5)] ELSE NULL END
    ),
    ('192.168.' || (g % 256) || '.' || ((g / 256) % 256))::inet,
    'Mozilla/5.0 (Agent ' || (g % 50) || ') Browser/' || (g % 10) || '.0',
    md5(((g / 100)::int)::text)::uuid,
    now() - (random() * interval '365 days')
FROM generate_series(1, 8000000) g;

-- audit_log: 5M rows, ~2GB
-- (~400 bytes/row)
\echo '>>> Inserting audit_log (5M rows, ~2GB)...'
INSERT INTO audit_log (table_name, record_id, action, old_data, new_data, performed_by, created_at)
SELECT
    (ARRAY['users','orders','products','order_items'])[1 + (g % 4)],
    1 + (g % 1000000),
    (ARRAY['INSERT','UPDATE','DELETE','UPDATE','UPDATE'])[1 + (g % 5)],
    CASE WHEN g % 5 != 0 THEN jsonb_build_object('status', 'old_' || (g % 10), 'val', g - 1) ELSE NULL END,
    jsonb_build_object('status', 'new_' || (g % 10), 'val', g, 'extra', substr(md5(g::text), 1, 16)),
    1 + (g % 500000),
    now() - (random() * interval '730 days')
FROM generate_series(1, 5000000) g;

-- =========================================================================
-- Indexes (beyond PKs and UNIQUEs created above)
-- =========================================================================
\echo '>>> Creating indexes...'

CREATE INDEX idx_users_created ON users (created_at);
CREATE INDEX idx_users_metadata_plan ON users USING gin (metadata);

CREATE INDEX idx_products_category ON products (category);
CREATE INDEX idx_products_price ON products (price);
CREATE INDEX idx_products_tags ON products USING gin (tags);

CREATE INDEX idx_orders_user_id ON orders (user_id);
CREATE INDEX idx_orders_status ON orders (status);
CREATE INDEX idx_orders_created ON orders (created_at);

CREATE INDEX idx_order_items_order ON order_items (order_id);
CREATE INDEX idx_order_items_product ON order_items (product_id);

CREATE INDEX idx_events_user_id ON events (user_id);
CREATE INDEX idx_events_type ON events (event_type);
CREATE INDEX idx_events_created ON events (created_at);
CREATE INDEX idx_events_session ON events (session_id);

CREATE INDEX idx_audit_table_record ON audit_log (table_name, record_id);
CREATE INDEX idx_audit_performed ON audit_log (performed_by);
CREATE INDEX idx_audit_created ON audit_log (created_at);

-- =========================================================================
-- Final size check
-- =========================================================================
\echo '>>> Done! Table sizes:'
SELECT
    relname AS table,
    pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size,
    pg_size_pretty(pg_relation_size(c.oid)) AS data_size,
    to_char(reltuples::bigint, 'FM999,999,999') AS est_rows
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'public' AND c.relkind = 'r'
ORDER BY pg_total_relation_size(c.oid) DESC;

SELECT pg_size_pretty(pg_database_size(current_database())) AS total_db_size;
