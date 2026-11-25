-- Student: Lute Walusungu Gondwe (202407170) | Target: PostgreSQL 14+

DROP SCHEMA IF EXISTS q3_library CASCADE;
CREATE SCHEMA q3_library;
SET search_path = q3_library, public;

CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INTEGER      NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on   DATE         NOT NULL,
    due_on        DATE         NOT NULL,
    returned_on   DATE         NULL,
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT ck_due_after_borrow CHECK (due_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id         SERIAL PRIMARY KEY,
    loan_id          INTEGER   NOT NULL REFERENCES loans(loan_id),
    old_returned_on  DATE      NULL,
    new_returned_on  DATE      NULL,
    changed_at       TIMESTAMP NOT NULL DEFAULT NOW()
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER       NOT NULL DEFAULT 0,
    total_fine    NUMERIC(12,2) NOT NULL DEFAULT 0
);

INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Operating System Concepts'),
    ('Computer Networks');

INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
    (1, 'Alice Tembo',    '2026-10-20', '2026-11-03'),
    (2, 'Brian Zulu',     '2026-11-20', '2026-12-04'),
    (1, 'Chipo Daka',     '2026-10-01', '2026-10-15'),
    (3, 'Dalitso Moyo',   '2026-10-05', '2026-10-19'),
    (2, 'Esther Lungu',   '2026-10-10', '2026-10-24'),
    (3, 'Farai Chanda',   '2026-11-01', '2026-11-10');

CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC AS $$
DECLARE
    v_due      DATE;
    v_returned DATE;
    v_end      DATE;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of date is required';
    END IF;

    SELECT due_on, returned_on INTO v_due, v_returned FROM loans WHERE loan_id = p_loan_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    v_end := LEAST(p_as_of, COALESCE(v_returned, p_as_of));

    RETURN 2 * GREATEST(v_end - v_due, 0);
END;
$$ LANGUAGE plpgsql STABLE;

CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_borrowed DATE;
    v_returned DATE;
    v_fine     NUMERIC(10,2);
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date is required';
    END IF;

    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_returned;
    END IF;
    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before the borrow date %', p_returned_on, v_borrowed;
    END IF;

    v_fine := fn_loan_fine(p_loan_id, p_returned_on);

    UPDATE loans
    SET returned_on = p_returned_on,
        fine_amount = v_fine
    WHERE loan_id = p_loan_id;
END;
$$;

CREATE OR REPLACE FUNCTION trg_fn_loan_audit()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
    VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on, NOW());
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_fn_loan_audit();

CALL pr_return_loan(3, '2026-10-14');
CALL pr_return_loan(4, '2026-10-19');
CALL pr_return_loan(5, '2026-10-29');

SELECT * FROM loans ORDER BY loan_id;
SELECT * FROM loan_audit ORDER BY audit_id;

SELECT fn_loan_fine(1, '2026-11-25') AS open_overdue_fine;
SELECT fn_loan_fine(5, '2026-12-31') AS returned_loan_stays_at_10;
SELECT fn_loan_fine(2, '2026-11-25') AS not_yet_due;

DO $$
BEGIN
    BEGIN PERFORM fn_loan_fine(999, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Unknown loan rejected: %', SQLERRM; END;
    BEGIN CALL pr_return_loan(999, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Unknown loan rejected: %', SQLERRM; END;
    BEGIN CALL pr_return_loan(5, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Already returned rejected: %', SQLERRM; END;
    BEGIN CALL pr_return_loan(1, '2026-10-01');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Return before borrow rejected: %', SQLERRM; END;
END $$;

UPDATE loans SET returned_on = returned_on WHERE loan_id = 3;
SELECT COUNT(*) AS audit_rows FROM loan_audit;

CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id,
       b.title,
       l.borrower_name,
       l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans ORDER BY loan_id;

CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;
ANALYZE loans;

SET enable_seqscan = off;
EXPLAIN
SELECT loan_id, borrower_name, due_on
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;
RESET enable_seqscan;

CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_count INTEGER;
    v_fine  NUMERIC(12,2);
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of date is required';
    END IF;

    SELECT COUNT(*), COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    INTO v_count, v_fine
    FROM loans
    WHERE borrowed_on <= p_as_of
      AND (returned_on IS NULL OR returned_on > p_as_of)
      AND due_on < p_as_of;

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    VALUES (p_as_of, v_count, v_fine)
    ON CONFLICT (snapshot_date)
    DO UPDATE SET overdue_count = EXCLUDED.overdue_count, total_fine = EXCLUDED.total_fine;
END;
$$;

CALL pr_refresh_overdue('2026-11-25');
CALL pr_refresh_overdue('2026-11-25');
SELECT * FROM overdue_summary;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q3_refresh_overdue',
    '10 0 * * *',
    $cron$CALL q3_library.pr_refresh_overdue(CURRENT_DATE)$cron$
);
