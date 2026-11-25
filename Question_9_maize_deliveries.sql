-- =====================================================
-- ICT371 Advanced Database
-- Question 9: Farmer Cooperative Maize Deliveries
-- Student: Nicholas | Mulungushi University
-- Database: PostgreSQL
-- =====================================================

DROP TABLE IF EXISTS daily_purchases, deliveries, farmers CASCADE;

-- (a) Database and seed data
-- Numeric weight and money columns; unit_rate and total_value are filled by the trigger
CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20) NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INT NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1) NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg    NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
    unit_rate    NUMERIC(8,2) NOT NULL,
    total_value  NUMERIC(12,2) NOT NULL,
    delivered_on DATE NOT NULL,
    is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(12,2) NOT NULL,
    total_value   NUMERIC(14,2) NOT NULL
);

INSERT INTO farmers (farmer_number, full_name) VALUES
    ('F001', 'Moses Banda'),
    ('F002', 'Alice Phiri'),
    ('F003', 'Isaac Tembo');

-- (b) Function
-- Grade A = K5, B = K4, C = K3 per kg; rejects NULL or unsupported grade
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade CHAR)
RETURNS NUMERIC AS $$
DECLARE
    v_rate NUMERIC;
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade is required';
    END IF;

    v_rate := CASE p_grade WHEN 'A' THEN 5 WHEN 'B' THEN 4 WHEN 'C' THEN 3 END;

    IF v_rate IS NULL THEN
        RAISE EXCEPTION 'Unsupported grade %. Use A, B or C', p_grade;
    END IF;

    RETURN v_rate;
END;
$$ LANGUAGE plpgsql;

-- (d) Trigger
-- BEFORE INSERT OR UPDATE: rejects non-positive weight, then sets unit_rate and
-- total_value itself, so direct SQL always follows the same pricing rule.
-- Installed before any deliveries are loaded.
CREATE OR REPLACE FUNCTION trg_delivery_price_fn()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive';
    END IF;

    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_delivery_price
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_delivery_price_fn();

-- (c) Procedure
-- Rejects unknown farmers and bad inputs, inserts the basic fields with is_paid false.
-- The trigger supplies unit_rate and total_value.
CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INT, p_grade CHAR, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Unknown farmer %', p_farmer_id;
    END IF;
    IF p_grade IS NULL OR p_grade NOT IN ('A', 'B', 'C') THEN
        RAISE EXCEPTION 'Invalid grade %. Use A, B or C', p_grade;
    END IF;
    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive';
    END IF;
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date is required';
    END IF;

    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END;
$$;

-- (a) continued: six deliveries covering all grades, loaded after the trigger exists
CALL pr_receive_delivery(1, 'A', 100, CURRENT_DATE - 2);    -- K500
CALL pr_receive_delivery(1, 'B',  80, CURRENT_DATE - 2);    -- K320
CALL pr_receive_delivery(2, 'C', 150, CURRENT_DATE - 1);    -- K450
CALL pr_receive_delivery(2, 'A',  60, CURRENT_DATE - 1);    -- K300
CALL pr_receive_delivery(3, 'B', 200, CURRENT_DATE - 1);    -- K800
CALL pr_receive_delivery(3, 'C',  50, CURRENT_DATE - 1);    -- K150

-- Mark some as paid so both payment states exist (farmer 3 is fully paid)
UPDATE deliveries SET is_paid = TRUE WHERE delivery_id IN (2, 5, 6);

SELECT * FROM deliveries ORDER BY delivery_id;

-- Tests for (b), (c) and (d)
SELECT fn_maize_rate('A') AS grade_a,
       fn_maize_rate('B') AS grade_b,
       fn_maize_rate('C') AS grade_c;

DO $$ BEGIN PERFORM fn_maize_rate(NULL);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (NULL grade): %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_maize_rate('D');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (grade D): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(99, 'A', 10, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown farmer): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(1, 'A', -5, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (negative weight): %', SQLERRM; END $$;

-- Direct SQL cannot cheat the price: the rate 99 and value 9999 are overwritten
DO $$
DECLARE
    v_rate  NUMERIC;
    v_total NUMERIC;
BEGIN
    INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on)
    VALUES (1, 'A', 10, 99, 9999, CURRENT_DATE)
    RETURNING unit_rate, total_value INTO v_rate, v_total;

    RAISE NOTICE 'Stored rate % and value % (expected 5 and 50)', v_rate, v_total;
    RAISE EXCEPTION 'Undoing the demo row';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE '%', SQLERRM; END $$;

DO $$ BEGIN
    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on)
    VALUES (1, 'A', 0, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Trigger rejected zero weight: %', SQLERRM; END $$;

SELECT count(*) FROM deliveries;    -- still 6

-- (e) View
-- Every farmer with their unpaid total; the unpaid filter sits in the JOIN so
-- farmers with nothing unpaid stay in the list, showing 0
CREATE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,
       f.full_name,
       COALESCE(SUM(d.total_value), 0) AS total_unpaid
FROM farmers f
LEFT JOIN deliveries d
       ON d.farmer_id = f.farmer_id AND d.is_paid = FALSE
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;    -- F001 500, F002 750, F003 0

-- (f) Index
-- Composite index: farmer_id (equality) first, then delivered_on (date range)
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);

ANALYZE deliveries;
SET enable_seqscan = off;      -- table is tiny, so force the planner to show the index
EXPLAIN
SELECT * FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job
-- Totals are recalculated from deliveries and replaced with ON CONFLICT,
-- so running it again never adds them twice
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day, COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
    FROM deliveries
    WHERE delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE
        SET total_weight = EXCLUDED.total_weight,
            total_value  = EXCLUDED.total_value;
END;
$$;

CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);    -- rerun test
SELECT * FROM daily_purchases;                  -- 460 kg, K1700

-- Schedule: every day at 01:30 for the previous day (needs pg_cron)
SELECT cron.schedule('refresh_purchases', '30 1 * * *',
                     $$CALL pr_refresh_purchases(CURRENT_DATE - 1)$$);
