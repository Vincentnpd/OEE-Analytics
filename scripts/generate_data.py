"""
============================================================================
File: scripts/generate_data.py
Description: Synthetic Data Generator cho hệ thống OEE Monitoring
             Bơm 6 tháng dữ liệu giả lập (6 máy, 3 ca/ngày) vào PostgreSQL
System: Python 3.9+ | psycopg2 | PostgreSQL 12+
============================================================================
"""

import os
import random
from datetime import datetime, timedelta

import psycopg2
from psycopg2.extras import execute_values


# ============================================================================
# CONFIGURATION & DB CONNECTION
# ============================================================================

from dotenv import load_dotenv
load_dotenv()

DB_CONFIG = {
    "dbname":   os.environ.get("POSTGRES_DB",       "oee_db"),
    "user":     os.environ.get("POSTGRES_USER",     "oee_admin"),
    "password": os.environ.get("POSTGRES_PASSWORD", ""),
    "host":     os.environ.get("POSTGRES_HOST",     "localhost"),
    "port":     os.environ.get("POSTGRES_PORT",     "5433"),
}

START_DATE = datetime(2026, 2, 1)
END_DATE   = datetime(2026, 7, 31)


# ============================================================================
# MASTER DATA DEFINITIONS
# ============================================================================

MACHINES = [
    # Group A — High Performers (Target OEE ~83% -> Availability ~89%)
    {"code": "MCH-001", "name": "Máy Ép Phun 500T-A", "line": "Line Sole A",  "dept": "Xưởng Ép Nhựa A", "type": "HIGH"},
    {"code": "MCH-002", "name": "Máy Ép Phun 500T-B", "line": "Line Sole A",  "dept": "Xưởng Ép Nhựa A", "type": "HIGH"},
    # Group B — Average / Stable (Target OEE ~68% -> Availability ~74%)
    {"code": "MCH-003", "name": "Máy Ép Phun 350T-A", "line": "Line Sole B",  "dept": "Xưởng Ép Nhựa A", "type": "MID"},
    {"code": "MCH-004", "name": "Máy Ép Phun 350T-B", "line": "Line Sole B",  "dept": "Xưởng Ép Nhựa A", "type": "MID"},
    # Group C — Problematic / Bottleneck (Target OEE ~50% -> Availability ~55%)
    {"code": "MCH-005", "name": "Máy Ép Phun 250T-A", "line": "Line Upper C", "dept": "Xưởng Ép Nhựa B", "type": "PROB_AVAIL"},  # Hỏng cơ khí liên tục
    {"code": "MCH-006", "name": "Máy Ép Phun 250T-B", "line": "Line Upper C", "dept": "Xưởng Ép Nhựa B", "type": "PROB_QUAL"},   # Chạy chậm + phế phẩm cao
]

PRODUCTS = [
    {"code": "SKU-OUTSOLE-NIKE",  "name": "Đế Ngoài Nike Air Zoom",      "cavities": 2, "cycle_time": 12.0},
    {"code": "SKU-MIDSOLE-PUMA",  "name": "Đế Giữa Puma Nitro",          "cavities": 1, "cycle_time": 18.0},
    {"code": "SKU-HEEL-ADIDAS",   "name": "Gót Nhựa Adidas Ultraboost",  "cavities": 4, "cycle_time":  8.5},
]

DOWNTIME_REASONS = [
    # is_planned=False — Unplanned
    {"code": "BREAKDOWN_MECH", "name": "Sự cố cơ khí / kẹt khuôn",    "cat": "Unplanned",    "is_planned": False, "weight": 40},
    {"code": "CHANGE_MOLD",    "name": "Thay khuôn & Setup",           "cat": "Setup",        "is_planned": False, "weight": 25},
    {"code": "WAIT_MATERIAL",  "name": "Chờ hạt nhựa TPU/PA",          "cat": "Supply Chain", "is_planned": False, "weight": 20},
    {"code": "BREAKDOWN_ELEC", "name": "Sự cố cảm biến / điện",        "cat": "Unplanned",    "is_planned": False, "weight": 10},
    # is_planned=True — Planned
    {"code": "LUNCH_BREAK",    "name": "Nghỉ trưa / Ăn giữa ca",       "cat": "Planned",      "is_planned": True,  "weight":  5},
]

