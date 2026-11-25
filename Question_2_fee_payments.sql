-- =====================================================
-- ICT371 Advanced Database
-- Question 2: University Fee Payments
-- Student: Nicholas | Mulungushi University
-- Database: PostgreSQL
-- =====================================================

DROP TABLE IF EXISTS daily_collections, payment_audit, payments, students CASCADE;

-- (a) Database and seed data
-- Four tables with keys, positive amounts and no negative fees
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL,
    fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INT NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on    DATE NOT NULL
);

CREATE TABLE payment_audit (
    audit_id   SERIAL PRIMARY KEY,
    payment_id INT NOT NULL REFERENCES payments(payment_id),
    student_id INT NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL,
    logged_at  TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INT NOT NULL,
    total_amount    NUMERIC(12,2) NOT NULL
);

-- Three students with different balances (payments are loaded later)
INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('2023001', 'Chileshe Banda', 5000),
    ('2023002', 'Mutale Phiri',   3000),
    ('2023003', 'Thandiwe Zulu',  4000);

-- (b) Function
-- fee_due minus total payments; full fee if no payments; rejects unknown student
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS NUMERIC AS $$
DECLARE
    v_fee  NUMERIC;
    v_paid NUMERIC;
BEGIN
    SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student %', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM payments WHERE student_id = p_student_id;

    RETURN v_fee - v_paid;
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure
-- Rejects NULL, zero, negative and too-large payments, then inserts.
-- It does not touch fee_due and does not write the audit row (the trigger does).
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INT, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_balance NUMERIC;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Amount must be greater than zero';
    END IF;

    -- lock the student row so two payments cannot overpay at the same time
    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student %', p_student_id;
    END IF;

    v_balance := fn_fee_balance(p_student_id);
    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment % is above the outstanding balance %', p_amount, v_balance;
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;

-- (d) Trigger
-- AFTER INSERT row trigger: writes payment ID, student ID, amount and time to the audit table
CREATE OR REPLACE FUNCTION trg_payment_audit_fn()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_payment_audit_fn();

-- (a) continued: seven payments loaded through the procedure
-- Student 1 owes 2000, student 2 is fully settled, student 3 has no payments
CALL pr_receive_payment(1, 1000, CURRENT_DATE - 3);
CALL pr_receive_payment(1, 1500, CURRENT_DATE - 2);
CALL pr_receive_payment(1,  500, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000, CURRENT_DATE - 3);
CALL pr_receive_payment(2, 1000, CURRENT_DATE - 1);
CALL pr_receive_payment(2,  500, CURRENT_DATE - 1);
CALL pr_receive_payment(2,  500, CURRENT_DATE - 1);

SELECT * FROM payments;
SELECT * FROM payment_audit;    -- 7 rows, written by the trigger

-- Tests for (b) and (c)
SELECT fn_fee_balance(1) AS student1,    -- 2000
       fn_fee_balance(2) AS student2,    -- 0
       fn_fee_balance(3) AS student3;    -- 4000 (full fee)

DO $$ BEGIN PERFORM fn_fee_balance(999);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown student): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(1, NULL, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (NULL): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(1, 0, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (zero): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(1, -50, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (negative): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(1, 2500, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (above balance): %', SQLERRM; END $$;

SELECT student_id, fee_due FROM students;    -- fee_due unchanged

-- (e) View
-- Only students who still owe fees; fully settled students are left out
CREATE VIEW v_fee_balances AS
SELECT s.student_number,
       s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;

SELECT * FROM v_fee_balances;    -- students 1 and 3 only

-- (f) Index
-- Composite index: student_id (equality) first, then paid_on (date range)
CREATE INDEX idx_payments_student_date ON payments (student_id, paid_on);

ANALYZE payments;
SET enable_seqscan = off;      -- table is tiny, so force the planner to show the index
EXPLAIN
SELECT * FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job
-- ON CONFLICT replaces the day's row, so reruns never duplicate it
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
    FROM payments
    WHERE paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
        SET payment_count = EXCLUDED.payment_count,
            total_amount  = EXCLUDED.total_amount;
END;
$$;

CALL pr_refresh_collections(CURRENT_DATE - 1);
CALL pr_refresh_collections(CURRENT_DATE - 1);    -- rerun test
SELECT * FROM daily_collections;                  -- 4 payments, 2500.00

-- Schedule: every day at 01:00 for the previous day (needs pg_cron)
SELECT cron.schedule('refresh_collections', '0 1 * * *',
                     $$CALL pr_refresh_collections(CURRENT_DATE - 1)$$);
