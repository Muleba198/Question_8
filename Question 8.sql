DROP VIEW IF EXISTS v_service_due CASCADE;
DROP TABLE IF EXISTS service_alerts, trips, vehicles CASCADE;

-- (a) Tables
CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          VARCHAR(30) NOT NULL UNIQUE,
    current_odometer      NUMERIC(12, 2) NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer NUMERIC(12, 2) NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT chk_vehicle_odometer_order CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE NOT NULL,
    start_odometer NUMERIC(12, 2) NOT NULL CHECK (start_odometer >= 0),
    end_odometer   NUMERIC(12, 2) NOT NULL CHECK (end_odometer > start_odometer)
);

CREATE TABLE service_alerts (
    vehicle_id       INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service NUMERIC(12, 2) NOT NULL CHECK (km_since_service >= 5000),
    flagged_on       DATE NOT NULL DEFAULT CURRENT_DATE
);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_curr NUMERIC(12, 2);
    v_last NUMERIC(12, 2);
BEGIN
    SELECT current_odometer, last_service_odometer
    INTO v_curr, v_last
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    RETURN (v_curr - v_last) >= 5000;
END;
$$;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INTEGER,
    p_trip_on    DATE,
    p_start      NUMERIC(12, 2),
    p_end        NUMERIC(12, 2)
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    IF p_end IS NULL OR p_start IS NULL OR p_end <= p_start THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION fn_trip_before_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_curr_odo NUMERIC(12, 2);
BEGIN
    IF NEW.end_odometer <= NEW.start_odometer OR NEW.start_odometer < 0 THEN
        RAISE EXCEPTION 'Invalid trip mileage: start %, end %', NEW.start_odometer, NEW.end_odometer;
    END IF;

    SELECT current_odometer INTO v_curr_odo
    FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;

    IF NEW.start_odometer <> v_curr_odo THEN
        RAISE EXCEPTION 'start_odometer (%) does not match current_odometer (%)',
            NEW.start_odometer, v_curr_odo;
    END IF;

    UPDATE vehicles
    SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trips_before_insert
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION fn_trip_before_insert();

-- (a) Seed Vehicles & Load 6 Trips via Procedure
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('GRZ 101A', 15200.00, 10000.00),
    ('GRZ 202B',  8200.00,  7000.00),
    ('GRZ 303C', 20000.00, 20000.00);

CALL pr_record_trip(1, '2026-11-20', 15200.00, 15450.00);
CALL pr_record_trip(1, '2026-11-22', 15450.00, 15700.00);
CALL pr_record_trip(2, '2026-11-21',  8200.00,  8500.00);
CALL pr_record_trip(2, '2026-11-23',  8500.00,  8900.00);
CALL pr_record_trip(3, '2026-11-22', 20000.00, 20300.00);
CALL pr_record_trip(3, '2026-11-24', 20300.00, 20600.00);

-- (e) View
CREATE OR REPLACE VIEW v_service_due AS
SELECT
    registration,
    (current_odometer - last_service_odometer) AS km_since_service
FROM vehicles
WHERE (current_odometer - last_service_odometer) >= 5000;

SELECT * FROM v_service_due;

-- (f) Index & EXPLAIN
CREATE INDEX idx_trips_vehicle_trip_on
ON trips (vehicle_id, trip_on);

EXPLAIN (ANALYZE, BUFFERS)
SELECT trip_id, vehicle_id, trip_on, start_odometer, end_odometer
FROM trips
WHERE vehicle_id = 1
  AND trip_on BETWEEN DATE '2026-11-01' AND DATE '2026-11-30';

-- (g) Refresh Procedure & Schedule
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT
        vehicle_id,
        (current_odometer - last_service_odometer),
        CURRENT_DATE
    FROM vehicles
    WHERE (current_odometer - last_service_odometer) >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
    SET km_since_service = EXCLUDED.km_since_service,
        flagged_on       = EXCLUDED.flagged_on;

    DELETE FROM service_alerts sa
    WHERE NOT EXISTS (
        SELECT 1
        FROM vehicles v
        WHERE v.vehicle_id = sa.vehicle_id
          AND (v.current_odometer - v.last_service_odometer) >= 5000
    );
END;
$$;

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;

