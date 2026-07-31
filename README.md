# 🏭 Production Efficiency Monitor — OEE Analytics Platform

![PostgreSQL](https://img.shields.io/badge/PostgreSQL-15-316192?style=flat&logo=postgresql&logoColor=white)
![Python](https://img.shields.io/badge/Python-3.11-3776AB?style=flat&logo=python&logoColor=white)
![Power BI](https://img.shields.io/badge/Power%20BI-Dashboard-F2C811?style=flat&logo=powerbi&logoColor=black)
![Docker](https://img.shields.io/badge/Docker-Compose-2496ED?style=flat&logo=docker&logoColor=white)
![Flyway](https://img.shields.io/badge/Flyway-Migration-CC0200?style=flat&logo=flyway&logoColor=white)
![Git](https://img.shields.io/badge/Git-Version%20Control-F05032?style=flat&logo=git&logoColor=white)

> An end-to-end manufacturing analytics platform built on a real production domain (injection molding), demonstrating data warehouse design, ETL pipeline, and operational KPI reporting with Power BI.

---

## 📌 Business Problem

A mid-size injection molding facility running 6 machines across 3 shifts has no centralized visibility into production efficiency. Downtime is logged manually, scrap is tracked per shift in isolation, and management cannot identify which machines, shifts, or product types are dragging down overall OEE.

**This project answers 4 operational questions:**
1. What is the current OEE per machine, shift, and product — and how has it trended over 6 months?
2. Which downtime categories consume the most available production time?
3. Which scrap defect types drive the highest reject rate?
4. Where should maintenance and process improvement efforts be prioritized?

---

## 🔍 Key Insights (from 3,258 production shifts · Feb–Jul 2026)

### 1. OEE Gap Between Machine Tiers is 37 Points
| Machine | Avg OEE | Avg Availability | Tier |
|---|---|---|---|
| MCH-001 / MCH-002 | 88.8% | 90.2% | HIGH |
| MCH-003 / MCH-004 | 74.5% | 76.8% | MID |
| MCH-005 | 64.2% | 66.1% | PROBLEMATIC |
| MCH-006 | 51.6% | 60.4% | PROBLEMATIC |

**Availability is the dominant OEE driver** — Performance (~99%) and Quality (~97%) are consistent across all machines. The gap is entirely in uptime.

### 2. Two Downtime Categories Account for 67% of All Unplanned Losses
| Reason | Total Minutes | Share |
|---|---|---|
| Sự cố cơ khí / kẹt khuôn | 134,908 | 39.5% |
| Thay khuôn & Setup | 92,851 | 27.2% |
| Chờ hạt nhựa TPU/PA | 72,138 | 21.1% |
| Sự cố cảm biến / điện | 41,212 | 12.1% |

Mechanical failure and mold jam alone represent **39.5% of all downtime** — a clear signal for preventive maintenance prioritization on MCH-005 and MCH-006.

### 3. OEE Improved 7 Points Following TPM Initiative (Mar 2026)
| Month | Avg OEE |
|---|---|
| Feb 2026 | 69.5% |
| Mar 2026 | 71.0% |
| Apr 2026 | 74.1% |
| May 2026 | 75.2% |
| Jun 2026 | 75.8% |
| Jul 2026 | 76.5% |

Sustained upward trend post-maintenance event confirms TPM impact. Target 85% world-class OEE remains achievable with focused intervention on bottom-tier machines.

### 4. Flash Defect Drives 62.6% of All Scrap
| Defect Type | Scrap Pieces | Share |
|---|---|---|
| Lỗi Bavia (Flash) | 220,764 | 62.6% |
| Thiếu liệu (Short Shot) | 80,308 | 22.8% |
| Cong vênh (Warpage) | 29,848 | 8.5% |
| Vết thâm đen (Burn Mark) | 21,560 | 6.1% |

Flash and Short Shot together = **85.4% of scrap** — a classic Pareto signal pointing to mold clamping pressure and material temperature parameters.

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    POSTGRESQL DATABASE                      │
│                                                             │
│  ┌─────────────────────────┐     ┌───────────────────────┐  │
│  │      Schema: stg        │     │      Schema: dw       │  │
│  ├─────────────────────────┤     ├───────────────────────┤  │
│  │ · shift_log             │ ETL │ · dim_date            │  │
│  │ · downtime_events       ├────►│ · dim_machine         │  │
│  │ · production_log        │     │ · dim_product         │  │
│  │ · quality_log           │     │ · dim_downtime_reason │  │
│  └─────────────────────────┘     │ · dim_scrap_reason    │  │
│                                  │ · fact_oee_summary    │  │
│                                  │ · fact_downtime_event │  │
│                                  │ · fact_scrap_event    │  │
│                                  └───────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
         ▲                                    │
         │ Python generate_data.py            │ Power BI
         │ (6 months · 6 machines · 3 shifts) │ DirectQuery / Import
         └────────────────────────────────────▘
```

**Design principles:**
- `stg` schema: raw event-level data, append-only
- `dw` schema: star schema, Power BI reads only from here
- ETL via stored procedures (`sp_populate_fact_oee`, `sp_populate_pareto_facts`)
- Idempotent upsert on `fact_oee_summary` (ON CONFLICT DO UPDATE)
- Full refresh on pareto facts (TRUNCATE + INSERT in atomic transaction)

---

## 📁 Project Structure

```
oee-analytics-platform/
├── docker-compose.yml          # PostgreSQL + Flyway containers
├── .env.example                # Environment variable template
├── sql/
│   ├── V1__init_stg_schema.sql # Staging layer DDL (4 event tables)
│   ├── V2__init_dw_schema.sql  # Star schema DDL (5 dims + 3 facts)
│   └── V3__create_views.sql    # ETL stored procedures
├── scripts/
│   └── generate_data.py        # Synthetic data generator (6 months)
└── README.md
```

---

## 🚀 How to Run

**Prerequisites:** Docker Desktop, Python 3.11+

```bash
# 1. Clone and configure
git clone https://github.com/YOUR_USERNAME/oee-analytics-platform.git
cd oee-analytics-platform
cp .env.example .env          # Fill in your credentials

# 2. Start PostgreSQL + run Flyway migrations
docker-compose up -d

# 3. Install Python dependencies
pip install psycopg2-binary pandas python-dotenv faker

# 4. Generate synthetic data
python scripts/generate_data.py

# 5. Run ETL pipeline
psql -h localhost -p 5433 -U oee_admin -d oee_db \
  -c "CALL dw.sp_run_full_etl();"
```

**Then open** `OEE_Dashboard.pbix` in Power BI Desktop and refresh.

---

## 📊 Dashboard Preview

> *Screenshot placeholder — Power BI dashboard (in progress)*

**Dashboard covers:**
- 4 KPI cards: OEE %, Availability %, Performance %, Quality %
- OEE trend line by month (Feb–Jul 2026)
- OEE comparison bar chart by machine
- Downtime Pareto chart by reason category
- Scrap Pareto chart by defect type
- Slicers: Plant · Month · Machine (cross-filter all visuals)

---

## 🛠️ Tech Stack

| Layer | Technology | Purpose |
|---|---|---|
| Infrastructure | Docker + Flyway | Containerized DB + versioned migrations |
| Database | PostgreSQL 15 | Staging + Data Warehouse (dual-schema) |
| ETL | SQL Stored Procedures | stg → dw transform, idempotent |
| Data Generation | Python + pandas | Synthetic 6-month production dataset |
| Visualization | Power BI Desktop | OEE KPI dashboard, star schema model |
| Version Control | Git + GitHub | Full project history |

---

## 📐 Data Model

**Fact table grain:** 1 row = 1 machine × 1 shift × 1 product × 1 date

**OEE Formula:**
```
OEE = Availability × Performance × Quality

Availability = Operating Time / Planned Production Time
Performance  = (Total Pieces / Ideal Cycle Time) / Operating Time  
Quality      = Good Pieces / Total Pieces
```

---

*Domain: Injection Molding Manufacturing · Inspired by a simulate production workflow at Polytech Industries*
