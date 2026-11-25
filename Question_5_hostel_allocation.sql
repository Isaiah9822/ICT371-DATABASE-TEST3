-- =====================================================
-- ICT371 Advanced Database
-- Question 5: Hostel Room Allocation
-- Student: Nicholas | Mulungushi University
-- Database: PostgreSQL
-- =====================================================

DROP TABLE IF EXISTS occupancy_snapshot, allocations, rooms, students CASCADE;

-- (a) Database and seed data
-- Positive capacities; ACTIVE needs released_on NULL, ENDED needs a release date
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(10) NOT NULL UNIQUE,
    capacity    INT NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INT NOT NULL REFERENCES students(student_id),
    room_id       INT NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE NOT NULL,
    released_on   DATE,
    status        VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE', 'ENDED')),
    CHECK (
        (status = 'ACTIVE' AND released_on IS NULL)
        OR (status = 'ENDED' AND released_on IS NOT NULL)
    )
);

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id       INT NOT NULL REFERENCES rooms(room_id),
    occupied_beds INT NOT NULL,
    free_beds     INT NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO students (student_number, full_name) VALUES
    ('2024001', 'Kelvin Mwale'),
    ('2024002', 'Grace Chisenga'),
    ('2024003', 'Peter Simwanza'),
    ('2024004', 'Ruth Mutemwa'),
    ('2024005', 'Joseph Kunda'),
    ('2024006', 'Esther Lubinda');

-- A101 will be full, A102 partly occupied, A103 empty
INSERT INTO rooms (room_number, capacity) VALUES
    ('A101', 2),
    ('A102', 3),
    ('A103', 2);

-- (b) Function
-- Capacity minus ACTIVE allocations; ENDED ones do not count; rejects unknown room
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT AS $$
DECLARE
    v_capacity INT;
    v_active   INT;
BEGIN
    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room %', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_active
    FROM allocations
    WHERE room_id = p_room_id AND status = 'ACTIVE';

    RETURN v_capacity - v_active;
END;
$$ LANGUAGE plpgsql;

-- (d) Trigger
-- BEFORE INSERT OR UPDATE: enforces room capacity and one ACTIVE allocation
-- per student, even for direct SQL. The row being updated is excluded
-- from the counts. Created before the data is loaded.
CREATE OR REPLACE FUNCTION trg_alloc_rules_fn()
RETURNS TRIGGER AS $$
DECLARE
    v_capacity INT;
    v_others   INT;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        -- lock the room so two people cannot take the last bed together
        SELECT capacity INTO v_capacity FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Unknown room %', NEW.room_id;
        END IF;

        IF EXISTS (
            SELECT 1 FROM allocations a
            WHERE a.student_id = NEW.student_id
              AND a.status = 'ACTIVE'
              AND a.allocation_id IS DISTINCT FROM NEW.allocation_id
        ) THEN
            RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
        END IF;

        SELECT COUNT(*) INTO v_others
        FROM allocations a
        WHERE a.room_id = NEW.room_id
          AND a.status = 'ACTIVE'
          AND a.allocation_id IS DISTINCT FROM NEW.allocation_id;

        IF v_others >= v_capacity THEN
            RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_capacity;
        END IF;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_alloc_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_alloc_rules_fn();

-- Backup rule: one ACTIVE allocation per student, even under simultaneous inserts
CREATE UNIQUE INDEX uq_one_active_per_student
ON allocations (student_id)
WHERE status = 'ACTIVE';

-- (c) Procedure
-- Validates IDs, checks the student has no ACTIVE allocation and the room has a free bed,
-- then creates one ACTIVE allocation with released_on NULL
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INT, p_room_id INT, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        RAISE EXCEPTION 'Unknown student %', p_student_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM rooms WHERE room_id = p_room_id) THEN
        RAISE EXCEPTION 'Unknown room %', p_room_id;
    END IF;
    IF EXISTS (SELECT 1 FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;
    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % has no free beds', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

-- (a) continued: seed allocations
CALL pr_allocate_room(1, 1, CURRENT_DATE - 60);    -- A101 full
CALL pr_allocate_room(2, 1, CURRENT_DATE - 55);
CALL pr_allocate_room(3, 2, CURRENT_DATE - 40);    -- A102 has 2 of 3 beds taken
CALL pr_allocate_room(4, 2, CURRENT_DATE - 30);

-- History only: an ENDED allocation in A103 does not occupy a bed
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
VALUES (5, 3, CURRENT_DATE - 200, CURRENT_DATE - 100, 'ENDED');

SELECT * FROM allocations ORDER BY allocation_id;

-- Tests for (b), (c) and (d)
SELECT fn_free_beds(1) AS a101,    -- 0
       fn_free_beds(2) AS a102,    -- 1
       fn_free_beds(3) AS a103;    -- 2 (ended allocation ignored)

DO $$ BEGIN PERFORM fn_free_beds(999);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown room): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_allocate_room(6, 1, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (room full): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_allocate_room(1, 3, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (already ACTIVE): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_allocate_room(99, 3, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown student): %', SQLERRM; END $$;

-- Direct SQL that skips the procedure, stopped by the trigger
DO $$ BEGIN
    INSERT INTO allocations (student_id, room_id, allocated_on, status)
    VALUES (6, 1, CURRENT_DATE, 'ACTIVE');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Trigger rejected (capacity): %', SQLERRM; END $$;
DO $$ BEGIN
    INSERT INTO allocations (student_id, room_id, allocated_on, status)
    VALUES (1, 3, CURRENT_DATE, 'ACTIVE');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Trigger rejected (second ACTIVE): %', SQLERRM; END $$;

-- Ending an allocation frees the bed, then a new student can take it
UPDATE allocations SET status = 'ENDED', released_on = CURRENT_DATE WHERE allocation_id = 2;
SELECT fn_free_beds(1) AS a101_after_release;    -- 1
CALL pr_allocate_room(6, 1, CURRENT_DATE);

-- (e) View
-- Every room with capacity, occupied and free beds; LEFT JOIN keeps empty rooms
CREATE VIEW v_room_occupancy AS
SELECT r.room_id,
       r.room_number,
       r.capacity,
       COUNT(a.allocation_id)              AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a
       ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy ORDER BY room_id;

-- (f) Index
-- Partial index: only ACTIVE rows are indexed, so it stays small as history grows
CREATE INDEX idx_alloc_active_room ON allocations (room_id) WHERE status = 'ACTIVE';

ANALYZE allocations;
SET enable_seqscan = off;      -- table is tiny, so force the planner to show the index
EXPLAIN
SELECT * FROM allocations
WHERE room_id = 1
  AND status = 'ACTIVE';
RESET enable_seqscan;

-- (g) Scheduled job
-- Stores today's occupancy for every room; ON CONFLICT replaces the values on rerun
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, room_id, occupied_beds, free_beds
    FROM v_room_occupancy
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
        SET occupied_beds = EXCLUDED.occupied_beds,
            free_beds     = EXCLUDED.free_beds;
END;
$$;

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();    -- rerun test, still one row per room
SELECT * FROM occupancy_snapshot ORDER BY room_id;

-- Schedule: every day at 23:55 (needs pg_cron)
SELECT cron.schedule('refresh_occupancy', '55 23 * * *',
                     $$CALL pr_refresh_occupancy()$$);
