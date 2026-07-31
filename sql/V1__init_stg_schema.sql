-- ============================================================================
-- File: V1__init_stg_schema.sql (FIXED)
-- Description: Khởi tạo Schema STG (Staging Event Logs) cho hệ thống OEE
-- System: PostgreSQL 12+
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS stg;

-- 1. Bảng SHIFT_LOG
CREATE TABLE IF NOT EXISTS stg.shift_log (
    shift_log_id        BIGSERIAL PRIMARY KEY,
    shift_date          DATE NOT NULL,
    shift_type          VARCHAR(10) NOT NULL, -- 'SHIFT_1', 'SHIFT_2', 'SHIFT_3'
    machine_code        VARCHAR(50) NOT NULL, -- 'MCH-001', 'INJ-002'
    shift_start_time    TIMESTAMPTZ NOT NULL,
    shift_end_time      TIMESTAMPTZ NOT NULL,
    operator_id         VARCHAR(50),
    created_at          TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT chk_shift_time CHECK (shift_end_time > shift_start_time),
    CONSTRAINT chk_shift_type CHECK (shift_type IN ('SHIFT_1', 'SHIFT_2', 'SHIFT_3'))
);

CREATE INDEX idx_stg_shift_log_lookup 
ON stg.shift_log (machine_code, shift_date, shift_start_time);


-- 2. Bảng DOWNTIME_EVENTS
CREATE TABLE IF NOT EXISTS stg.downtime_events (
    downtime_event_id   BIGSERIAL PRIMARY KEY,
    shift_log_id        BIGINT NOT NULL,
    start_time          TIMESTAMPTZ NOT NULL,
    end_time            TIMESTAMPTZ NOT NULL,
    is_planned          BOOLEAN NOT NULL,
    downtime_reason_code VARCHAR(50) NOT NULL,
    remarks             TEXT,
    created_at          TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT fk_downtime_shift 
        FOREIGN KEY (shift_log_id) 
        REFERENCES stg.shift_log (shift_log_id) 
        ON DELETE CASCADE,

    CONSTRAINT chk_downtime_time CHECK (end_time >= start_time)
);

CREATE INDEX idx_stg_downtime_shift_id ON stg.downtime_events(shift_log_id);


-- 3. Bảng PRODUCTION_LOG
CREATE TABLE IF NOT EXISTS stg.production_log (
    production_log_id   BIGSERIAL PRIMARY KEY,
    shift_log_id        BIGINT NOT NULL,
    product_code        VARCHAR(50) NOT NULL,  -- SKU Code
    ideal_cycle_time_sec NUMERIC(8, 2) NOT NULL, 
    cavities            INT NOT NULL DEFAULT 1,
    total_strokes       INT NOT NULL DEFAULT 0,
    start_time          TIMESTAMPTZ NOT NULL,
    end_time            TIMESTAMPTZ NOT NULL,
    created_at          TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT fk_production_shift 
        FOREIGN KEY (shift_log_id) 
        REFERENCES stg.shift_log (shift_log_id) 
        ON DELETE CASCADE,

    CONSTRAINT chk_strokes_positive CHECK (total_strokes >= 0),
    CONSTRAINT chk_cavities_positive CHECK (cavities > 0),
    CONSTRAINT chk_cycle_time_positive CHECK (ideal_cycle_time_sec > 0),
    CONSTRAINT chk_prod_time CHECK (end_time >= start_time)
);

-- Index tối ưu cho JOIN với Quality Log theo Composite Key (shift_log_id, product_code)
CREATE INDEX idx_stg_production_shift_prod 
ON stg.production_log(shift_log_id, product_code);


-- 4. Bảng QUALITY_LOG (FIXED: Đã thêm product_code)
CREATE TABLE IF NOT EXISTS stg.quality_log (
    quality_log_id      BIGSERIAL PRIMARY KEY,
    shift_log_id        BIGINT NOT NULL,
    product_code        VARCHAR(50) NOT NULL,  -- FIXED: Bổ sung product_code để map chính xác với production_log
    good_pieces         INT NOT NULL DEFAULT 0,
    scrap_pieces        INT NOT NULL DEFAULT 0,
    scrap_reason_code   VARCHAR(50),
    created_at          TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT fk_quality_shift 
        FOREIGN KEY (shift_log_id) 
        REFERENCES stg.shift_log (shift_log_id) 
        ON DELETE CASCADE,

    CONSTRAINT chk_good_pieces_positive CHECK (good_pieces >= 0),
    CONSTRAINT chk_scrap_pieces_positive CHECK (scrap_pieces >= 0)
);

-- Index tối ưu cho JOIN
CREATE INDEX idx_stg_quality_shift_prod 
ON stg.quality_log(shift_log_id, product_code);