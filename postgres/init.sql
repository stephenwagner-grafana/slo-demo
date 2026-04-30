CREATE TABLE IF NOT EXISTS products (
  id    SERIAL PRIMARY KEY,
  name  TEXT NOT NULL,
  price NUMERIC(10, 2) NOT NULL
);

CREATE TABLE IF NOT EXISTS reports (
  id           SERIAL PRIMARY KEY,
  title        TEXT NOT NULL,
  generated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO products (name, price) VALUES
  ('Lumen Standard',  49.00),
  ('Lumen Pro',      149.00),
  ('Lumen Team',     499.00),
  ('Lumen Cloud',    999.00),
  ('Lumen Forge',   1499.00)
ON CONFLICT DO NOTHING;

INSERT INTO reports (title, generated_at) VALUES
  ('Weekly latency review',          now() - interval '6 hours'),
  ('Q2 cost allocation',             now() - interval '1 day'),
  ('Top failing endpoints',          now() - interval '2 days'),
  ('Browser compatibility roll-up',  now() - interval '3 days')
ON CONFLICT DO NOTHING;
