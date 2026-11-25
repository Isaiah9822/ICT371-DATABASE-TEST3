-- =====================================================
-- ICT371 Advanced Database
-- Question 4: Clinic Appointment Scheduling
-- Student: Nicholas | Mulungushi University
-- Database: PostgreSQL
-- =====================================================

DROP TABLE IF EXISTS clinic_summary, appointments, doctors, patients CASCADE;

-- (a) Database and seed data
-- slot_time is a TIME limited to the four slots; status is BOOKED, ATTENDED or CANCELLED
CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    patient_id      INT NOT NULL REFERENCES patients(patient_id),
    doctor_id       INT NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time       TIME NOT NULL CHECK (slot_time IN ('09:00', '10:00', '11:00', '12:00')),
    status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED'
                    CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INT NOT NULL,
    attended_count  INT NOT NULL,
    cancelled_count INT NOT NULL
);

INSERT INTO patients (full_name) VALUES ('Alice Mwansa'), ('Brian Kasonde'), ('Cynthia Nkole');
INSERT INTO doctors  (full_name) VALUES ('Dr. Daka'), ('Dr. Ngoma'), ('Dr. Zimba');

-- (b) Function
-- Counts a doctor's non-cancelled appointments for a day; 0 if none; rejects unknown doctor
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INT AS $$
DECLARE
    v_count INT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor %', p_doctor_id;
    END IF;

    SELECT COUNT(*) INTO v_count
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- (d) Trigger
-- BEFORE INSERT OR UPDATE: rejects a clash with another non-cancelled appointment.
-- On UPDATE the row being changed is excluded, so it never clashes with itself.
-- Created before the procedure is used because the procedure relies on it.
CREATE OR REPLACE FUNCTION trg_appt_clash_fn()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' THEN
        IF EXISTS (
            SELECT 1 FROM appointments a
            WHERE a.doctor_id = NEW.doctor_id
              AND a.appointment_day = NEW.appointment_day
              AND a.slot_time = NEW.slot_time
              AND a.status <> 'CANCELLED'
              AND a.appointment_id IS DISTINCT FROM NEW.appointment_id
        ) THEN
            RAISE EXCEPTION 'Slot clash: doctor % is already booked on % at %',
                            NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_appt_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_appt_clash_fn();

-- Backup rule: the database itself blocks double bookings, even if two
-- people book the same slot at the exact same moment
CREATE UNIQUE INDEX uq_doctor_slot
ON appointments (doctor_id, appointment_day, slot_time)
WHERE status <> 'CANCELLED';

-- (c) Procedure
-- Validates IDs, rejects past dates and unsupported slots, inserts a BOOKED appointment
CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INT, p_doctor_id INT, p_day DATE, p_slot TIME)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
        RAISE EXCEPTION 'Unknown patient %', p_patient_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor %', p_doctor_id;
    END IF;
    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date % is in the past', p_day;
    END IF;
    IF p_slot IS NULL OR p_slot NOT IN ('09:00', '10:00', '11:00', '12:00') THEN
        RAISE EXCEPTION 'Unsupported slot %', p_slot;
    END IF;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

-- (a) continued: six appointments with no slot clashes
CALL pr_book_appointment(1, 1, CURRENT_DATE,     '09:00');
CALL pr_book_appointment(2, 1, CURRENT_DATE,     '10:00');
CALL pr_book_appointment(3, 2, CURRENT_DATE,     '09:00');   -- same slot, different doctor
CALL pr_book_appointment(1, 3, CURRENT_DATE + 1, '11:00');
CALL pr_book_appointment(2, 2, CURRENT_DATE + 1, '12:00');
CALL pr_book_appointment(3, 3, CURRENT_DATE + 2, '10:00');

UPDATE appointments SET status = 'ATTENDED'  WHERE appointment_id = 2;
UPDATE appointments SET status = 'CANCELLED' WHERE appointment_id = 6;

SELECT * FROM appointments ORDER BY appointment_id;

-- Tests for (b), (c) and (d)
SELECT fn_daily_load(1, CURRENT_DATE)      AS dr_daka_today,       -- 2
       fn_daily_load(3, CURRENT_DATE + 2)  AS cancelled_only,      -- 0
       fn_daily_load(2, CURRENT_DATE + 30) AS no_bookings;         -- 0

DO $$ BEGIN PERFORM fn_daily_load(999, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown doctor): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(3, 1, CURRENT_DATE, '09:00');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (clash): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE - 1, '09:00');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (past date): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE + 5, '13:00');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (bad slot): %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(99, 1, CURRENT_DATE + 5, '09:00');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (unknown patient): %', SQLERRM; END $$;

-- UPDATE side of the trigger
UPDATE appointments SET status = 'BOOKED' WHERE appointment_id = 1;      -- fine, excludes itself
DO $$ BEGIN UPDATE appointments SET slot_time = '10:00' WHERE appointment_id = 1;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected (update clash): %', SQLERRM; END $$;

-- A cancelled slot can be booked again
CALL pr_book_appointment(1, 3, CURRENT_DATE + 2, '10:00');

-- (e) View
-- Today's BOOKED appointments with only patient name, doctor name and slot
CREATE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name,
       d.full_name AS doctor_name,
       a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.status = 'BOOKED'
  AND a.appointment_day = CURRENT_DATE;

SELECT * FROM v_today_appointments ORDER BY slot_time;

-- (f) Index
-- Non-unique index on day and doctor, the two columns the search filters on
CREATE INDEX idx_appt_day_doctor ON appointments (appointment_day, doctor_id);

ANALYZE appointments;
SET enable_seqscan = off;      -- table is tiny, so force the planner to show the index
EXPLAIN
SELECT * FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 1;
RESET enable_seqscan;

-- (g) Scheduled job
-- Counts each status for the day; ON CONFLICT replaces the day's row on rerun
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM appointments
    WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
        SET booked_count    = EXCLUDED.booked_count,
            attended_count  = EXCLUDED.attended_count,
            cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

CALL pr_refresh_clinic_summary(CURRENT_DATE);
CALL pr_refresh_clinic_summary(CURRENT_DATE);    -- rerun test
SELECT * FROM clinic_summary;                    -- booked 2, attended 1, cancelled 0

-- Schedule: every day at 01:00 for the previous day (needs pg_cron)
SELECT cron.schedule('refresh_clinic_summary', '0 1 * * *',
                     $$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);
