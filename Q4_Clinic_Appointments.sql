-- Student: Lute Walusungu Gondwe (202407170) | Target: PostgreSQL 14+

DROP SCHEMA IF EXISTS q4_clinic CASCADE;
CREATE SCHEMA q4_clinic;
SET search_path = q4_clinic, public;

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
    patient_id      INTEGER     NOT NULL REFERENCES patients(patient_id),
    doctor_id       INTEGER     NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE        NOT NULL,
    slot_time       TIME        NOT NULL,
    status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED',
    CONSTRAINT ck_status CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED')),
    CONSTRAINT ck_slot   CHECK (slot_time IN ('09:00', '10:00', '11:00', '12:00'))
);

CREATE UNIQUE INDEX ux_active_slot
    ON appointments (doctor_id, appointment_day, slot_time)
    WHERE status <> 'CANCELLED';

CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INTEGER NOT NULL DEFAULT 0,
    attended_count  INTEGER NOT NULL DEFAULT 0,
    cancelled_count INTEGER NOT NULL DEFAULT 0
);

INSERT INTO patients (full_name) VALUES ('Patricia Sakala'), ('Kelvin Mumba'), ('Natasha Kunda');
INSERT INTO doctors  (full_name) VALUES ('Dr. Chileshe'), ('Dr. Nkonde'), ('Dr. Simwanza');

CREATE OR REPLACE FUNCTION trg_fn_appointment_clash()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' THEN
        IF EXISTS (
            SELECT 1
            FROM appointments a
            WHERE a.doctor_id       = NEW.doctor_id
              AND a.appointment_day = NEW.appointment_day
              AND a.slot_time       = NEW.slot_time
              AND a.status         <> 'CANCELLED'
              AND a.appointment_id IS DISTINCT FROM NEW.appointment_id
        ) THEN
            RAISE EXCEPTION 'Doctor % is already booked on % at %',
                NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_appointment_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_appointment_clash();

INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
    (1, 1, CURRENT_DATE,     '09:00', 'BOOKED'),
    (2, 1, CURRENT_DATE,     '10:00', 'BOOKED'),
    (3, 2, CURRENT_DATE,     '09:00', 'BOOKED'),
    (1, 2, CURRENT_DATE - 1, '11:00', 'ATTENDED'),
    (2, 3, CURRENT_DATE - 1, '12:00', 'CANCELLED'),
    (3, 3, CURRENT_DATE + 1, '09:00', 'BOOKED');

SELECT * FROM appointments ORDER BY appointment_id;

CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INTEGER, p_day DATE)
RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    SELECT COUNT(*) INTO v_count
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN v_count;
END;
$$ LANGUAGE plpgsql STABLE;

SELECT fn_daily_load(1, CURRENT_DATE)     AS dr1_today;
SELECT fn_daily_load(3, CURRENT_DATE - 1) AS cancelled_only;
SELECT fn_daily_load(1, CURRENT_DATE + 30) AS empty_day;

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
        RAISE EXCEPTION 'Unsupported slot %. Use 09:00, 10:00, 11:00 or 12:00', p_slot;
    END IF;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

CALL pr_book_appointment(2, 3, CURRENT_DATE + 2, '10:00');

DO $$
BEGIN
    BEGIN CALL pr_book_appointment(99, 1, CURRENT_DATE + 1, '09:00');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Unknown patient: %', SQLERRM; END;
    BEGIN CALL pr_book_appointment(1, 99, CURRENT_DATE + 1, '09:00');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Unknown doctor: %', SQLERRM; END;
    BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE - 1, '09:00');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Past date: %', SQLERRM; END;
    BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE + 1, '13:00');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Bad slot: %', SQLERRM; END;
    BEGIN CALL pr_book_appointment(3, 1, CURRENT_DATE, '09:00');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Clash (trigger): %', SQLERRM; END;
    BEGIN UPDATE appointments SET slot_time = '09:00' WHERE appointment_id = 2;
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Clash on update (trigger): %', SQLERRM; END;
    UPDATE appointments SET status = 'ATTENDED' WHERE appointment_id = 1;
    RAISE NOTICE 'Self-update accepted';
END $$;

CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name,
       d.full_name AS doctor_name,
       a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';

SELECT * FROM v_today_appointments ORDER BY slot_time, doctor_name;

CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);
ANALYZE appointments;

SET enable_seqscan = off;
EXPLAIN
SELECT appointment_id, patient_id, slot_time, status
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 1;
RESET enable_seqscan;

CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_booked    INTEGER;
    v_attended  INTEGER;
    v_cancelled INTEGER;
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Day is required';
    END IF;

    SELECT COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    INTO v_booked, v_attended, v_cancelled
    FROM appointments
    WHERE appointment_day = p_day;

    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    VALUES (p_day, v_booked, v_attended, v_cancelled)
    ON CONFLICT (summary_date)
    DO UPDATE SET booked_count    = EXCLUDED.booked_count,
                  attended_count  = EXCLUDED.attended_count,
                  cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
SELECT * FROM clinic_summary;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q4_refresh_clinic_summary',
    '0 1 * * *',
    $cron$CALL q4_clinic.pr_refresh_clinic_summary(CURRENT_DATE - 1)$cron$
);