SCRAP_REASONS = [
    {"code": "FLASH",       "name": "Lỗi Bavia (Bọt nhựa tràn)",       "cat": "Mold Defect",    "weight": 60},
    {"code": "SHORT_SHOT",  "name": "Thiếu liệu / Chưa điền đầy",      "cat": "Process Defect", "weight": 25},
    {"code": "WARPAGE",     "name": "Cong vênh sản phẩm",              "cat": "Cooling Defect", "weight": 10},
    {"code": "BLACK_SPOT",  "name": "Vết thâm đen / Cháy nhựa",        "cat": "Material Defect","weight":  5},
]

SHIFTS = [
    ("SHIFT_1",  6, 14),   # 06:00–14:00
    ("SHIFT_2", 14, 22),   # 14:00–22:00
    ("SHIFT_3", 22,  6),   # 22:00–06:00 (hôm sau)
]


# ============================================================================
# DIMENSION SEEDING
# ============================================================================

def seed_dimensions(cursor):
    """Bơm Master Data vào toàn bộ bảng dw.dim_*"""
    print("🌱 Seeding DW Dimension tables...")

    # --- 1. dim_date ----------------------------------------------------------
    dates_data = []
    curr = START_DATE
    while curr <= END_DATE:
        date_key = int(curr.strftime("%Y%m%d"))
        quarter  = (curr.month - 1) // 3 + 1
        dates_data.append((
            date_key,
            curr.date(),
            curr.year,
            quarter,
            f"Q{quarter}",
            curr.month,
            curr.strftime("%B"),          # 'February'
            curr.strftime("%m-%Y"),       # '02-2026'
            curr.isocalendar()[1],        # week_of_year
            curr.day,
            curr.weekday() + 1,           # ISO: Mon=1 … Sun=7
            curr.strftime("%A"),          # 'Monday'
            curr.weekday() >= 5,          # is_weekend
        ))
        curr += timedelta(days=1)

    execute_values(cursor, """
        INSERT INTO dw.dim_date (
            date_key, full_date, year, quarter, quarter_name,
            month, month_name, month_year, week_of_year,
            day_of_month, day_of_week, day_name, is_weekend
        ) VALUES %s
        ON CONFLICT (date_key) DO NOTHING;
    """, dates_data)
    print(f"   ✔ dim_date: {len(dates_data)} rows")

    # --- 2. dim_machine -------------------------------------------------------
    for m in MACHINES:
        cursor.execute("""
            INSERT INTO dw.dim_machine (machine_code, machine_name, line_name, workshop_name)
            VALUES (%s, %s, %s, %s)
            ON CONFLICT (machine_code) DO NOTHING;
        """, (m["code"], m["name"], m["line"], m["dept"]))
    print(f"   ✔ dim_machine: {len(MACHINES)} rows")

    # --- 3. dim_product -------------------------------------------------------
    for p in PRODUCTS:
        cursor.execute("""
            INSERT INTO dw.dim_product (product_code, product_name, default_cavities, ideal_cycle_time_sec)
            VALUES (%s, %s, %s, %s)
            ON CONFLICT (product_code) DO NOTHING;
        """, (p["code"], p["name"], p["cavities"], p["cycle_time"]))
    print(f"   ✔ dim_product: {len(PRODUCTS)} rows")

    # --- 4. dim_downtime_reason -----------------------------------------------
    for r in DOWNTIME_REASONS:
        cursor.execute("""
            INSERT INTO dw.dim_downtime_reason (reason_code, reason_name, category, is_planned)
            VALUES (%s, %s, %s, %s)
            ON CONFLICT (reason_code) DO NOTHING;
        """, (r["code"], r["name"], r["cat"], r["is_planned"]))
    print(f"   ✔ dim_downtime_reason: {len(DOWNTIME_REASONS)} rows")

    # --- 5. dim_scrap_reason --------------------------------------------------
    for s in SCRAP_REASONS:
        cursor.execute("""
            INSERT INTO dw.dim_scrap_reason (scrap_reason_code, scrap_reason_name, category)
            VALUES (%s, %s, %s)
            ON CONFLICT (scrap_reason_code) DO NOTHING;
        """, (s["code"], s["name"], s["cat"]))
    print(f"   ✔ dim_scrap_reason: {len(SCRAP_REASONS)} rows")


# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

def _unplanned_minutes(machine_type: str, month: int, month_factor: float) -> int:
    """
    Tính số phút dừng máy ngoài kế hoạch dựa trên:
    - Loại máy (personality): Đã cập nhật ranges chuẩn hóa Realistic Availability
    - Tháng trong năm (cải tiến dần theo thời gian)
    - month_factor: hệ số tăng trưởng cải tiến (TPM / Kaizen)
    """
    if machine_type == "HIGH":
        # Target Availability ~89% -> Unplanned ~50 phút/ca
        raw = random.randint(30, 70)
    elif machine_type == "MID":
        # Target Availability ~74% -> Unplanned ~117 phút/ca
        raw = random.randint(90, 145)
    elif machine_type == "PROB_AVAIL":
        # Máy lỗi hỏng nặng trước khi cải tiến (tháng 2-3)
        if month <= 3:
            raw = random.randint(180, 240)  # ~200 phút/ca
        else:
            raw = random.randint(120, 180)  # Cải tiến sau đại tu
    else:  # PROB_QUAL
        # Target Availability ~55% -> Unplanned ~200 phút/ca
        raw = random.randint(160, 240)

    # Cải tiến OEE giảm dần số phút downtime theo tháng
    return int(max(10, raw / month_factor))


def _pick_downtime_reason(is_planned: bool) -> str:
    pool    = [r for r in DOWNTIME_REASONS if r["is_planned"] == is_planned]
    codes   = [r["code"]   for r in pool]
    weights = [r["weight"] for r in pool]
    return random.choices(codes, weights=weights)[0]


def _pick_scrap_reason() -> str:
    codes   = [s["code"]   for s in SCRAP_REASONS]
    weights = [s["weight"] for s in SCRAP_REASONS]
    return random.choices(codes, weights=weights)[0]


# ============================================================================
# STAGING EVENT LOG GENERATION
# ============================================================================

