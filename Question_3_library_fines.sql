-- =====================================================
-- ICT371 Advanced Database
-- Question 3: Library Returns and Overdue Fines
-- Student: Nicholas | Mulungushi University
-- Database: PostgreSQL
-- =====================================================

DROP TABLE IF EXISTS overdue_summary, loan_audit, loans, books CASCADE;

-- (a) Database and seed data
-- due_on must be on or after borrowed_on; returned_on is NULL while the book is out
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INT NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on   DATE NOT NULL,
    due_on        DATE NOT NULL,
    returned_on   DATE,
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CHECK (due_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id        SERIAL PRIMARY KEY,
    loan_id         INT NOT NULL REFERENCES loans(loan_id),
    old_returned_on DATE,
    new_returned_on DATE,
    changed_at      TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INT NOT NULL,
    total_fine    NUMERIC(12,2) NOT NULL
);

INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Introduction to Algorithms'),
    ('Computer Networks');

-- (b) Function
-- K2 per day late, never below zero; stops at the return date if returned
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC AS $$
DECLARE
    v_due      DATE;
    v_returned DATE;
    v_end      DATE;
BEGIN
    SELECT due_on, returned_on INTO v_due, v_returned
    FROM loans WHERE loan_id = p_loan_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan %', p_loan_id;
    END IF;

    -- use the earlier of the as-of date and the return date
    v_end := LEAST(p_as_of, COALESCE(v_returned, p_as_of));

    RETURN 2 * GREATEST(v_end - v_due, 0);
END;
$$ LANGUAGE plpgsql;

-- (c) Procedure
-- Rejects unknown, already returned, or too-early returns.
-- Return date and final fine are saved together in one UPDATE.
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_borrowed DATE;
    v_returned DATE;
    v_fine     NUMERIC;
BEGIN
    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans WHERE loan_id = p_loan_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan %', p_loan_id;
    END IF;

    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned', p_loan_id;
    END IF;

    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date is before the borrowed date';
    END IF;

    v_fine := fn_loan_fine(p_loan_id, p_returned_on);

    UPDATE loans
    SET returned_on = p_returned_on,
        fine_amount = v_fine
    WHERE loan_id = p_loan_id;
END;
$$;

-- (d) Trigger
-- AFTER UPDATE row trigger: logs OLD and NEW returned_on, only when the date changes
CREATE OR REPLACE FUNCTION trg_loan_audit_fn()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on)
    VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_loan_audit_fn();

-- (a) continued: six loans (dates are relative to today)
-- Loans 1 and 5 are open and overdue, 2 and 6 are open and on time,
-- 3 and 4 get returned below
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
    (1, 'Mwila Chanda',   CURRENT_DATE - 30, CURRENT_DATE - 16),
    (1, 'Chola Mumba',    CURRENT_DATE - 5,  CURRENT_DATE + 9),
    (2, 'Natasha Tembo',  CURRENT_DATE - 40, CURRENT_DATE - 26),
    (2, 'Bwalya Sakala',  CURRENT_DATE - 20, CURRENT_DATE - 6),
    (3, 'Temwani Lungu',  CURRENT_DATE - 10, CURRENT_DATE - 3),
    (3, 'Mulenga Kapesa', CURRENT_DATE - 15, CURRENT_DATE + 1);

CALL pr_return_loan(3, CURRENT_DATE - 20);    -- 6 days late, fine K12
CALL pr_return_loan(4, CURRENT_DATE - 6);     -- returned on the due date, fine K0

SELECT * FROM loans ORDER BY loan_id;
SELECT * FROM loan_audit;                     -- 2 rows

-- Tests for (b), (c) and (d)
SELECT fn_loan_fine(1, CURRENT_DATE) AS open_overdue,    -- 32
       fn_loan_fine(2, CURRENT_DATE) AS on_time,         -- 0
       fn_loan_fine(3, CURRENT_DATE) AS returned_late;   -- 12

DO $$ BEGIN PERFORM fn_loan_fine(999, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown loan): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(3, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (already returned): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(1, CURRENT_DATE - 100);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (before borrowed date): %', SQLERRM; END $$;

UPDATE loans SET borrower_name = 'Mwila C. Chanda' WHERE loan_id = 1;
SELECT count(*) FROM loan_audit;              -- still 2, no audit row for a name change

-- (e) View
-- Loans not returned and due before today, with the fine as of today
CREATE VIEW v_overdue_loans AS
SELECT b.title,
       l.borrower_name,
       l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans;                -- loans 1 and 5

-- (f) Index
-- Partial index: only unreturned loans are indexed, which is what this search needs
CREATE INDEX idx_loans_book_open ON loans (book_id) WHERE returned_on IS NULL;

ANALYZE loans;
SET enable_seqscan = off;      -- table is tiny, so force the planner to show the index
EXPLAIN
SELECT * FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;
RESET enable_seqscan;

-- (g) Scheduled job
-- Counts loans still out and past due on that date, sums their fines.
-- ON CONFLICT replaces the row for the same snapshot_date.
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of,
           COUNT(*),
           COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM loans
    WHERE borrowed_on <= p_as_of
      AND (returned_on IS NULL OR returned_on > p_as_of)
      AND due_on < p_as_of
    ON CONFLICT (snapshot_date) DO UPDATE
        SET overdue_count = EXCLUDED.overdue_count,
            total_fine    = EXCLUDED.total_fine;
END;
$$;

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);        -- rerun test
SELECT * FROM overdue_summary;                -- 2 loans, K38

-- Schedule: every day at 00:10 for today (needs pg_cron)
SELECT cron.schedule('refresh_overdue', '10 0 * * *',
                     $$CALL pr_refresh_overdue(CURRENT_DATE)$$);
