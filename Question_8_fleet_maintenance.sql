-- =====================================================
-- ICT371 Advanced Database
-- Question 8: Transport Fleet Maintenance
-- Student: Nicholas | Mulungushi University
-- Database: PostgreSQL
-- =====================================================

DROP TABLE IF EXISTS service_alerts, trips, vehicles CASCADE;

-- (a) Database and seed data
-- Non-negative odometers; last_service_odometer can never exceed current_odometer
CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          VARCHAR(15) NOT NULL UNIQUE,
    current_odometer      INT NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer INT NOT NULL CHECK (last_service_odometer >= 0),
    CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INT NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE NOT NULL,
    start_odometer INT NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INT NOT NULL CHECK (end_odometer >= 0)
);

CREATE TABLE service_alerts (
    vehicle_id       INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service INT NOT NULL,
    flagged_on       DATE NOT NULL
);

-- Three vehicles at different service positions
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('BAK 1234', 52000, 50000),    -- 2000 km since service
    ('BAM 5678', 30000, 24000),    -- 6000 km since service (already due)
    ('BAN 9012', 10000,  5800);    -- 4200 km now, reaches exactly 5000 after its trips

-- (b) Function
-- True when 5000 km or more since the last service; rejects unknown vehicle
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN AS $$
DECLARE
    v_km INT;
BEGIN
    SELECT current_odometer - last_service_odometer INTO v_km
    FROM vehicles WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle %', p_vehicle_id;
    END IF;

    RETURN v_km >= 5000;
END;
$$ LANGUAGE plpgsql;

-- (d) Trigger
-- BEFORE INSERT on trips: checks the start matches the vehicle's odometer,
-- rejects invalid mileage, then moves current_odometer to the trip end (once).
-- Installed before any trips are added.
CREATE OR REPLACE FUNCTION trg_trip_odometer_fn()
RETURNS TRIGGER AS $$
DECLARE
    v_current INT;
BEGIN
    -- lock the vehicle row so two trips cannot start from the same reading
    SELECT current_odometer INTO v_current
    FROM vehicles WHERE vehicle_id = NEW.vehicle_id
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle %', NEW.vehicle_id;
    END IF;

    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: end % must be greater than start %',
                        NEW.end_odometer, NEW.start_odometer;
    END IF;

    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Trip must start at the current odometer % (got %)',
                        v_current, NEW.start_odometer;
    END IF;

    UPDATE vehicles SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_trip_odometer_fn();

-- (c) Procedure
-- Validates the vehicle and mileage, then inserts the trip.
-- It does not update the vehicle odometer; the trigger does that.
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INT, p_trip_on DATE, p_start INT, p_end INT)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle %', p_vehicle_id;
    END IF;
    IF p_start IS NULL OR p_end IS NULL OR p_end <= p_start THEN
        RAISE EXCEPTION 'end_odometer must be greater than start_odometer';
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- (a) continued: six trips added through the procedure, two per vehicle
CALL pr_record_trip(1, CURRENT_DATE - 6, 52000, 52300);
CALL pr_record_trip(1, CURRENT_DATE - 3, 52300, 52800);
CALL pr_record_trip(2, CURRENT_DATE - 5, 30000, 30400);
CALL pr_record_trip(2, CURRENT_DATE - 2, 30400, 31000);
CALL pr_record_trip(3, CURRENT_DATE - 4, 10000, 10300);
CALL pr_record_trip(3, CURRENT_DATE - 1, 10300, 10800);

SELECT * FROM vehicles ORDER BY vehicle_id;    -- odometers now 52800, 31000, 10800
SELECT * FROM trips ORDER BY trip_id;

-- Tests for (b), (c) and (d)
SELECT fn_service_due(1) AS vehicle1,    -- false (2800 km)
       fn_service_due(2) AS vehicle2,    -- true  (7000 km)
       fn_service_due(3) AS vehicle3;    -- true  (exactly 5000 km)

DO $$ BEGIN PERFORM fn_service_due(999);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown vehicle): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 40000, 40100);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (wrong start): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 52800, 52800);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (end not greater): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(99, CURRENT_DATE, 0, 10);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown vehicle): %', SQLERRM; END $$;

-- Direct SQL with bad mileage is also stopped by the trigger
DO $$ BEGIN
    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (1, CURRENT_DATE, 52800, 52000);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Trigger rejected direct insert: %', SQLERRM; END $$;

SELECT count(*) FROM trips;    -- still 6

-- (e) View
-- Vehicles that have reached the 5000 km threshold
CREATE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

SELECT * FROM v_service_due ORDER BY registration;    -- BAM 5678 and BAN 9012

-- (f) Index
-- vehicle_id (equality) first, then trip_on (date range), so one vehicle's
-- trips are read as a single ordered slice of the index
CREATE INDEX idx_trips_vehicle_date ON trips (vehicle_id, trip_on);

ANALYZE trips;
SET enable_seqscan = off;      -- table is tiny, so force the planner to show the index
EXPLAIN
SELECT * FROM trips
WHERE vehicle_id = 2
  AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) Scheduled job
-- Adds or updates an alert for each due vehicle, then removes alerts for
-- vehicles that are no longer due. On update, flagged_on keeps the date
-- the vehicle was first flagged.
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
    FROM vehicles
    WHERE current_odometer - last_service_odometer >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
        SET km_since_service = EXCLUDED.km_since_service;

    DELETE FROM service_alerts sa
    USING vehicles v
    WHERE v.vehicle_id = sa.vehicle_id
      AND v.current_odometer - v.last_service_odometer < 5000;
END;
$$;

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;    -- vehicles 2 and 3

-- Vehicle 2 gets serviced, so its alert disappears on the next run
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 2;
CALL pr_refresh_service_alerts();
CALL pr_refresh_service_alerts();                    -- rerun test
SELECT * FROM service_alerts ORDER BY vehicle_id;    -- only vehicle 3 left

-- Schedule: every Monday at 06:00 (needs pg_cron)
SELECT cron.schedule('refresh_service_alerts', '0 6 * * 1',
                     $$CALL pr_refresh_service_alerts()$$);
