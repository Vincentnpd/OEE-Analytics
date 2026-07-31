-- ============================================================================
-- File: V3_1__add_pareto_facts.sql
-- Description: Bổ sung Event-Level Fact Tables cho Pareto Analysis (Downtime & Scrap)
-- System: PostgreSQL 12+
-- NOTE: Flyway yêu cầu tên file đúng format V{version}__{description}.sql
--       → đổi V3_1 thành V3_1 (dấu gạch dưới kép trước description)
-- ============================================================================

-- ============================================================================
-- 1. FACT TABLES PHỤ CHO PARETO ANALYSIS
-- ============================================================================

-- 1.1 Fact Downtime Events (Event-Level Grain: 1 row = 1 sự kiện dừng máy)
CREATE TABLE IF NOT EXISTS dw.fact_downtime_event (
    downtime_fact_id      BIGSERIAL PRIMARY KEY,
    date_key              INT          NOT NULL,
    machine_key           INT          NOT NULL,
    reason_key            INT          NOT NULL,
    shift_type            VARCHAR(10)  NOT NULL,
    downtime_duration_min NUMERIC(8,2) NOT NULL,
    is_planned            BOOLEAN      NOT NULL,

    CONSTRAINT fk_dt_date    FOREIGN KEY (date_key)    REFERENCES dw.dim_date             (date_key),
    CONSTRAINT fk_dt_machine FOREIGN KEY (machine_key) REFERENCES dw.dim_machine           (machine_key),
    CONSTRAINT fk_dt_reason  FOREIGN KEY (reason_key)  REFERENCES dw.dim_downtime_reason   (reason_key),
    CONSTRAINT chk_dt_shift  CHECK (shift_type IN ('SHIFT_1', 'SHIFT_2', 'SHIFT_3'))
);

CREATE INDEX IF NOT EXISTS idx_dt_event_lookup
    ON dw.fact_downtime_event (date_key, machine_key, reason_key);


-- 1.2 Fact Scrap Events (Event-Level Grain: 1 row = 1 quality_log entry có scrap)
CREATE TABLE IF NOT EXISTS dw.fact_scrap_event (
    scrap_fact_id      BIGSERIAL PRIMARY KEY,
    date_key           INT         NOT NULL,
    machine_key        INT         NOT NULL,
    product_key        INT         NOT NULL,
    scrap_reason_key   INT         NOT NULL,
    shift_type         VARCHAR(10) NOT NULL,
    scrap_pieces       INT         NOT NULL,

    CONSTRAINT fk_sc_date    FOREIGN KEY (date_key)         REFERENCES dw.dim_date         (date_key),
    CONSTRAINT fk_sc_machine FOREIGN KEY (machine_key)      REFERENCES dw.dim_machine       (machine_key),
    CONSTRAINT fk_sc_product FOREIGN KEY (product_key)      REFERENCES dw.dim_product       (product_key),
    CONSTRAINT fk_sc_reason  FOREIGN KEY (scrap_reason_key) REFERENCES dw.dim_scrap_reason  (scrap_reason_key),
    CONSTRAINT chk_sc_shift  CHECK (shift_type IN ('SHIFT_1', 'SHIFT_2', 'SHIFT_3')),
    CONSTRAINT chk_sc_pieces CHECK (scrap_pieces > 0)       -- chỉ ghi khi có phế phẩm thực sự
);

CREATE INDEX IF NOT EXISTS idx_sc_event_lookup
    ON dw.fact_scrap_event (date_key, machine_key, scrap_reason_key);


-- ============================================================================
-- 2. STORED PROCEDURE NẠP DỮ LIỆU PARETO FACTS
-- ============================================================================
-- Lý do dùng TRUNCATE + INSERT thay vì Upsert (ON CONFLICT):
--   - fact_downtime_event & fact_scrap_event là Event-Level Facts: không có
--     Natural Business Key ở cấp độ từng dòng event (1 ca có thể hỏng cơ khí
--     3 lần → 3 rows cùng date_key + machine_key + reason_key).
--   - Không có Composite Unique Key → không thể viết ON CONFLICT clause.
--   - Giải pháp: Full Refresh (TRUNCATE + INSERT) được bọc trong 1 transaction
--     duy nhất → nếu INSERT fail giữa chừng, TRUNCATE sẽ tự động ROLLBACK,
--     bảng không bao giờ rơi vào trạng thái trống/thiếu data.
-- ============================================================================

