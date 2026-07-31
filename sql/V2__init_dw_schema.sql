-- ============================================================================
-- File: V2__init_dw_schema.sql
-- Description: Khởi tạo Data Warehouse Schema (Star Schema) phục vụ Power BI
-- System: PostgreSQL 12+
-- ============================================================================

CREATE SCHEMA IF NOT EXISTS dw;

-- ============================================================================
-- 1. DIMENSION TABLES
-- ============================================================================

-- 1.1 DIM_DATE (Trục thời gian chuẩn cho Power BI Time Intelligence)
CREATE TABLE IF NOT EXISTS dw.dim_date (
    date_key            INT PRIMARY KEY,          -- Format: YYYYMMDD (VD: 20260731)
    full_date           DATE NOT NULL,            -- 2026-07-31
    year                INT NOT NULL,             -- 2026
    quarter             INT NOT NULL,             -- 3
    quarter_name        VARCHAR(10) NOT NULL,     -- 'Q3'
    month               INT NOT NULL,             -- 7
    month_name          VARCHAR(20) NOT NULL,     -- 'July'
    month_year          VARCHAR(10) NOT NULL,     -- '07-2026'
    week_of_year        INT NOT NULL,             -- 31
    day_of_month        INT NOT NULL,             -- 31
    day_of_week         INT NOT NULL,             -- 6 (Thứ Bảy trong ISO hoặc 5 tùy config)
    day_name            VARCHAR(20) NOT NULL,     -- 'Friday'
    is_weekend          BOOLEAN NOT NULL,         -- FALSE
    is_holiday          BOOLEAN DEFAULT FALSE     -- FALSE
);

CREATE UNIQUE INDEX idx_dw_dim_date_full ON dw.dim_date(full_date);


-- 1.2 DIM_MACHINE (Hỗ trợ Drill-down: Plant -> Workshop -> Line -> Machine)
CREATE TABLE IF NOT EXISTS dw.dim_machine (
    machine_key         SERIAL PRIMARY KEY,
    machine_code        VARCHAR(50) UNIQUE NOT NULL, -- 'INJ-001'
    machine_name        VARCHAR(100) NOT NULL,        -- 'Máy Ép Phun 500T-A'
    line_name           VARCHAR(50) NOT NULL,         -- 'Line Sole A'
    workshop_name       VARCHAR(50) NOT NULL,         -- 'Xưởng Ép Nhựa (Injection Dept)'
    plant_name          VARCHAR(50) NOT NULL DEFAULT 'Framas BD1',
    is_active           BOOLEAN DEFAULT TRUE
);


-- 1.3 DIM_PRODUCT (Thông tin SKU & Định mức)
CREATE TABLE IF NOT EXISTS dw.dim_product (
    product_key         SERIAL PRIMARY KEY,
    product_code        VARCHAR(50) UNIQUE NOT NULL, -- 'SKU-OUTSOLE-V1'
    product_name        VARCHAR(100) NOT NULL,        -- 'Đế Ngoài Nike Air Zoom'
    category            VARCHAR(50),                  -- 'Outsole'
    customer_name       VARCHAR(50),                  -- 'Nike'
    default_cavities    INT NOT NULL DEFAULT 1,
    ideal_cycle_time_sec NUMERIC(8, 2) NOT NULL       -- Định mức lý thuyết chuẩn
);


-- 1.4 DIM_DOWNTIME_REASON (Từ điển mã lỗi dừng máy cho Pareto Chart)
CREATE TABLE IF NOT EXISTS dw.dim_downtime_reason (
    reason_key          SERIAL PRIMARY KEY,
    reason_code         VARCHAR(50) UNIQUE NOT NULL, -- 'BREAKDOWN_MECH'
    reason_name         VARCHAR(100) NOT NULL,       -- 'Sự cố cơ khí'
    category            VARCHAR(50) NOT NULL,        -- 'Unplanned Maintenance', 'Setup', 'External'
    is_planned          BOOLEAN NOT NULL             -- TRUE / FALSE
);


