-- Student: Lute Walusungu Gondwe (202407170) | Target: PostgreSQL 14+

DROP SCHEMA IF EXISTS q2_fees CASCADE;
CREATE SCHEMA q2_fees;
SET search_path = q2_fees, public;

CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)   NOT NULL UNIQUE,
    full_name      VARCHAR(100)  NOT NULL,
    fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INTEGER       NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on    DATE          NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE payment_audit (
    audit_id   SERIAL PRIMARY KEY,
    payment_id INTEGER       NOT NULL REFERENCES payments(payment_id),
    student_id INTEGER       NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL,
    logged_at  TIMESTAMP     NOT NULL DEFAULT NOW()
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INTEGER       NOT NULL DEFAULT 0,
    total_amount    NUMERIC(12,2) NOT NULL DEFAULT 0
);

INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('202401001', 'Mary Phiri',    5000.00),
    ('202401002', 'John Banda',    3000.00),
    ('202401003', 'Grace Mwansa',  4000.00);

CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC AS $$
DECLARE
    v_fee  NUMERIC(12,2);
    v_paid NUMERIC(12,2);
BEGIN
    SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0) INTO v_paid FROM payments WHERE student_id = p_student_id;
    RETURN v_fee - v_paid;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INTEGER, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_balance NUMERIC(12,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid payment amount: % (must be greater than zero)', p_amount;
    END IF;
    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Payment date is required';
    END IF;

    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    v_balance := fn_fee_balance(p_student_id);
    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment % exceeds outstanding balance % for student %',
            p_amount, v_balance, p_student_id;
    END IF;

    INSERT INTO payments (student_id, amount, paid_on) VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;

CREATE OR REPLACE FUNCTION trg_fn_payment_audit()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, NOW());
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_payment_audit();

CALL pr_receive_payment(1, 1000.00, '2026-11-18');
CALL pr_receive_payment(1, 1500.00, '2026-11-19');
CALL pr_receive_payment(1,  500.00, '2026-11-20');
CALL pr_receive_payment(2, 1000.00, '2026-11-18');
CALL pr_receive_payment(2, 1000.00, '2026-11-19');
CALL pr_receive_payment(2, 1000.00, '2026-11-20');

SELECT * FROM payments ORDER BY payment_id;
SELECT * FROM payment_audit ORDER BY audit_id;

SELECT student_id, fn_fee_balance(student_id) AS balance FROM students ORDER BY student_id;

DO $$
BEGIN
    BEGIN CALL pr_receive_payment(1, NULL, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'NULL rejected: %', SQLERRM; END;
    BEGIN CALL pr_receive_payment(1, 0, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Zero rejected: %', SQLERRM; END;
    BEGIN CALL pr_receive_payment(1, -50, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Negative rejected: %', SQLERRM; END;
    BEGIN CALL pr_receive_payment(1, 2000.01, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Overpayment rejected: %', SQLERRM; END;
    BEGIN PERFORM fn_fee_balance(999);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Unknown student rejected: %', SQLERRM; END;
END $$;

CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number,
       s.full_name,
       s.fee_due - COALESCE(p.total_paid, 0) AS outstanding_balance
FROM students s
LEFT JOIN (SELECT student_id, SUM(amount) AS total_paid
           FROM payments GROUP BY student_id) p ON p.student_id = s.student_id
WHERE s.fee_due - COALESCE(p.total_paid, 0) > 0;

SELECT * FROM v_fee_balances ORDER BY student_number;

CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);
ANALYZE payments;

SET enable_seqscan = off;
EXPLAIN
SELECT payment_id, amount, paid_on
FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN '2026-11-18' AND '2026-11-20';
RESET enable_seqscan;

CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_count  INTEGER;
    v_amount NUMERIC(12,2);
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Day is required';
    END IF;

    SELECT COUNT(*), COALESCE(SUM(amount), 0) INTO v_count, v_amount
    FROM payments WHERE paid_on = p_day;

    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    VALUES (p_day, v_count, v_amount)
    ON CONFLICT (collection_date)
    DO UPDATE SET payment_count = EXCLUDED.payment_count, total_amount = EXCLUDED.total_amount;
END;
$$;

CALL pr_refresh_collections('2026-11-19');
CALL pr_refresh_collections('2026-11-19');
SELECT * FROM daily_collections;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q2_refresh_collections',
    '0 1 * * *',
    $cron$CALL q2_fees.pr_refresh_collections(CURRENT_DATE - 1)$cron$
);
