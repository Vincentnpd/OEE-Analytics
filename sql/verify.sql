-- 1. Row counts
SELECT 'shift_log' AS tbl, COUNT(*) FROM stg.shift_log
UNION ALL
SELECT 'downtime_events', COUNT(*) FROM stg.downtime_events
UNION ALL
SELECT 'production_log', COUNT(*) FROM stg.production_log
UNION ALL
SELECT 'quality_log', COUNT(*) FROM stg.quality_log;

-- 2. Sample OEE calculation check (1 shift)
SELECT 
    s.shift_log_id,
    s.machine_code,
    s.shift_type,
    s.shift_date,
    EXTRACT(EPOCH FROM (s.shift_end_time - s.shift_start_time)) AS shift_duration_sec,
    COALESCE(SUM(EXTRACT(EPOCH FROM (d.end_time - d.start_time))) FILTER (WHERE d.is_planned), 0) AS planned_dt_sec,
    COALESCE(SUM(EXTRACT(EPOCH FROM (d.end_time - d.start_time))) FILTER (WHERE NOT d.is_planned), 0) AS unplanned_dt_sec
FROM stg.shift_log s
LEFT JOIN stg.downtime_events d ON s.shift_log_id = d.shift_log_id
WHERE s.shift_log_id = 1
GROUP BY s.shift_log_id, s.machine_code, s.shift_type, s.shift_date, s.shift_start_time, s.shift_end_time;

-- 3. Check composite join integrity
SELECT COUNT(*) AS orphan_quality_rows
FROM stg.quality_log q
WHERE NOT EXISTS (
    SELECT 1 FROM stg.production_log p
    WHERE p.shift_log_id = q.shift_log_id
    AND p.product_code = q.product_code
);