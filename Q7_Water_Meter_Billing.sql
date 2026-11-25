-- Student: Lute Walusungu Gondwe (202407170) | Target: PostgreSQL 14+

DROP SCHEMA IF EXISTS q7_water CASCADE;
CREATE SCHEMA q7_water;
SET search_path = q7_water, public;

CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INTEGER       NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE          NOT NULL,
    previous_reading NUMERIC(12,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(12,2) NOT NULL CHECK (current_reading >= 0),
    CONSTRAINT ck_reading_month_start CHECK (reading_month = date_trunc('month', reading_month)::date),
    CONSTRAINT uq_customer_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INTEGER       NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on      DATE          NOT NULL,
    CONSTRAINT ck_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(14,2) NOT NULL DEFAULT 0
);

INSERT INTO customers (full_name) VALUES ('Alick Nyirenda'), ('Beatrice Hamoonga'), ('Charles Sikazwe');

CREATE OR REPLACE FUNCTION trg_fn_reading_check()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'Current reading % is below previous reading %',
            NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_reading_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_fn_reading_check();

INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, '2026-09-01', 100.00, 100.00),
    (1, '2026-10-01', 100.00, 110.00),
    (2, '2026-09-01',  50.00,  65.00),
    (2, '2026-10-01',  65.00,  90.00),
    (3, '2026-09-01',  20.00,  27.00),
    (3, '2026-10-01',  27.00,  37.50);

DO $$
BEGIN
    BEGIN INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
          VALUES (3, '2026-11-01', 37.50, 30.00);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected on insert: %', SQLERRM; END;
    BEGIN UPDATE readings SET current_reading = 1 WHERE reading_id = 6;
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected on update: %', SQLERRM; END;
END $$;
SELECT COUNT(*) AS reading_rows FROM readings;

CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2) AS $$
BEGIN
    IF p_units IS NULL THEN
        RAISE EXCEPTION 'Consumption is required';
    END IF;
    IF p_units < 0 THEN
        RAISE EXCEPTION 'Consumption cannot be negative: %', p_units;
    END IF;

    IF p_units <= 10 THEN
        RETURN ROUND(p_units * 5, 2);
    END IF;
    RETURN ROUND(10 * 5 + (p_units - 10) * 8, 2);
END;
$$ LANGUAGE plpgsql IMMUTABLE;

SELECT fn_water_charge(0)    AS zero_units,
       fn_water_charge(10)   AS ten_units,
       fn_water_charge(15)   AS fifteen_units,
       fn_water_charge(10.5) AS ten_and_half;

DO $$
BEGIN
    BEGIN PERFORM fn_water_charge(NULL);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'NULL rejected: %', SQLERRM; END;
    BEGIN PERFORM fn_water_charge(-1);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Negative rejected: %', SQLERRM; END;
END $$;

CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INTEGER, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_prev  NUMERIC(12,2);
    v_curr  NUMERIC(12,2);
    v_units NUMERIC(12,2);
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date is required';
    END IF;

    SELECT previous_reading, current_reading INTO v_prev, v_curr
    FROM readings WHERE reading_id = p_reading_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %', p_reading_id;
    END IF;

    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    v_units := v_curr - v_prev;
    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, fn_water_charge(v_units), 0, p_due_on);
END;
$$;

CALL pr_generate_bill(1, '2026-10-15');
CALL pr_generate_bill(2, '2026-11-15');
CALL pr_generate_bill(3, '2026-10-15');
CALL pr_generate_bill(4, '2026-12-15');
CALL pr_generate_bill(5, '2026-10-15');
CALL pr_generate_bill(6, '2026-11-15');

DO $$
BEGIN
    BEGIN CALL pr_generate_bill(999, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Unknown reading: %', SQLERRM; END;
    BEGIN CALL pr_generate_bill(1, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Duplicate bill: %', SQLERRM; END;
END $$;

UPDATE bills SET amount_paid = charge WHERE reading_id = 5;
UPDATE bills SET amount_paid = 40.00  WHERE reading_id = 3;

SELECT b.bill_id, r.reading_id, r.current_reading - r.previous_reading AS units, b.charge, b.amount_paid, b.due_on
FROM bills b JOIN readings r USING (reading_id) ORDER BY b.bill_id;

CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name AS customer_name,
       b.due_on,
       b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r  ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

SELECT * FROM v_overdue_bills ORDER BY due_on, customer_name;

CREATE INDEX idx_bills_unpaid_due ON bills (due_on) WHERE amount_paid < charge;
ANALYZE bills;

SET enable_seqscan = off;
EXPLAIN
SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM bills
WHERE amount_paid < charge
  AND due_on < CURRENT_DATE;
RESET enable_seqscan;

CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
DECLARE
    v_total NUMERIC(14,2);
BEGIN
    SELECT COALESCE(SUM(charge - amount_paid), 0) INTO v_total
    FROM bills WHERE amount_paid < charge;

    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    VALUES (CURRENT_DATE, v_total)
    ON CONFLICT (snapshot_date) DO UPDATE SET total_due = EXCLUDED.total_due;
END;
$$;

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();
SELECT * FROM receivable_snapshot;
SELECT SUM(charge - amount_paid) AS expected_total FROM bills;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q7_refresh_receivables',
    '30 0 * * *',
    $cron$CALL q7_water.pr_refresh_receivables()$cron$
);