def generate_event_logs(conn):
    cursor = conn.cursor()

    # Seed dimensions trước
    seed_dimensions(cursor)
    conn.commit()

    print("\n🚀 Generating Staging Event Logs (6 months)...")

    total_shifts = 0
    curr_date = START_DATE

    while curr_date <= END_DATE:

        months_elapsed         = curr_date.month - 2          # 0 ở T2, 5 ở T7
        avail_improve_factor   = 1.0 + months_elapsed * 0.05  # Availability driver
        quality_improve_factor = 1.0 + months_elapsed * 0.03  # Quality driver

        for m in MACHINES:
            for shift_code, start_h, end_h in SHIFTS:

                # ------ Mốc thời gian ca -----
                s_start = curr_date.replace(hour=start_h, minute=0, second=0, microsecond=0)
                if shift_code == "SHIFT_3":
                    s_end = (curr_date + timedelta(days=1)).replace(
                        hour=end_h, minute=0, second=0, microsecond=0
                    )
                else:
                    s_end = curr_date.replace(hour=end_h, minute=0, second=0, microsecond=0)

                # ------ 1. SHIFT LOG -----
                cursor.execute("""
                    INSERT INTO stg.shift_log
                        (shift_date, shift_type, machine_code, shift_start_time, shift_end_time, operator_id)
                    VALUES (%s, %s, %s, %s, %s, %s)
                    RETURNING shift_log_id;
                """, (
                    curr_date.date(),
                    shift_code,
                    m["code"],
                    s_start,
                    s_end,
                    f"OP-{(hash(m['code']) % 50) + 100}",
                ))
                shift_log_id = cursor.fetchone()[0]

                # ------ 2. DOWNTIME EVENTS -----

                # Nghỉ trưa cố định 30 phút (giữa ca)
                lunch_start = s_start + timedelta(hours=4)
                cursor.execute("""
                    INSERT INTO stg.downtime_events
                        (shift_log_id, start_time, end_time, is_planned, downtime_reason_code, remarks)
                    VALUES (%s, %s, %s, %s, %s, %s);
                """, (
                    shift_log_id,
                    lunch_start,
                    lunch_start + timedelta(minutes=30),
                    True,
                    "LUNCH_BREAK",
                    "Nghỉ giữa ca",
                ))

                # Dừng máy ngoài kế hoạch (dùng avail_improve_factor)
                unplanned_mins = _unplanned_minutes(m["type"], curr_date.month, avail_improve_factor)
                dt_start = s_start + timedelta(hours=1, minutes=random.randint(0, 30))
                dt_end   = dt_start + timedelta(minutes=unplanned_mins)
                cursor.execute("""
                    INSERT INTO stg.downtime_events
                        (shift_log_id, start_time, end_time, is_planned, downtime_reason_code)
                    VALUES (%s, %s, %s, %s, %s);
                """, (
                    shift_log_id,
                    dt_start,
                    dt_end,
                    False,
                    _pick_downtime_reason(is_planned=False),
                ))

                # ------ 3. PRODUCTION LOG -----
                prod = random.choice(PRODUCTS)

                # MCH-006: chạy chậm hơn 25% do máy cũ
                speed_penalty   = 1.25 if m["type"] == "PROB_QUAL" else 1.02
                actual_cycle    = prod["cycle_time"] * speed_penalty

                shift_duration_sec     = (s_end - s_start).total_seconds()
                planned_downtime_sec   = 30 * 60          # lunch 30p
                unplanned_downtime_sec = unplanned_mins * 60
                operating_sec = max(0,
                    shift_duration_sec - planned_downtime_sec - unplanned_downtime_sec
                )
                total_strokes = int(operating_sec / actual_cycle)

                cursor.execute("""
                    INSERT INTO stg.production_log
                        (shift_log_id, product_code, ideal_cycle_time_sec,
                         cavities, total_strokes, start_time, end_time)
                    VALUES (%s, %s, %s, %s, %s, %s, %s);
                """, (
                    shift_log_id,
                    prod["code"],
                    prod["cycle_time"],
                    prod["cavities"],
                    total_strokes,
                    s_start,
                    s_end,
                ))

                # ------ 4. QUALITY LOG -----
                total_pieces = total_strokes * prod["cavities"]

                if m["type"] == "PROB_QUAL":
                    base_scrap_rate = 0.085   # 8.5%
                elif m["type"] == "HIGH":
                    base_scrap_rate = 0.010   # 1.0%
                else:
                    base_scrap_rate = 0.025   # 2.5%

                scrap_rate = max(base_scrap_rate * 0.25, base_scrap_rate / quality_improve_factor)

                scrap_pieces = int(total_pieces * scrap_rate)
                good_pieces  = total_pieces - scrap_pieces

                cursor.execute("""
                    INSERT INTO stg.quality_log
                        (shift_log_id, product_code, good_pieces, scrap_pieces, scrap_reason_code)
                    VALUES (%s, %s, %s, %s, %s);
                """, (
                    shift_log_id,
                    prod["code"],
                    good_pieces,
                    scrap_pieces,
                    _pick_scrap_reason(),
                ))

                total_shifts += 1

        conn.commit()
        curr_date += timedelta(days=1)

    print(f"✅ Hoàn thành! Đã sinh {total_shifts:,} shift records.")
    print(f"   → {total_shifts * 4:,} rows tổng cộng (shift_log + downtime x2 + production + quality)")


# ============================================================================
# ENTRY POINT
# ============================================================================

if __name__ == "__main__":
    print("=" * 60)
    print("  OEE Synthetic Data Generator")
    print(f"  Period : {START_DATE.strftime('%d/%m/%Y')} → {END_DATE.strftime('%d/%m/%Y')}")
    print(f"  Machines: {len(MACHINES)} | Products: {len(PRODUCTS)} | Shifts/day: {len(SHIFTS)}")
    print("=" * 60)

    try:
        conn = psycopg2.connect(
            host=DB_CONFIG["host"],
            port=DB_CONFIG["port"],
            dbname=DB_CONFIG["dbname"],
            user=DB_CONFIG["user"],
            password=DB_CONFIG["password"]
        )
        conn.set_client_encoding('UTF8')
        generate_event_logs(conn)
        conn.close()
    except psycopg2.OperationalError as e:
        print(f"\n❌ Không kết nối được DB: {e}")
        print("   Kiểm tra lại biến môi trường POSTGRES_HOST / POSTGRES_USER / POSTGRES_PASSWORD")
    except Exception as e:
        print(f"\n❌ Lỗi không xác định: {e}")
        raise