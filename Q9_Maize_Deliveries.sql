-- Student: Lute Walusungu Gondwe (202407170) | Target: PostgreSQL 14+

DROP SCHEMA IF EXISTS q9_maize CASCADE;
CREATE SCHEMA q9_maize;
SET search_path = q9_maize, public;

CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INTEGER       NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1)       NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg    NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
    unit_rate    NUMERIC(10,2) NOT NULL,
    total_value  NUMERIC(12,2) NOT NULL,
    delivered_on DATE          NOT NULL,
    is_paid      BOOLEAN       NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(12,2) NOT NULL DEFAULT 0,
    total_value   NUMERIC(14,2) NOT NULL DEFAULT 0
);

INSERT INTO farmers (farmer_number, full_name) VALUES
    ('F001', 'Moses Tembo'),
    ('F002', 'Florence Banda'),
    ('F003', 'Isaac Mwale');

CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade TEXT)
RETURNS NUMERIC AS $$
DECLARE
    v_rate NUMERIC(10,2);
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade is required';
    END IF;

    v_rate := CASE p_grade WHEN 'A' THEN 5.00 WHEN 'B' THEN 4.00 WHEN 'C' THEN 3.00 END;
    IF v_rate IS NULL THEN
        RAISE EXCEPTION 'Unsupported grade: % (use A, B or C)', p_grade;
    END IF;
    RETURN v_rate;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

SELECT fn_maize_rate('A') AS a, fn_maize_rate('B') AS b, fn_maize_rate('C') AS c;

DO $$
BEGIN
    BEGIN PERFORM fn_maize_rate(NULL);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'NULL rejected: %', SQLERRM; END;
    BEGIN PERFORM fn_maize_rate('D');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Unsupported grade rejected: %', SQLERRM; END;
END $$;

CREATE OR REPLACE FUNCTION trg_fn_delivery_pricing()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive, got %', NEW.weight_kg;
    END IF;

    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_delivery_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_fn_delivery_pricing();

CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INTEGER, p_grade TEXT, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Unknown farmer_id: %', p_farmer_id;
    END IF;
    IF p_grade IS NULL OR p_grade NOT IN ('A', 'B', 'C') THEN
        RAISE EXCEPTION 'Invalid grade: %', p_grade;
    END IF;
    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Invalid weight: % (must be positive)', p_weight;
    END IF;
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date is required';
    END IF;

    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END;
$$;

INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid) VALUES
    (1, 'A', 100.00, '2026-11-20', TRUE),
    (1, 'B', 250.50, '2026-11-21', FALSE),
    (2, 'C', 400.00, '2026-11-21', TRUE),
    (2, 'A',  80.25, '2026-11-22', FALSE),
    (3, 'B', 150.00, '2026-11-22', TRUE),
    (3, 'C', 300.00, '2026-11-23', TRUE);

INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on)
VALUES (3, 'C', 10.00, 99.00, 9999.00, '2026-11-24');
SELECT grade, weight_kg, unit_rate, total_value FROM deliveries WHERE delivery_id = 7;
DELETE FROM deliveries WHERE delivery_id = 7;

SELECT * FROM deliveries ORDER BY delivery_id;

CALL pr_receive_delivery(2, 'B', 120.00, '2026-11-24');
DO $$
BEGIN
    BEGIN CALL pr_receive_delivery(99, 'A', 10, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Unknown farmer: %', SQLERRM; END;
    BEGIN CALL pr_receive_delivery(1, 'D', 10, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Bad grade: %', SQLERRM; END;
    BEGIN CALL pr_receive_delivery(1, 'A', 0, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Zero weight: %', SQLERRM; END;
    BEGIN INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on) VALUES (1, 'A', -5, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Direct negative weight: %', SQLERRM; END;
    UPDATE deliveries SET grade = 'A' WHERE delivery_id = 3;
END $$;
SELECT delivery_id, grade, weight_kg, unit_rate, total_value FROM deliveries WHERE delivery_id = 3;
UPDATE deliveries SET grade = 'C' WHERE delivery_id = 3;

CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,
       f.full_name,
       COALESCE(SUM(d.total_value) FILTER (WHERE NOT d.is_paid), 0) AS amount_due
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;

CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);
ANALYZE deliveries;

SET enable_seqscan = off;
EXPLAIN
SELECT delivery_id, grade, weight_kg, total_value
FROM deliveries
WHERE farmer_id = 2
  AND delivered_on BETWEEN '2026-11-20' AND '2026-11-24';
RESET enable_seqscan;

CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_weight NUMERIC(12,2);
    v_value  NUMERIC(14,2);
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Day is required';
    END IF;

    SELECT COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
    INTO v_weight, v_value
    FROM deliveries WHERE delivered_on = p_day;

    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    VALUES (p_day, v_weight, v_value)
    ON CONFLICT (purchase_date)
    DO UPDATE SET total_weight = EXCLUDED.total_weight, total_value = EXCLUDED.total_value;
END;
$$;

CALL pr_refresh_purchases('2026-11-21');
CALL pr_refresh_purchases('2026-11-21');
SELECT * FROM daily_purchases;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q9_refresh_purchases',
    '30 1 * * *',
    $cron$CALL q9_maize.pr_refresh_purchases(CURRENT_DATE - 1)$cron$
);
