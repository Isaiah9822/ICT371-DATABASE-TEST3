-- =====================================================
-- ICT371 Advanced Database
-- Question 6: Monthly Payroll Processing
-- Student: Nicholas | Mulungushi University
-- Database: PostgreSQL
-- =====================================================

DROP TABLE IF EXISTS salary_audit, payroll, employees CASCADE;

-- (a) Database and seed data
-- Non-negative money columns, boolean active, pay_month must be the 1st of a month
CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(100) NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
    deduction    NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
    active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INT NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE NOT NULL CHECK (EXTRACT(DAY FROM pay_month) = 1),
    gross_pay   NUMERIC(12,2) NOT NULL,
    net_pay     NUMERIC(12,2) NOT NULL,
    UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INT NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction) VALUES
    ('Joyce Mulenga',   8000, 1500, 1200),
    ('Patrick Chama',   6500, 1000,  900),
    ('Lucy Mbewe',      7200, 1200, 1000),
    ('Samuel Hamoonga', 5000,  800,  700);

-- (b) Function
-- Net pay = basic + allowance - deduction; rejects unknown employee or negative result
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC AS $$
DECLARE
    v_net NUMERIC;
BEGIN
    SELECT basic_salary + allowance - deduction INTO v_net
    FROM employees WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee %', p_employee_id;
    END IF;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;

    RETURN v_net;
END;
$$ LANGUAGE plpgsql;

-- (d) Trigger
-- AFTER UPDATE: logs OLD and NEW basic_salary, only when it really changes
CREATE OR REPLACE FUNCTION trg_salary_audit_fn()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary)
    VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_salary_audit_fn();

-- (c) Procedure
-- Query FOR loop over active employees. fn_net_pay runs for every one of them,
-- so a single bad calculation fails the whole call and nothing is saved.
-- ON CONFLICT DO NOTHING leaves existing employee/month rows unchanged.
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE
    r     RECORD;
    v_net NUMERIC;
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'p_month must be the first day of a month';
    END IF;

    FOR r IN
        SELECT employee_id, basic_salary + allowance AS gross
        FROM employees
        WHERE active
        ORDER BY employee_id
    LOOP
        v_net := fn_net_pay(r.employee_id);

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (r.employee_id, p_month, r.gross, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$;

-- (a) continued: two payroll months, then one employee leaves and one gets a raise
CALL pr_process_payroll('2026-09-01');
CALL pr_process_payroll('2026-10-01');

UPDATE employees SET active = FALSE WHERE employee_id = 4;
UPDATE employees SET basic_salary = 8500 WHERE employee_id = 1;

SELECT * FROM payroll ORDER BY pay_month, employee_id;    -- 8 rows
SELECT * FROM salary_audit;                                -- 1 row: 8000 -> 8500

-- Tests for (b), (c) and (d)
UPDATE employees SET basic_salary = 8500 WHERE employee_id = 1;    -- same value
UPDATE employees SET allowance = 1600 WHERE employee_id = 2;      -- different column
SELECT count(*) FROM salary_audit;                                 -- still 1

SELECT fn_net_pay(2);                                              -- 6500 + 1600 - 900 = 7200

DO $$ BEGIN PERFORM fn_net_pay(999);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown employee): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_process_payroll('2026-11-15');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (not a month start): %', SQLERRM; END $$;

CALL pr_process_payroll('2026-10-01');                             -- rerun: nothing changes
SELECT count(*) FROM payroll WHERE pay_month = '2026-10-01';      -- still 4

-- A huge deduction makes one employee invalid, so the whole call fails
-- (the DO block also undoes the UPDATE, so nothing is left behind)
DO $$ BEGIN
    UPDATE employees SET deduction = 99999 WHERE employee_id = 3;
    CALL pr_process_payroll('2026-12-01');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Whole call failed: %', SQLERRM; END $$;
SELECT count(*) FROM payroll WHERE pay_month = '2026-12-01';      -- 0

-- (e) View
-- No filter on active, so payroll history of employees who left is kept
CREATE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;    -- Samuel is still listed

-- (f) Index
-- The unique index starts with employee_id, so it cannot serve a search by month alone.
-- This index starts with pay_month and does not duplicate it.
CREATE INDEX idx_payroll_month ON payroll (pay_month);

ANALYZE payroll;
SET enable_seqscan = off;      -- table is tiny, so force the planner to show the index
EXPLAIN
SELECT * FROM payroll
WHERE pay_month = '2026-10-01';
RESET enable_seqscan;

-- (g) Scheduled job
-- 02:00 on the 1st of every month, processing the previous month (needs pg_cron)
SELECT cron.schedule(
    'monthly_payroll',
    '0 2 1 * *',
    $$CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$
);

-- Inspect the job
SELECT jobid, jobname, schedule, command, active
FROM cron.job
WHERE jobname = 'monthly_payroll';

-- Inspect the run history
SELECT d.runid, d.status, d.return_message, d.start_time, d.end_time
FROM cron.job_run_details d
JOIN cron.job j ON j.jobid = d.jobid
WHERE j.jobname = 'monthly_payroll'
ORDER BY d.start_time DESC;