-- 1.5 DIM_SCRAP_REASON (Từ điển mã lỗi phế phẩm cho Pareto Chart)
CREATE TABLE IF NOT EXISTS dw.dim_scrap_reason (
    scrap_reason_key    SERIAL PRIMARY KEY,
    scrap_reason_code   VARCHAR(50) UNIQUE NOT NULL, -- 'FLASH'
    scrap_reason_name   VARCHAR(100) NOT NULL,       -- 'Lỗi Bavia (Bọt nhựa tràn)'
    category            VARCHAR(50) NOT NULL         -- 'Mold Defect', 'Material Defect', 'Process Defect'
);


-- ============================================================================
-- 2. FACT TABLE (FACT_OEE_SUMMARY)
-- ============================================================================

CREATE TABLE IF NOT EXISTS dw.fact_oee_summary (
    fact_id             BIGSERIAL PRIMARY KEY,

    -- Foreign Keys (Dimension Keys)
    date_key            INT NOT NULL,
    machine_key         INT NOT NULL,
    product_key         INT NOT NULL,

    -- Degenerate Dimensions / Operational Context
    shift_type          VARCHAR(10) NOT NULL,        -- 'SHIFT_1', 'SHIFT_2', 'SHIFT_3'
    shift_log_id        BIGINT NOT NULL,             -- Traceability ngược về STG

    -- Time Measures (tính bằng Giây)
    planned_production_time_sec NUMERIC(10, 2) NOT NULL DEFAULT 0,
    operating_time_sec          NUMERIC(10, 2) NOT NULL DEFAULT 0,
    planned_downtime_sec        NUMERIC(10, 2) NOT NULL DEFAULT 0,
    unplanned_downtime_sec      NUMERIC(10, 2) NOT NULL DEFAULT 0,

    -- Production & Quality Quantity Measures (Đơn vị: Sản phẩm / Nhịp)
    total_strokes               INT NOT NULL DEFAULT 0,
    total_pieces                INT NOT NULL DEFAULT 0, -- total_strokes * cavities
    good_pieces                 INT NOT NULL DEFAULT 0,
    scrap_pieces                INT NOT NULL DEFAULT 0,

    -- Performance Standard Metric
    ideal_cycle_time_sec        NUMERIC(8, 2) NOT NULL,

    -- Pre-calculated OEE Percentages (Range: 0.0000 - 1.0000)
    availability_pct            NUMERIC(6, 4) DEFAULT 0,
    performance_pct             NUMERIC(6, 4) DEFAULT 0,
    quality_pct                 NUMERIC(6, 4) DEFAULT 0,
    oee_pct                     NUMERIC(6, 4) DEFAULT 0,

    created_at                  TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,

    -- Constraints & Foreign Key References
    CONSTRAINT uq_fact_oee_grain UNIQUE (date_key, machine_key, product_key, shift_type),
    CONSTRAINT fk_fact_date FOREIGN KEY (date_key) REFERENCES dw.dim_date (date_key),
    CONSTRAINT fk_fact_machine FOREIGN KEY (machine_key) REFERENCES dw.dim_machine (machine_key),
    CONSTRAINT fk_fact_product FOREIGN KEY (product_key) REFERENCES dw.dim_product (product_key),
    CONSTRAINT chk_shift_type_dw CHECK (shift_type IN ('SHIFT_1', 'SHIFT_2', 'SHIFT_3'))
);

-- Index tối ưu truy vấn aggregation từ Power BI
-- (Không tạo lại index trùng với UNIQUE constraint uq_fact_oee_grain ở trên,
--  vì PostgreSQL đã tự động tạo unique index cho đúng 4 cột date_key/machine_key/
--  product_key/shift_type. Nếu cần thêm index cho pattern truy vấn khác
--  (ví dụ chỉ theo machine_key, date_key) thì khai báo riêng ở đây.