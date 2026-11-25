-- =====================================================
-- ICT371 Advanced Database
-- Question 10: Scholarship Application Assessment
-- Student: Nicholas | Mulungushi University
-- Database: PostgreSQL
-- =====================================================

DROP TABLE IF EXISTS decision_audit, applications, students CASCADE;

-- (a) Database and seed data
-- Non-negative income, positive age, marks 0 to 100, status PENDING/APPROVED/REJECTED
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id     SERIAL PRIMARY KEY,
    student_id         INT NOT NULL REFERENCES students(student_id),
    age_at_application INT NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on       DATE NOT NULL,
    status             VARCHAR(10) NOT NULL DEFAULT 'PENDING'
                       CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INT NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(10) NOT NULL,
    new_status     VARCHAR(10) NOT NULL,
    changed_at     TIMESTAMP NOT NULL DEFAULT now()
);

INSERT INTO students (student_number, full_name) VALUES
    ('2025001', 'Mercy Katongo'),
    ('2025002', 'Daniel Mumba'),
    ('2025003', 'Faith Sinkala');

-- Six PENDING applications across three students: qualifying, non-qualifying, boundary
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on) VALUES
    (1, 18, 3000.00, 70.00, CURRENT_DATE - 14),    -- 1: all lower boundaries, qualifies
    (1, 25, 2500.00, 85.00, CURRENT_DATE - 12),    -- 2: upper age boundary, qualifies
    (2, 17, 1000.00, 90.00, CURRENT_DATE - 10),    -- 3: too young, rejected
    (2, 22, 3000.01, 80.00, CURRENT_DATE -  8),    -- 4: income just over, rejected
    (3, 20, 1500.00, 69.99, CURRENT_DATE -  6),    -- 5: mark just under, rejected
    (3, 22, 2000.00, 95.00, CURRENT_DATE -  4);    -- 6: clear qualifier

-- (b) Function
-- True only when age is 18 to 25, income is at most K3000 and mark is at least 70.
-- Rejects NULLs, negative income, non-positive age and marks outside 0 to 100.
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark are all required';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive';
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income cannot be negative';
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100';
    END IF;

    RETURN p_age BETWEEN 18 AND 25
       AND p_income <= 3000
       AND p_mark >= 70;
END;
$$ LANGUAGE plpgsql;

-- (d) Trigger
-- AFTER UPDATE row trigger: records OLD and NEW status with a timestamp,
-- only when the status really changes
CREATE OR REPLACE FUNCTION trg_decision_audit_fn()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (OLD.application_id, OLD.status, NEW.status, now());
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_decision_audit_fn();

-- (c) Procedure
-- Needs an existing PENDING application, calls the function, sets APPROVED or REJECTED.
-- Raises a clear error for an unknown or already assessed application.
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql AS $$
DECLARE
    v_app      applications%ROWTYPE;
    v_eligible BOOLEAN;
BEGIN
    -- lock the row so two people cannot assess the same application at once
    SELECT * INTO v_app FROM applications
    WHERE application_id = p_application_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Application % does not exist', p_application_id;
    END IF;

    IF v_app.status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % was already assessed (status %)',
                        p_application_id, v_app.status;
    END IF;

    v_eligible := fn_scholarship_eligible(v_app.age_at_application,
                                          v_app.monthly_income,
                                          v_app.average_mark);

    UPDATE applications
    SET status = CASE WHEN v_eligible THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE application_id = p_application_id;
END;
$$;

-- Tests for (b)
SELECT fn_scholarship_eligible(18, 3000, 70)    AS lower_boundaries,    -- true
       fn_scholarship_eligible(25, 3000, 70)    AS age_25,              -- true
       fn_scholarship_eligible(26, 1000, 90)    AS age_26,              -- false
       fn_scholarship_eligible(17, 1000, 90)    AS age_17,              -- false
       fn_scholarship_eligible(20, 3000.01, 90) AS income_over,         -- false
       fn_scholarship_eligible(20, 1000, 69.99) AS mark_under;          -- false

DO $$ BEGIN PERFORM fn_scholarship_eligible(NULL, 1000, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (NULL): %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, -1, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (negative income): %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(0, 1000, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (age 0): %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, 1000, 101);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (mark 101): %', SQLERRM; END $$;

-- Tests for (c) and (d)
CALL pr_assess_application(1);    -- boundary applicant, becomes APPROVED

DO $$ BEGIN CALL pr_assess_application(1);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (already assessed): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_assess_application(999);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown): %', SQLERRM; END $$;

UPDATE applications SET status = 'APPROVED' WHERE application_id = 1;    -- same status, no audit row
SELECT * FROM decision_audit;    -- exactly 1 row: PENDING -> APPROVED

-- (e) View
-- Approved applicants only; household income is not shown
CREATE VIEW v_approved_applicants AS
SELECT s.student_number,
       s.full_name,
       a.average_mark,
       a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- (g) Scheduled job
-- Query FOR loop over PENDING applications only. Finished applications are never
-- picked up, so a rerun does nothing and creates no duplicate audit rows.
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'
        ORDER BY application_id
    LOOP
        CALL pr_assess_application(r.application_id);
    END LOOP;
END;
$$;

CALL pr_assess_pending();    -- assesses applications 2 to 6
CALL pr_assess_pending();    -- rerun test, nothing left to do

SELECT application_id, status FROM applications ORDER BY application_id;    -- 1, 2 and 6 APPROVED
SELECT * FROM decision_audit ORDER BY audit_id;                             -- exactly 6 rows
SELECT * FROM v_approved_applicants ORDER BY student_number;                -- 3 approved, no income

-- Schedule: every Monday at 08:00 (needs pg_cron)
SELECT cron.schedule('assess_pending', '0 8 * * 1',
                     $$CALL pr_assess_pending()$$);

-- (f) Index
-- status (equality) first, then submitted_on (date range)
CREATE INDEX idx_app_status_date ON applications (status, submitted_on);

ANALYZE applications;
SET enable_seqscan = off;      -- table is tiny, so force the planner to show the index
EXPLAIN
SELECT * FROM applications
WHERE status = 'APPROVED'
  AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;
