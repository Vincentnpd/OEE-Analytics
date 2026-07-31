-- ============================================================================
-- File: V3__create_views.sql
-- Description: Lớp ELT Transformation - Biến đổi Event Logs thành Fact OEE Summary
-- System: PostgreSQL 12+
-- ============================================================================

-- ============================================================================
-- 1. STAGING AGGREGATION VIEWS (Gom nhóm sự kiện theo Shift + Machine + Product)
-- ============================================================================

-- 1.1 Tổng hợp Downtime theo ca (Planned vs Unplanned)
CREATE OR REPLACE VIEW stg.vw_downtime_summary AS
SELECT 
    shift_log_id,
    COALESCE(SUM(EXTRACT(EPOCH FROM (end_time - start_time))) FILTER (WHERE is_planned = TRUE), 0) AS planned_downtime_sec,
    COALESCE(SUM(EXTRACT(EPOCH FROM (end_time - start_time))) FILTER (WHERE is_planned = FALSE), 0) AS unplanned_downtime_sec
FROM stg.downtime_events
GROUP BY shift_log_id;


-- 1.2 Tổng hợp Production Log
CREATE OR REPLACE VIEW stg.vw_production_summary AS
SELECT 
    shift_log_id,
    product_code,
    MAX(ideal_cycle_time_sec) AS ideal_cycle_time_sec,
    MAX(cavities) AS cavities,
    SUM(total_strokes) AS total_strokes,
    SUM(total_strokes * cavities) AS total_pieces
FROM stg.production_log
GROUP BY shift_log_id, product_code;


-- 1.3 Tổng hợp Quality Log
CREATE OR REPLACE VIEW stg.vw_quality_summary AS
SELECT 
    shift_log_id,
    product_code,
    SUM(good_pieces) AS good_pieces,
    SUM(scrap_pieces) AS scrap_pieces
FROM stg.quality_log
GROUP BY shift_log_id, product_code;


-- ============================================================================
-- 2. MAIN ELT TRANSFORMED VIEW (Ghép nối & Tính toán OEE Metrics)
-- ============================================================================

CREATE OR REPLACE VIEW dw.vw_stg_oee_transformed AS
WITH shift_base AS (
    SELECT 
        s.shift_log_id,
        s.shift_date,
        CAST(TO_CHAR(s.shift_date, 'YYYYMMDD') AS INT) AS date_key,
        m.machine_key,
        s.shift_type,
        EXTRACT(EPOCH FROM (s.shift_end_time - s.shift_start_time)) AS shift_duration_sec
    FROM stg.shift_log s
    JOIN dw.dim_machine m ON s.machine_code = m.machine_code
),
metrics_joined AS (
    SELECT 
        sb.date_key,
        sb.machine_key,
        p_dim.product_key,
        sb.shift_type,
        sb.shift_log_id,
        
        -- Time Metrics
        (sb.shift_duration_sec - COALESCE(dt.planned_downtime_sec, 0)) AS planned_production_time_sec,
        GREATEST(0, (sb.shift_duration_sec - COALESCE(dt.planned_downtime_sec, 0) - COALESCE(dt.unplanned_downtime_sec, 0))) AS operating_time_sec,
        COALESCE(dt.planned_downtime_sec, 0) AS planned_downtime_sec,
        COALESCE(dt.unplanned_downtime_sec, 0) AS unplanned_downtime_sec,
        
        -- Production & Quality Quantities
        COALESCE(p.total_strokes, 0) AS total_strokes,
        COALESCE(p.total_pieces, 0) AS total_pieces,
        COALESCE(q.good_pieces, 0) AS good_pieces,
        COALESCE(q.scrap_pieces, 0) AS scrap_pieces,
        COALESCE(p.ideal_cycle_time_sec, p_dim.ideal_cycle_time_sec) AS ideal_cycle_time_sec

    FROM shift_base sb
    -- Join với Production Summary
    JOIN stg.vw_production_summary p ON sb.shift_log_id = p.shift_log_id
    JOIN dw.dim_product p_dim ON p.product_code = p_dim.product_code
    
    -- Left Join Downtime Summary
    LEFT JOIN stg.vw_downtime_summary dt ON sb.shift_log_id = dt.shift_log_id
    
    -- Composite Join chuẩn với Quality Summary (shift_log_id + product_code)
    LEFT JOIN stg.vw_quality_summary q 
        ON p.shift_log_id = q.shift_log_id 
       AND p.product_code = q.product_code
)
SELECT 
    date_key,
    machine_key,
    product_key,
    shift_type,
    shift_log_id,
    
    planned_production_time_sec,
    operating_time_sec,
    planned_downtime_sec,
    unplanned_downtime_sec,
    
    total_strokes,
    total_pieces,
    good_pieces,
    scrap_pieces,
    ideal_cycle_time_sec,

    -- 1. AVAILABILITY = Operating Time / Planned Production Time
    CASE 
        WHEN planned_production_time_sec > 0 
        THEN ROUND(CAST(operating_time_sec / planned_production_time_sec AS NUMERIC), 4)
        ELSE 0 
    END AS availability_pct,

    -- 2. PERFORMANCE = (Total Pieces * Ideal Cycle Time) / Operating Time
    CASE 
        WHEN operating_time_sec > 0 
        THEN LEAST(1.0000, ROUND(CAST((total_pieces * ideal_cycle_time_sec) / operating_time_sec AS NUMERIC), 4))
        ELSE 0 
    END AS performance_pct,

    -- 3. QUALITY = Good Pieces / Total Pieces
    CASE 
        WHEN (good_pieces + scrap_pieces) > 0 
        THEN ROUND(CAST(good_pieces::NUMERIC / (good_pieces + scrap_pieces) AS NUMERIC), 4)
        ELSE 0 
    END AS quality_pct,

    -- 4. OVERALL OEE = Availability * Performance * Quality
    ROUND(
        CAST(
            (CASE WHEN planned_production_time_sec > 0 THEN operating_time_sec / planned_production_time_sec ELSE 0 END) *
            (CASE WHEN operating_time_sec > 0 THEN LEAST(1.0000, (total_pieces * ideal_cycle_time_sec) / operating_time_sec) ELSE 0 END) *
            (CASE WHEN (good_pieces + scrap_pieces) > 0 THEN good_pieces::NUMERIC / (good_pieces + scrap_pieces) ELSE 0 END)
        AS NUMERIC), 
    4) AS oee_pct