CREATE OR REPLACE PROCEDURE dw.sp_populate_pareto_facts()
LANGUAGE plpgsql
AS $$
DECLARE
    v_dt_rows INT;
    v_sc_rows INT;
BEGIN
    -- ----------------------------------------------------------------
    -- Fact Downtime Event — Full Refresh
    -- ----------------------------------------------------------------
    TRUNCATE TABLE dw.fact_downtime_event;

    INSERT INTO dw.fact_downtime_event (
        date_key,
        machine_key,
        reason_key,
        shift_type,
        downtime_duration_min,
        is_planned
    )
    SELECT
        CAST(TO_CHAR(s.shift_date, 'YYYYMMDD') AS INT)                          AS date_key,
        m.machine_key,
        r.reason_key,
        s.shift_type,
        ROUND(
            CAST(EXTRACT(EPOCH FROM (d.end_time - d.start_time)) / 60.0 AS NUMERIC),
        2)                                                                       AS downtime_duration_min,
        d.is_planned
    FROM stg.downtime_events      d
    JOIN stg.shift_log            s ON d.shift_log_id        = s.shift_log_id
    JOIN dw.dim_machine           m ON s.machine_code        = m.machine_code
    JOIN dw.dim_downtime_reason   r ON d.downtime_reason_code = r.reason_code
    -- Chỉ ghi những event có duration > 0 để loại noise
    WHERE (d.end_time - d.start_time) > INTERVAL '0 seconds';

    GET DIAGNOSTICS v_dt_rows = ROW_COUNT;

    -- ----------------------------------------------------------------
    -- Fact Scrap Event — Full Refresh
    -- ----------------------------------------------------------------
    TRUNCATE TABLE dw.fact_scrap_event;

    INSERT INTO dw.fact_scrap_event (
        date_key,
        machine_key,
        product_key,
        scrap_reason_key,
        shift_type,
        scrap_pieces
    )
    SELECT
        CAST(TO_CHAR(s.shift_date, 'YYYYMMDD') AS INT)  AS date_key,
        m.machine_key,
        p.product_key,
        sr.scrap_reason_key,
        s.shift_type,
        q.scrap_pieces
    FROM stg.quality_log          q
    JOIN stg.shift_log            s  ON q.shift_log_id       = s.shift_log_id
    JOIN dw.dim_machine           m  ON s.machine_code       = m.machine_code
    JOIN dw.dim_product           p  ON q.product_code       = p.product_code
    JOIN dw.dim_scrap_reason      sr ON q.scrap_reason_code  = sr.scrap_reason_code
    WHERE q.scrap_pieces > 0;   -- constraint chk_sc_pieces cũng guard ở tầng bảng

    GET DIAGNOSTICS v_sc_rows = ROW_COUNT;

    RAISE NOTICE '✅ sp_populate_pareto_facts completed: % downtime rows | % scrap rows.',
        v_dt_rows, v_sc_rows;

    -- Nếu có exception, PostgreSQL tự ROLLBACK toàn bộ transaction (TRUNCATE + INSERT)
    -- → bảng không bao giờ ở trạng thái trống.
EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION '❌ sp_populate_pareto_facts FAILED: %. Transaction rolled back.', SQLERRM;
END;
$$;


-- ============================================================================
-- 3. MASTER ETL RUNNER — Gọi đúng thứ tự cho 1 lần refresh hoàn chỉnh
-- ============================================================================
-- Sử dụng:
--     CALL dw.sp_run_full_etl();
-- ============================================================================

CREATE OR REPLACE PROCEDURE dw.sp_run_full_etl()
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE NOTICE '▶ Step 1/2 — Populating fact_oee_summary (Upsert)...';
    CALL dw.sp_populate_fact_oee();

    RAISE NOTICE '▶ Step 2/2 — Populating Pareto Fact Tables (Full Refresh)...';
    CALL dw.sp_populate_pareto_facts();

    RAISE NOTICE '🎉 Full ETL pipeline completed successfully.';
END;
$$;