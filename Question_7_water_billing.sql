-- =====================================================
-- ICT371 Advanced Database
-- Question 7: Water Meter Readings and Billing
-- Student: Nicholas | Mulungushi University
-- Database: PostgreSQL
-- =====================================================

DROP TABLE IF EXISTS receivable_snapshot, bills, readings, customers CASCADE;

-- (a) Database and seed data
-- Non-negative meter values, month-start reading_month, amount_paid between 0 and charge
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INT NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE NOT NULL CHECK (EXTRACT(DAY FROM reading_month) = 1),
    previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(10,2) NOT NULL CHECK (current_reading >= 0),
    UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INT NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on      DATE NOT NULL,
    CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(14,2) NOT NULL
);

INSERT INTO customers (full_name) VALUES
    ('Agnes Mutinta'),
    ('Boniface Sikazwe'),
    ('Clara Moonga');

-- (b) Function
-- First 10 units cost K5 each, units above 10 cost K8 each.
-- Rejects NULL or negative units and returns a two-decimal charge.
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC AS $$
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Consumption must be zero or more';
    END IF;

    IF p_units <= 10 THEN
        RETURN ROUND(p_units * 5, 2);
    END IF;

    RETURN ROUND(10 * 5 + (p_units - 10) * 8, 2);
END;
$$ LANGUAGE plpgsql;

-- (d) Trigger
-- BEFORE INSERT OR UPDATE: rejects current_reading below previous_reading.
-- Raising an error stops the row being saved, even for direct SQL imports.
CREATE OR REPLACE FUNCTION trg_reading_check_fn()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) is below previous_reading (%)',
                        NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_reading_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_reading_check_fn();

-- (c) Procedure
-- Works out the units used, calls the function, inserts a bill with amount_paid 0.
-- Rejects an unknown reading or one that already has a bill.
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_prev  NUMERIC;
    v_curr  NUMERIC;
BEGIN
    SELECT previous_reading, current_reading INTO v_prev, v_curr
    FROM readings WHERE reading_id = p_reading_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading %', p_reading_id;
    END IF;

    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, fn_water_charge(v_curr - v_prev), 0, p_due_on);
END;
$$;

-- (a) continued: six readings covering 0 units, exactly 10 units and above 10
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, '2026-09-01', 100, 100),    -- 0 units,  K0
    (1, '2026-10-01', 100, 110),    -- 10 units, K50
    (2, '2026-09-01',  50,  65),    -- 15 units, K90
    (2, '2026-10-01',  65,  90),    -- 25 units, K170
    (3, '2026-09-01',   0,   8),    -- 8 units,  K40
    (3, '2026-10-01',   8,  18);    -- 10 units, K50

-- Bills: most are already overdue, the last one is not due yet
CALL pr_generate_bill(1, CURRENT_DATE - 20);
CALL pr_generate_bill(2, CURRENT_DATE - 5);
CALL pr_generate_bill(3, CURRENT_DATE - 20);
CALL pr_generate_bill(4, CURRENT_DATE - 5);
CALL pr_generate_bill(5, CURRENT_DATE - 20);
CALL pr_generate_bill(6, CURRENT_DATE + 10);

UPDATE bills SET amount_paid = 90 WHERE reading_id = 3;    -- fully paid
UPDATE bills SET amount_paid = 20 WHERE reading_id = 4;    -- partly paid

SELECT * FROM readings ORDER BY reading_id;
SELECT * FROM bills ORDER BY bill_id;

-- Tests for (b), (c) and (d)
SELECT fn_water_charge(0)  AS zero_units,       -- 0.00
       fn_water_charge(10) AS ten_units,        -- 50.00
       fn_water_charge(15) AS fifteen_units;    -- 90.00

DO $$ BEGIN PERFORM fn_water_charge(NULL);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (NULL): %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_water_charge(-3);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (negative): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_generate_bill(999, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown reading): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_generate_bill(1, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (already billed): %', SQLERRM; END $$;

-- Direct SQL with a lower current reading is stopped by the trigger
DO $$ BEGIN
    INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
    VALUES (1, '2026-11-01', 110, 100);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Trigger rejected insert: %', SQLERRM; END $$;
DO $$ BEGIN
    UPDATE readings SET current_reading = 5 WHERE reading_id = 2;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Trigger rejected update: %', SQLERRM; END $$;

SELECT count(*) FROM readings;    -- still 6

-- (e) View
-- Bills past their due date that are not fully paid, with the amount still owed
CREATE VIEW v_overdue_bills AS
SELECT c.full_name,
       b.due_on,
       b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r  ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

SELECT * FROM v_overdue_bills ORDER BY due_on;

-- (f) Index
-- Partial index on due_on for unpaid bills only. Paid bills are never searched
-- by the overdue report, so leaving them out keeps the index small.
CREATE INDEX idx_bills_unpaid_due ON bills (due_on) WHERE amount_paid < charge;

ANALYZE bills;
SET enable_seqscan = off;      -- table is tiny, so force the planner to show the index
EXPLAIN
SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM bills
WHERE amount_paid < charge
  AND due_on < CURRENT_DATE
ORDER BY due_on;
RESET enable_seqscan;

-- (g) Scheduled job
-- Stores today's total of unpaid balances; ON CONFLICT replaces today's row on rerun
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
    FROM bills
    WHERE amount_paid < charge
    ON CONFLICT (snapshot_date) DO UPDATE
        SET total_due = EXCLUDED.total_due;
END;
$$;

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();    -- rerun test
SELECT * FROM receivable_snapshot;    -- 290

-- Schedule: every day at 00:30 (needs pg_cron)
SELECT cron.schedule('refresh_receivables', '30 0 * * *',
                     $$CALL pr_refresh_receivables()$$);