FROM metrics_joined;


-- ============================================================================
-- 3. ETL PROCEDURE (Populate Data to Physical Fact Table)
-- ============================================================================

CREATE OR REPLACE PROCEDURE dw.sp_populate_fact_oee()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO dw.fact_oee_summary (
        date_key,
        machine_key,
        product_key,
        shift_type,
        shift_log_id,
        planned_production_time_sec,
        operating_time_sec,
        planned_downtime_sec,
        unplanned_downtime_sec,
        total_strokes,
        total_pieces,
        good_pieces,
        scrap_pieces,
        ideal_cycle_time_sec,
        availability_pct,
        performance_pct,
        quality_pct,
        oee_pct
    )
    SELECT 
        date_key,
        machine_key,
        product_key,
        shift_type,
        shift_log_id,
        planned_production_time_sec,
        operating_time_sec,
        planned_downtime_sec,
        unplanned_downtime_sec,
        total_strokes,
        total_pieces,
        good_pieces,
        scrap_pieces,
        ideal_cycle_time_sec,
        availability_pct,
        performance_pct,
        quality_pct,
        oee_pct
    FROM dw.vw_stg_oee_transformed
    
    -- Cơ chế Idempotent: Cập nhật nếu dòng dữ liệu đã tồn tại
    ON CONFLICT (date_key, machine_key, product_key, shift_type) 
    DO UPDATE SET 
        planned_production_time_sec = EXCLUDED.planned_production_time_sec,
        operating_time_sec          = EXCLUDED.operating_time_sec,
        planned_downtime_sec        = EXCLUDED.planned_downtime_sec,
        unplanned_downtime_sec      = EXCLUDED.unplanned_downtime_sec,
        total_strokes               = EXCLUDED.total_strokes,
        total_pieces                = EXCLUDED.total_pieces,
        good_pieces                 = EXCLUDED.good_pieces,
        scrap_pieces                = EXCLUDED.scrap_pieces,
        ideal_cycle_time_sec        = EXCLUDED.ideal_cycle_time_sec,
        availability_pct            = EXCLUDED.availability_pct,
        performance_pct             = EXCLUDED.performance_pct,
        quality_pct                 = EXCLUDED.quality_pct,
        oee_pct                     = EXCLUDED.oee_pct,
        created_at                  = CURRENT_TIMESTAMP;

    RAISE NOTICE '✅ Successfully populated/updated dw.fact_oee_summary!';
END;
$$;