-- Student: Lute Walusungu Gondwe (202407170) | Target: PostgreSQL 14+

DROP SCHEMA IF EXISTS q5_hostel CASCADE;
CREATE SCHEMA q5_hostel;
SET search_path = q5_hostel, public;

CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(10) NOT NULL UNIQUE,
    capacity    INTEGER     NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INTEGER     NOT NULL REFERENCES students(student_id),
    room_id       INTEGER     NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE        NOT NULL,
    released_on   DATE        NULL,
    status        VARCHAR(10) NOT NULL DEFAULT 'ACTIVE',
    CONSTRAINT ck_alloc_status CHECK (status IN ('ACTIVE', 'ENDED')),
    CONSTRAINT ck_alloc_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED'  AND released_on IS NOT NULL AND released_on >= allocated_on)
    )
);

CREATE UNIQUE INDEX ux_one_active_per_student ON allocations (student_id) WHERE status = 'ACTIVE';

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE    NOT NULL,
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL CHECK (occupied_beds >= 0),
    free_beds     INTEGER NOT NULL CHECK (free_beds >= 0),
    PRIMARY KEY (snapshot_date, room_id)
);

CREATE OR REPLACE FUNCTION trg_fn_allocation_rules()
RETURNS TRIGGER AS $$
DECLARE
    v_capacity INTEGER;
    v_others   INTEGER;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        SELECT capacity INTO v_capacity FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Unknown room_id: %', NEW.room_id;
        END IF;

        IF EXISTS (SELECT 1 FROM allocations a
                   WHERE a.student_id = NEW.student_id
                     AND a.status = 'ACTIVE'
                     AND a.allocation_id IS DISTINCT FROM NEW.allocation_id) THEN
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

CREATE TRIGGER trg_allocation_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_fn_allocation_rules();

INSERT INTO students (student_number, full_name) VALUES
    ('202405001', 'Thandiwe Mulenga'),
    ('202405002', 'Joseph Kapaya'),
    ('202405003', 'Ruth Bwalya'),
    ('202405004', 'Samuel Zimba'),
    ('202405005', 'Agnes Chola'),
    ('202405006', 'Peter Musonda');

INSERT INTO rooms (room_number, capacity) VALUES
    ('A101', 2),
    ('A102', 3),
    ('A103', 2);

INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status) VALUES
    (1, 1, '2026-09-01', NULL,         'ACTIVE'),
    (2, 1, '2026-09-01', NULL,         'ACTIVE'),
    (3, 2, '2026-09-02', NULL,         'ACTIVE'),
    (4, 3, '2026-02-01', '2026-06-30', 'ENDED'),
    (4, 2, '2026-09-05', NULL,         'ACTIVE'),
    (5, 1, '2026-02-01', '2026-06-30', 'ENDED');

SELECT * FROM allocations ORDER BY allocation_id;

CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INTEGER)
RETURNS INTEGER AS $$
DECLARE
    v_capacity INTEGER;
    v_active   INTEGER;
BEGIN
    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_active
    FROM allocations WHERE room_id = p_room_id AND status = 'ACTIVE';

    RETURN v_capacity - v_active;
END;
$$ LANGUAGE plpgsql STABLE;

SELECT room_id, fn_free_beds(room_id) AS free_beds FROM rooms ORDER BY room_id;

CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INTEGER, p_room_id INTEGER, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date is required';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
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

CALL pr_allocate_room(5, 2, '2026-11-25');

DO $$
BEGIN
    BEGIN CALL pr_allocate_room(99, 2, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Unknown student: %', SQLERRM; END;
    BEGIN CALL pr_allocate_room(6, 99, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Unknown room: %', SQLERRM; END;
    BEGIN CALL pr_allocate_room(1, 3, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Already active: %', SQLERRM; END;
    BEGIN CALL pr_allocate_room(6, 1, CURRENT_DATE);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Room full: %', SQLERRM; END;
    BEGIN INSERT INTO allocations (student_id, room_id, allocated_on, status) VALUES (6, 1, CURRENT_DATE, 'ACTIVE');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Direct insert into full room: %', SQLERRM; END;
    BEGIN INSERT INTO allocations (student_id, room_id, allocated_on, status) VALUES (1, 3, CURRENT_DATE, 'ACTIVE');
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Direct insert, second ACTIVE: %', SQLERRM; END;
    UPDATE allocations SET allocated_on = allocated_on WHERE allocation_id = 1;
    RAISE NOTICE 'Self-update accepted';
END $$;

CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id,
       r.room_number,
       r.capacity,
       COUNT(a.allocation_id)              AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy ORDER BY room_id;

CREATE INDEX idx_alloc_active_room ON allocations (room_id) WHERE status = 'ACTIVE';
ANALYZE allocations;

SET enable_seqscan = off;
EXPLAIN
SELECT allocation_id, student_id, allocated_on
FROM allocations
WHERE room_id = 1
  AND status = 'ACTIVE';
RESET enable_seqscan;

CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE, r.room_id, COUNT(a.allocation_id), r.capacity - COUNT(a.allocation_id)
    FROM rooms r
    LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
    GROUP BY r.room_id, r.capacity
    ON CONFLICT (snapshot_date, room_id)
    DO UPDATE SET occupied_beds = EXCLUDED.occupied_beds, free_beds = EXCLUDED.free_beds;
END;
$$;

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();
SELECT * FROM occupancy_snapshot ORDER BY room_id;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q5_refresh_occupancy',
    '55 23 * * *',
    $cron$CALL q5_hostel.pr_refresh_occupancy()$cron$
);
