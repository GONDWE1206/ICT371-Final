-- Student: Lute Walusungu Gondwe (202407170) | Target: PostgreSQL 14+

DROP SCHEMA IF EXISTS q10_scholarship CASCADE;
CREATE SCHEMA q10_scholarship;
SET search_path = q10_scholarship, public;

CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id     SERIAL PRIMARY KEY,
    student_id         INTEGER       NOT NULL REFERENCES students(student_id),
    age_at_application INTEGER       NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on       DATE          NOT NULL,
    status             VARCHAR(10)   NOT NULL DEFAULT 'PENDING',
    CONSTRAINT ck_app_status CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INTEGER     NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(10) NOT NULL,
    new_status     VARCHAR(10) NOT NULL,
    changed_at     TIMESTAMP   NOT NULL DEFAULT NOW()
);

INSERT INTO students (student_number, full_name) VALUES
    ('202406001', 'Anita Chisenga'),
    ('202406002', 'Bernard Kalaba'),
    ('202406003', 'Cynthia Mapulanga');

INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
    (1, 20, 2500.00, 85.00, '2026-11-02', 'PENDING'),
    (1, 18, 3000.00, 70.00, '2026-11-03', 'PENDING'),
    (2, 25, 2999.99, 69.99, '2026-11-05', 'PENDING'),
    (2, 17, 1000.00, 90.00, '2026-11-07', 'PENDING'),
    (3, 26,  500.00, 80.00, '2026-11-10', 'PENDING'),
    (3, 22, 3000.01, 75.00, '2026-11-12', 'PENDING');

CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INTEGER, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark are all required';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive, got %', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income cannot be negative, got %', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100, got %', p_mark;
    END IF;

    RETURN p_age BETWEEN 18 AND 25
       AND p_income <= 3000
       AND p_mark >= 70;
END;
$$ LANGUAGE plpgsql IMMUTABLE;

SELECT fn_scholarship_eligible(18, 3000, 70)      AS all_boundaries,
       fn_scholarship_eligible(25, 2999.99, 69.99) AS mark_too_low,
       fn_scholarship_eligible(26, 500, 80)        AS too_old,
       fn_scholarship_eligible(22, 3000.01, 75)    AS income_too_high;

DO $$
BEGIN
    BEGIN PERFORM fn_scholarship_eligible(NULL, 1000, 80);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'NULL rejected: %', SQLERRM; END;
    BEGIN PERFORM fn_scholarship_eligible(20, -1, 80);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Negative income rejected: %', SQLERRM; END;
    BEGIN PERFORM fn_scholarship_eligible(0, 1000, 80);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Non-positive age rejected: %', SQLERRM; END;
    BEGIN PERFORM fn_scholarship_eligible(20, 1000, 101);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Mark out of range rejected: %', SQLERRM; END;
END $$;

CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
    v_status   VARCHAR(10);
    v_age      INTEGER;
    v_income   NUMERIC(12,2);
    v_mark     NUMERIC(5,2);
    v_eligible BOOLEAN;
BEGIN
    SELECT status, age_at_application, monthly_income, average_mark
    INTO v_status, v_age, v_income, v_mark
    FROM applications WHERE application_id = p_application_id FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Application % does not exist', p_application_id;
    END IF;
    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed (status %)', p_application_id, v_status;
    END IF;

    v_eligible := fn_scholarship_eligible(v_age, v_income, v_mark);

    UPDATE applications
    SET status = CASE WHEN v_eligible THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE application_id = p_application_id;
END;
$$;

CREATE OR REPLACE FUNCTION trg_fn_decision_audit()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (OLD.application_id, OLD.status, NEW.status, NOW());
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_fn_decision_audit();

CALL pr_assess_application(1);

DO $$
BEGIN
    BEGIN CALL pr_assess_application(999);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Unknown application: %', SQLERRM; END;
    BEGIN CALL pr_assess_application(1);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Already assessed: %', SQLERRM; END;
END $$;

UPDATE applications SET status = status WHERE application_id = 1;
SELECT * FROM decision_audit ORDER BY audit_id;

CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'
        ORDER BY application_id
    LOOP
        CALL pr_assess_application(rec.application_id);
    END LOOP;
END;
$$;

CALL pr_assess_pending();
CALL pr_assess_pending();

SELECT application_id, age_at_application, monthly_income, average_mark, status
FROM applications ORDER BY application_id;
SELECT COUNT(*) AS audit_rows FROM decision_audit;

CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

SELECT * FROM v_approved_applicants ORDER BY student_number, average_mark;

CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);
ANALYZE applications;

SET enable_seqscan = off;
EXPLAIN
SELECT application_id, student_id, submitted_on
FROM applications
WHERE status = 'REJECTED'
  AND submitted_on BETWEEN '2026-11-01' AND '2026-11-30';
RESET enable_seqscan;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q10_assess_pending',
    '0 8 * * 1',
    $cron$CALL q10_scholarship.pr_assess_pending()$cron$
);
