-- ICT371 Advanced Database | Question 4: Clinic Appointment Scheduling
-- Student: Luumbi Malambo | Student No: 202408554

DROP TABLE IF EXISTS clinic_summary, appointments, doctors, patients CASCADE;

-- (a) Tables ---------------------------------------------------------------
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
    patient_id      INTEGER NOT NULL REFERENCES patients(patient_id),
    doctor_id       INTEGER NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time       TIME NOT NULL,
    status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED',
    CONSTRAINT chk_slot   CHECK (slot_time IN ('09:00', '10:00', '11:00', '12:00')),
    CONSTRAINT chk_status CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);
CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INTEGER NOT NULL,
    attended_count  INTEGER NOT NULL,
    cancelled_count INTEGER NOT NULL
);

INSERT INTO patients (full_name) VALUES ('Peter Sakala'), ('Ruth Chisenga'), ('Samuel Nkhoma');
INSERT INTO doctors  (full_name) VALUES ('Dr. Mwale'), ('Dr. Chileshe'), ('Dr. Kapwepwe');

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INTEGER, p_day DATE)
RETURNS INTEGER AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    RETURN (SELECT COUNT(*)::INTEGER          -- COUNT gives 0 when there are no bookings
            FROM appointments
            WHERE doctor_id = p_doctor_id
              AND appointment_day = p_day
              AND status <> 'CANCELLED');
END;
$$ LANGUAGE plpgsql STABLE;

-- (d) Trigger (created before data is loaded) --------------------------------
CREATE OR REPLACE FUNCTION trg_appointment_clash() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' THEN
        IF EXISTS (
            SELECT 1 FROM appointments a
            WHERE a.doctor_id       = NEW.doctor_id
              AND a.appointment_day = NEW.appointment_day
              AND a.slot_time       = NEW.slot_time
              AND a.status         <> 'CANCELLED'
              -- On UPDATE this excludes the row being changed. On INSERT the new
              -- id does not exist yet, so nothing is excluded.
              AND a.appointment_id <> NEW.appointment_id
        ) THEN
            RAISE EXCEPTION 'Clash: doctor % already has an appointment on % at %',
                NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_appointment_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION trg_appointment_clash();

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_book_appointment(p_patient_id INTEGER, p_doctor_id INTEGER,
                                                p_day DATE, p_slot TIME)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
        RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;
    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date % is in the past or missing', p_day;
    END IF;
    IF p_slot IS NULL OR p_slot NOT IN ('09:00', '10:00', '11:00', '12:00') THEN
        RAISE EXCEPTION 'Unsupported slot: % (use 09:00, 10:00, 11:00 or 12:00)', p_slot;
    END IF;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');   -- trigger checks clashes
END;
$$;

-- Safety net: also a partial unique index (the trigger gives the friendlier message)
CREATE UNIQUE INDEX uq_doctor_day_slot_active
    ON appointments (doctor_id, appointment_day, slot_time)
    WHERE status <> 'CANCELLED';

-- (a) continued: six appointments with no slot clash
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
    (1, 1, CURRENT_DATE,     '09:00', 'BOOKED'),
    (2, 1, CURRENT_DATE,     '10:00', 'BOOKED'),
    (3, 2, CURRENT_DATE,     '09:00', 'BOOKED'),
    (1, 2, CURRENT_DATE - 1, '11:00', 'ATTENDED'),
    (2, 3, CURRENT_DATE - 1, '12:00', 'CANCELLED'),
    (3, 3, CURRENT_DATE + 1, '10:00', 'BOOKED');

SELECT * FROM appointments ORDER BY appointment_id;

-- Tests
SELECT fn_daily_load(1, CURRENT_DATE)     AS dr1_today;         -- 2
SELECT fn_daily_load(3, CURRENT_DATE - 1) AS dr3_yesterday;     -- 0 (the only one is cancelled)
SELECT fn_daily_load(3, CURRENT_DATE + 30) AS dr3_no_bookings;  -- 0

CALL pr_book_appointment(2, 3, CURRENT_DATE + 2, '11:00');      -- valid
DO $$
BEGIN
    BEGIN PERFORM fn_daily_load(99, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_book_appointment(99, 1, CURRENT_DATE + 1, '09:00');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE - 1, '09:00');   -- past date
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE + 1, '13:00');   -- bad slot
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE, '09:00');       -- clash (trigger)
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN UPDATE appointments SET slot_time = '09:00' WHERE appointment_id = 2;  -- UPDATE clash
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
END $$;
-- Updating a row without moving it must NOT clash with itself:
UPDATE appointments SET status = 'ATTENDED' WHERE appointment_id = 1;
-- A cancelled slot can be re-used:
UPDATE appointments SET status = 'CANCELLED' WHERE appointment_id = 2;
CALL pr_book_appointment(3, 1, CURRENT_DATE, '10:00');
SELECT * FROM appointments ORDER BY appointment_id;

-- (e) View: today's BOOKED appointments only; no unrelated patient data ------
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name,
       d.full_name AS doctor_name,
       a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';

SELECT * FROM v_today_appointments ORDER BY slot_time;

-- (f) Index ----------------------------------------------------------------
-- Searches filter on a day and a doctor, so a NON-unique composite index
-- (appointment_day, doctor_id) lets PostgreSQL go straight to those rows.
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);
ANALYZE appointments;
SET enable_seqscan = off;   -- tiny table: force the plan to show the index
EXPLAIN
SELECT * FROM appointments WHERE appointment_day = CURRENT_DATE AND doctor_id = 1;
RESET enable_seqscan;

-- (g) Scheduled job --------------------------------------------------------
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
CALL pr_refresh_clinic_summary(CURRENT_DATE);    -- rerun replaces the row
SELECT * FROM clinic_summary;

-- Scheduling with pg_cron. If pg_cron is not installed, this prints a notice instead
-- of failing, so the rest of the script is not rolled back.
DO $do$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    PERFORM cron.schedule('refresh_clinic_summary_daily', '0 1 * * *',
        $$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_cron not available, job not scheduled: %', SQLERRM;
END $do$;

-- Inspect the job (works only where pg_cron is installed):
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT jobid, runid, status, return_message, start_time, end_time
--   FROM cron.job_run_details ORDER BY start_time DESC LIMIT 20;
