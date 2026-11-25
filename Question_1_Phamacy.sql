-- =====================================================
-- ICT371 Advanced Database
-- Question 1: Pharmacy Stock and Daily Sales
-- Student: Nicholas | Mulungushi University
-- Database: PostgreSQL
-- =====================================================

DROP TABLE IF EXISTS daily_sales, stock_audit, sales, medicines CASCADE;

-- (a) Database and seed data
-- Four tables with keys, positive prices and non-negative stock
CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100) NOT NULL,
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INT NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id     SERIAL PRIMARY KEY,
    medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
    quantity    INT NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10,2) NOT NULL,
    sold_on     DATE NOT NULL
);

CREATE TABLE stock_audit (
    audit_id    SERIAL PRIMARY KEY,
    medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INT NOT NULL,
    new_qty     INT NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INT NOT NULL,
    total_amount NUMERIC(12,2) NOT NULL
);

-- Four medicines (sales are loaded later through the procedure)
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol', 2.50, 100),
    ('Amoxicillin', 8.00,  30),
    ('Ibuprofen',   4.00,  20),
    ('ORS Sachet',  1.50,  12);

-- (b) Function
-- Returns current price x quantity, rejects unknown medicine or bad quantity
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC AS $$
DECLARE
    v_price NUMERIC;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive';
    END IF;

    SELECT unit_price INTO v_price FROM medicines WHERE medicine_id = p_medicine_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine %', p_medicine_id;
    END IF;

    RETURN v_price * p_quantity;
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure
-- Checks stock, saves the sale with the current price, deducts stock once.
-- If any check fails, nothing is saved in either table.
CREATE OR REPLACE PROCEDURE pr_record_sale(p_medicine_id INT, p_quantity INT, p_sold_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_price NUMERIC;
    v_stock INT;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Quantity must be positive';
    END IF;

    -- FOR UPDATE locks the row so two sales cannot oversell at the same time
    SELECT unit_price, stock_qty INTO v_price, v_stock
    FROM medicines WHERE medicine_id = p_medicine_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine %', p_medicine_id;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Not enough stock: have %, need %', v_stock, p_quantity;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    UPDATE medicines SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END;
$$;

-- (d) Trigger
-- AFTER UPDATE row trigger: logs old and new stock, only when stock_qty changes
CREATE OR REPLACE FUNCTION trg_stock_audit_fn()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO stock_audit (medicine_id, old_qty, new_qty)
    VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION trg_stock_audit_fn();

-- (a) continued: six sales loaded through the procedure
CALL pr_record_sale(1, 20, CURRENT_DATE - 1);
CALL pr_record_sale(2,  5, CURRENT_DATE - 1);
CALL pr_record_sale(3,  6, CURRENT_DATE - 1);
CALL pr_record_sale(3,  5, CURRENT_DATE - 1);
CALL pr_record_sale(4,  4, CURRENT_DATE - 1);
CALL pr_record_sale(1, 15, CURRENT_DATE - 1);

SELECT * FROM sales;
SELECT * FROM stock_audit;

-- Tests for (b) and (c)
SELECT fn_sale_value(1, 3);

DO $$ BEGIN CALL pr_record_sale(2, 9999, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

SELECT count(*) FROM sales;    -- still 6

-- (e) View
-- Medicines with stock below 10, checked after another sale
CREATE VIEW v_low_stock AS
SELECT medicine_name, unit_price, stock_qty
FROM medicines
WHERE stock_qty < 10;

CALL pr_record_sale(2, 18, CURRENT_DATE);
SELECT * FROM v_low_stock;

-- (f) Index
-- Equality column (medicine_id) first, then the date range column (sold_on)
CREATE INDEX idx_sales_medicine_date ON sales (medicine_id, sold_on);

ANALYZE sales;
SET enable_seqscan = off;      -- table is tiny, so force the planner to show the index
EXPLAIN
SELECT * FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job
-- ON CONFLICT replaces the day's row, so reruns never double-count
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day, COALESCE(SUM(quantity), 0), COALESCE(SUM(quantity * unit_price), 0)
    FROM sales
    WHERE sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
        SET total_qty    = EXCLUDED.total_qty,
            total_amount = EXCLUDED.total_amount;
END;
$$;

CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);    -- rerun test
SELECT * FROM daily_sales;                  -- 55 units, K177.50

-- Schedule: every day at 00:15 for the previous day (needs pg_cron)
SELECT cron.schedule('refresh_sales', '15 0 * * *',
                     $$CALL pr_refresh_sales(CURRENT_DATE - 1)$$);
