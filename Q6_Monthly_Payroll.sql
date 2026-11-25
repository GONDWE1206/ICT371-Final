-- Student: Lute Walusungu Gondwe (202407170) | Target: PostgreSQL 14+

DROP SCHEMA IF EXISTS q6_payroll CASCADE;
CREATE SCHEMA q6_payroll;
SET search_path = q6_payroll, public;

CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(100)  NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
    deduction    NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
    active       BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INTEGER       NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE          NOT NULL,
    gross_pay   NUMERIC(12,2) NOT NULL,
    net_pay     NUMERIC(12,2) NOT NULL,
    CONSTRAINT ck_pay_month_start CHECK (pay_month = date_trunc('month', pay_month)::date),
    CONSTRAINT uq_employee_month  UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INTEGER       NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMP     NOT NULL DEFAULT NOW()
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Chanda Mutale',   9000.00, 1500.00, 1200.00, TRUE),
    ('Bupe Lweendo',    7500.00, 1000.00,  900.00, TRUE),
    ('Mwila Kasonde',   6000.00,  500.00,  700.00, TRUE),
    ('Temwani Phiri',   5000.00,  400.00,  600.00, TRUE),
    ('Lillian Sinkala', 4000.00,  300.00,  500.00, FALSE);

CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC AS $$
DECLARE
    v_net NUMERIC(12,2);
BEGIN
    SELECT basic_salary + allowance - deduction INTO v_net
    FROM employees WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Employee % has a negative net pay: %', p_employee_id, v_net;
    END IF;
    RETURN v_net;
END;
$$ LANGUAGE plpgsql STABLE;

SELECT employee_id, fn_net_pay(employee_id) AS net_pay FROM employees ORDER BY employee_id;

CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE
    rec     RECORD;
    v_net   NUMERIC(12,2);
    v_gross NUMERIC(12,2);
BEGIN
    IF p_month IS NULL OR p_month <> date_trunc('month', p_month)::date THEN
        RAISE EXCEPTION 'Payroll month must be the first day of a month, got: %', p_month;
    END IF;

    FOR rec IN
        SELECT employee_id, basic_salary, allowance
        FROM employees
        WHERE active
        ORDER BY employee_id
    LOOP
        CONTINUE WHEN EXISTS (SELECT 1 FROM payroll
                              WHERE employee_id = rec.employee_id AND pay_month = p_month);

        v_net   := fn_net_pay(rec.employee_id);
        v_gross := rec.basic_salary + rec.allowance;

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (rec.employee_id, p_month, v_gross, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$;

CREATE OR REPLACE FUNCTION trg_fn_salary_audit()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
    VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary, NOW());
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_salary_audit();

CALL pr_process_payroll('2026-09-01');
CALL pr_process_payroll('2026-10-01');

UPDATE employees SET basic_salary = 9500.00 WHERE employee_id = 1;
UPDATE employees SET allowance   = 1600.00 WHERE employee_id = 1;
UPDATE employees SET basic_salary = basic_salary WHERE employee_id = 2;
UPDATE employees SET active = FALSE WHERE employee_id = 4;

SELECT * FROM salary_audit;

CALL pr_process_payroll('2026-11-01');
SELECT * FROM payroll ORDER BY pay_month, employee_id;

CALL pr_process_payroll('2026-11-01');
CALL pr_process_payroll('2026-10-01');
SELECT COUNT(*) AS payroll_rows FROM payroll;
SELECT gross_pay, net_pay FROM payroll WHERE employee_id = 1 AND pay_month = '2026-10-01';

DO $$
BEGIN
    BEGIN CALL pr_process_payroll('2026-12-15');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Not a month start: %', SQLERRM; END;

    UPDATE employees SET deduction = 99999 WHERE employee_id = 3;
    BEGIN CALL pr_process_payroll('2026-12-01');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Whole call failed: %', SQLERRM; END;
    UPDATE employees SET deduction = 700 WHERE employee_id = 3;
    BEGIN PERFORM fn_net_pay(999);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Unknown employee: %', SQLERRM; END;
END $$;
SELECT COUNT(*) AS dec_rows FROM payroll WHERE pay_month = '2026-12-01';

CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;

CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);
ANALYZE payroll;

SET enable_seqscan = off;
EXPLAIN
SELECT employee_id, gross_pay, net_pay
FROM payroll
WHERE pay_month = '2026-10-01';
RESET enable_seqscan;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q6_process_payroll',
    '0 2 1 * *',
    $cron$CALL q6_payroll.pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$cron$
);

SELECT jobid, jobname, schedule, command, active
FROM cron.job
WHERE jobname = 'q6_process_payroll';

SELECT d.jobid, d.runid, d.status, d.return_message, d.start_time, d.end_time
FROM cron.job_run_details d
JOIN cron.job j ON j.jobid = d.jobid
WHERE j.jobname = 'q6_process_payroll'
ORDER BY d.start_time DESC;
