-- Student: Lute Walusungu Gondwe (202407170) | Target: PostgreSQL 14+

DROP SCHEMA IF EXISTS q8_fleet CASCADE;
CREATE SCHEMA q8_fleet;
SET search_path = q8_fleet, public;

CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          VARCHAR(15) NOT NULL UNIQUE,
    current_odometer      INTEGER     NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer INTEGER     NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT ck_service_not_ahead CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE    NOT NULL,
    start_odometer INTEGER NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INTEGER NOT NULL CHECK (end_odometer >= 0)
);

CREATE TABLE service_alerts (
    vehicle_id       INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service INTEGER NOT NULL,
    flagged_on       DATE    NOT NULL DEFAULT CURRENT_DATE
);

INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('BAE 1001', 12000, 10000),
    ('BAF 2002', 20000, 14000),
    ('BAG 3003',  8000,  3000);

CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN AS $$
DECLARE
    v_current INTEGER;
    v_service INTEGER;
BEGIN
    SELECT current_odometer, last_service_odometer INTO v_current, v_service
    FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    RETURN (v_current - v_service) >= 5000;
END;
$$ LANGUAGE plpgsql STABLE;

SELECT vehicle_id, fn_service_due(vehicle_id) AS due FROM vehicles ORDER BY vehicle_id;

CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INTEGER, p_trip_on DATE, p_start INTEGER, p_end INTEGER)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;
    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Trip date, start odometer and end odometer are all required';
    END IF;
    IF p_end <= p_start THEN
        RAISE EXCEPTION 'End odometer % must be greater than start odometer %', p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

CREATE OR REPLACE FUNCTION trg_fn_trip_odometer()
RETURNS TRIGGER AS $$
DECLARE
    v_current INTEGER;
BEGIN
    SELECT current_odometer INTO v_current FROM vehicles WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;

    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Trip must start at the current odometer %, got %', v_current, NEW.start_odometer;
    END IF;
    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: end % is not greater than start %',
            NEW.end_odometer, NEW.start_odometer;
    END IF;

    UPDATE vehicles SET current_odometer = NEW.end_odometer WHERE vehicle_id = NEW.vehicle_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_trip_odometer();

CALL pr_record_trip(1, '2026-11-10', 12000, 12300);
CALL pr_record_trip(1, '2026-11-14', 12300, 12500);
CALL pr_record_trip(2, '2026-11-11', 20000, 20400);
CALL pr_record_trip(2, '2026-11-15', 20400, 20900);
CALL pr_record_trip(3, '2026-11-12',  8000,  8100);
CALL pr_record_trip(3, '2026-11-16',  8100,  8300);

SELECT * FROM trips ORDER BY trip_id;
SELECT * FROM vehicles ORDER BY vehicle_id;

DO $$
BEGIN
    BEGIN CALL pr_record_trip(99, CURRENT_DATE, 0, 10);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Unknown vehicle: %', SQLERRM; END;
    BEGIN CALL pr_record_trip(1, CURRENT_DATE, 12500, 12500);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'End not greater: %', SQLERRM; END;
    BEGIN CALL pr_record_trip(1, CURRENT_DATE, 12000, 12600);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Wrong start (trigger): %', SQLERRM; END;
    BEGIN INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer) VALUES (1, CURRENT_DATE, 12500, 12400);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Bad mileage (trigger): %', SQLERRM; END;
END $$;
SELECT COUNT(*) AS trip_rows FROM trips;

CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

SELECT * FROM v_service_due ORDER BY registration;

CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);
ANALYZE trips;

SET enable_seqscan = off;
EXPLAIN
SELECT trip_id, trip_on, start_odometer, end_odometer
FROM trips
WHERE vehicle_id = 2
  AND trip_on BETWEEN '2026-11-01' AND '2026-11-30';
RESET enable_seqscan;

CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT v.vehicle_id, v.current_odometer - v.last_service_odometer, CURRENT_DATE
    FROM vehicles v
    WHERE fn_service_due(v.vehicle_id)
    ON CONFLICT (vehicle_id)
    DO UPDATE SET km_since_service = EXCLUDED.km_since_service;

    DELETE FROM service_alerts sa
    WHERE NOT EXISTS (SELECT 1 FROM vehicles v
                      WHERE v.vehicle_id = sa.vehicle_id
                        AND fn_service_due(v.vehicle_id));
END;
$$;

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;

UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 2;
CALL pr_refresh_service_alerts();
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q8_refresh_service_alerts',
    '0 6 * * 1',
    $cron$CALL q8_fleet.pr_refresh_service_alerts()$cron$
);
