#!/usr/bin/env python3
"""
setup_redshift_views.py
Creates all 6 analytical views in Redshift.
Reads config from deploy-config.json (or env vars).

Zero ETL creates a read-only database (ebsanalytics_zetl) with the raw Oracle
tables. Views are created in a regular database (ebsanalytics) with cross-database
references to the Zero ETL data.

Views:
  1. current_cash_position
  2. ar_aging_analysis
  3. weekly_cash_flow_summary
  4. customer_payment_behavior
  5. liquidity_sufficiency_analysis
  6. predictive_cash_flow_forecast
"""

import boto3
import json
import os
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def load_config():
    config_path = os.path.join(SCRIPT_DIR, 'deploy-config.json')
    if os.path.exists(config_path):
        with open(config_path) as f:
            cfg = json.load(f)
        region = cfg.get('aws_region') or 'us-east-1'
        cluster = os.environ.get('CLUSTER_ID') or cfg['redshift'].get('cluster_id')
        database = os.environ.get('DATABASE') or cfg['redshift'].get('database')
        user = os.environ.get('DB_USER') or cfg['redshift'].get('db_user')
        if not all([cluster, database, user]):
            print("ERROR: redshift.cluster_id, database, and db_user must be set in deploy-config.json")
            sys.exit(1)
        return region, cluster, database, user
    return (
        os.environ.get('AWS_REGION', 'us-east-1'),
        os.environ['CLUSTER_ID'],
        os.environ['DATABASE'],
        os.environ['DB_USER'],
    )


REGION, CLUSTER_ID, DATABASE, DB_USER = load_config()
ZETL_DB = f"{DATABASE}_zetl"
rs = boto3.client('redshift-data', region_name=REGION)

# Cross-database references to Zero ETL tables
AR = f'"{ZETL_DB}"."AR"."AR_PAYMENT_SCHEDULES_ALL"'  # nosec B608
AP = f'"{ZETL_DB}"."AP"."AP_PAYMENT_SCHEDULES_ALL"'  # nosec B608
HZ = f'"{ZETL_DB}"."AR"."HZ_CUST_ACCOUNTS"'  # nosec B608


def exec_sql(sql, database='dev', timeout=60):
    """Execute SQL and wait for completion. Returns (success, error).
    Note: SQL is constructed from hardcoded view definitions, not user input.
    """
    r = rs.execute_statement(
        ClusterIdentifier=CLUSTER_ID, Database=database, DbUser=DB_USER, Sql=sql
    )
    stmt_id = r['Id']
    for _ in range(timeout):
        s = rs.describe_statement(Id=stmt_id)
        if s['Status'] == 'FINISHED':
            return True, None
        if s['Status'] in ('FAILED', 'ABORTED'):
            return False, s.get('Error', 'unknown')
        time.sleep(1)  # nosemgrep: arbitrary-sleep — required for AWS async API polling
    return False, 'timed out'


def run_sql(sql, label=''):
    print(f"  Creating: {label}")
    # Cross-database references to Zero ETL databases are treated as external
    # tables by Redshift. Late-binding views (WITH NO SCHEMA BINDING) are
    # required to wrap them.
    sql_stripped = sql.rstrip().rstrip(';')
    if 'CREATE OR REPLACE VIEW' in sql_stripped.upper() and 'NO SCHEMA BINDING' not in sql_stripped.upper():
        sql_stripped = sql_stripped + '\nWITH NO SCHEMA BINDING'
    ok, err = exec_sql(sql_stripped, database=DATABASE)
    if ok:
        print(f"    OK")
    else:
        print(f"    FAILED: {err}")
    return ok


def ensure_database():
    """Create the regular database for views if it doesn't exist."""
    print(f"Ensuring database '{DATABASE}' exists...")
    ok, err = exec_sql(f'CREATE DATABASE "{DATABASE}"', database='dev')  # nosec B608
    if ok:
        print(f"  ✓ Created database '{DATABASE}'")
    elif err and 'already exists' in err.lower():
        print(f"  ✓ Database '{DATABASE}' already exists")
    else:
        print(f"  ERROR: {err}")
        sys.exit(1)


# ---------------------------------------------------------------------------
# View SQL definitions — cross-database references to Zero ETL database
# ---------------------------------------------------------------------------

# SQL below uses f-strings for cross-database table references only (from config, not user input)
# nosec B608 — no SQL injection risk as all interpolated values are from deploy-config.json
VIEWS = {
    "current_cash_position": f"""
CREATE OR REPLACE VIEW current_cash_position AS
SELECT
  'Current Position' AS metric,
  SUM(CASE WHEN "DUE_DATE"::date < CURRENT_DATE THEN "AMOUNT_DUE_REMAINING"::numeric(18,0) ELSE 0 END) AS overdue_receivables,
  SUM(CASE WHEN "DUE_DATE"::date >= CURRENT_DATE AND "DUE_DATE"::date <= CURRENT_DATE + 7
      THEN "AMOUNT_DUE_REMAINING"::numeric(18,0) ELSE 0 END) AS receivables_due_this_week,
  SUM(CASE WHEN "DUE_DATE"::date >= CURRENT_DATE AND "DUE_DATE"::date <= CURRENT_DATE + 30
      THEN "AMOUNT_DUE_REMAINING"::numeric(18,0) ELSE 0 END) AS receivables_due_this_month,
  (SELECT COALESCE(SUM("GROSS_AMOUNT"), 0) FROM {AP}
   WHERE "DUE_DATE" < CURRENT_DATE AND "PAYMENT_STATUS_FLAG" = 'N') AS overdue_payables,
  (SELECT COALESCE(SUM("GROSS_AMOUNT"), 0) FROM {AP}
   WHERE "DUE_DATE" >= CURRENT_DATE AND "DUE_DATE" <= CURRENT_DATE + 7
     AND "PAYMENT_STATUS_FLAG" = 'N') AS payables_due_this_week,
  (SELECT COALESCE(SUM("GROSS_AMOUNT"), 0) FROM {AP}
   WHERE "DUE_DATE" >= CURRENT_DATE AND "DUE_DATE" <= CURRENT_DATE + 30
     AND "PAYMENT_STATUS_FLAG" = 'N') AS payables_due_this_month,
  SUM(CASE WHEN "DUE_DATE"::date >= CURRENT_DATE AND "DUE_DATE"::date <= CURRENT_DATE + 7
      THEN "AMOUNT_DUE_REMAINING"::numeric(18,0) ELSE 0 END)
  - (SELECT COALESCE(SUM("GROSS_AMOUNT"), 0) FROM {AP}
     WHERE "DUE_DATE" >= CURRENT_DATE AND "DUE_DATE" <= CURRENT_DATE + 7
       AND "PAYMENT_STATUS_FLAG" = 'N') AS net_cash_this_week,
  SUM(CASE WHEN "DUE_DATE"::date >= CURRENT_DATE AND "DUE_DATE"::date <= CURRENT_DATE + 30
      THEN "AMOUNT_DUE_REMAINING"::numeric(18,0) ELSE 0 END)
  - (SELECT COALESCE(SUM("GROSS_AMOUNT"), 0) FROM {AP}
     WHERE "DUE_DATE" >= CURRENT_DATE AND "DUE_DATE" <= CURRENT_DATE + 30
       AND "PAYMENT_STATUS_FLAG" = 'N') AS net_cash_this_month
FROM {AR}
WHERE "AMOUNT_DUE_REMAINING" IS NOT NULL AND "DUE_DATE" IS NOT NULL
""",

    "ar_aging_analysis": f"""
CREATE OR REPLACE VIEW ar_aging_analysis AS
SELECT
  CASE
    WHEN "DUE_DATE"::date < CURRENT_DATE THEN 'OVERDUE'
    WHEN "DUE_DATE"::date <= CURRENT_DATE + 7 THEN 'DUE_THIS_WEEK'
    WHEN "DUE_DATE"::date <= CURRENT_DATE + 30 THEN 'DUE_THIS_MONTH'
    ELSE 'FUTURE'
  END AS aging_bucket,
  COUNT(*) AS invoice_count,
  SUM("AMOUNT_DUE_REMAINING"::numeric(38,10)) AS total_amount,
  AVG("AMOUNT_DUE_REMAINING"::numeric(38,10)) AS avg_amount,
  COUNT(DISTINCT "CUSTOMER_ID") AS unique_customers
FROM {AR}
WHERE "AMOUNT_DUE_REMAINING" IS NOT NULL AND "DUE_DATE" IS NOT NULL
GROUP BY 1
""",

    "weekly_cash_flow_summary": f"""
CREATE OR REPLACE VIEW weekly_cash_flow_summary AS
SELECT
  DATE_TRUNC('week', "DUE_DATE"::date) AS forecast_week,
  SUM("AMOUNT_DUE_REMAINING"::numeric(38,10)) AS total_inflows,
  0 AS total_outflows,
  SUM("AMOUNT_DUE_REMAINING"::numeric(38,10)) AS net_cash_flow,
  COUNT(*) AS inflow_count,
  0 AS outflow_count
FROM {AR}
WHERE "DUE_DATE" IS NOT NULL AND "AMOUNT_DUE_REMAINING" IS NOT NULL
  AND "DUE_DATE"::date >= DATE_TRUNC('week', CURRENT_DATE)
  AND "DUE_DATE"::date <= CURRENT_DATE + INTERVAL '90 days'
GROUP BY 1 ORDER BY 1
""",

    "customer_payment_behavior": f"""
CREATE OR REPLACE VIEW customer_payment_behavior AS
SELECT
  "CUSTOMER_ID" AS customer_id,
  COUNT(*) AS total_invoices,
  COUNT(CASE WHEN "STATUS" = 'OP' THEN 1 END) AS overdue_invoices,
  SUM("AMOUNT_DUE_REMAINING"::numeric(38,10)) AS total_outstanding,
  SUM(CASE WHEN "DUE_DATE"::date < CURRENT_DATE
      THEN "AMOUNT_DUE_REMAINING"::numeric(38,10) ELSE 0 END) AS overdue_amount,
  AVG("AMOUNT_DUE_REMAINING"::numeric(38,10)) AS avg_invoice_amount,
  CASE
    WHEN COUNT(CASE WHEN "DUE_DATE"::date < CURRENT_DATE THEN 1 END) > 0 THEN 'HIGH_RISK'
    WHEN SUM("AMOUNT_DUE_REMAINING"::numeric(38,10)) > 100000000 THEN 'HIGH_VALUE'
    ELSE 'NORMAL'
  END AS risk_category
FROM {AR}
WHERE "CUSTOMER_ID" IS NOT NULL AND "AMOUNT_DUE_REMAINING" IS NOT NULL
GROUP BY "CUSTOMER_ID"
""",

    "liquidity_sufficiency_analysis": f"""
CREATE OR REPLACE VIEW liquidity_sufficiency_analysis AS
SELECT
  'Liquidity Analysis' AS analysis_type,
  SUM(CASE WHEN "DUE_DATE"::date >= CURRENT_DATE AND "DUE_DATE"::date <= CURRENT_DATE + INTERVAL '7 days'
      THEN "AMOUNT_DUE_REMAINING"::numeric(38,10) ELSE 0 END) AS expected_inflows_7days,
  SUM(CASE WHEN "DUE_DATE"::date >= CURRENT_DATE AND "DUE_DATE"::date <= CURRENT_DATE + INTERVAL '30 days'
      THEN "AMOUNT_DUE_REMAINING"::numeric(38,10) ELSE 0 END) AS expected_inflows_30days,
  SUM(CASE WHEN "DUE_DATE"::date < CURRENT_DATE
      THEN "AMOUNT_DUE_REMAINING"::numeric(38,10) ELSE 0 END) AS overdue_at_risk,
  SUM(CASE WHEN "DUE_DATE"::date >= CURRENT_DATE AND "DUE_DATE"::date <= CURRENT_DATE + INTERVAL '7 days'
        AND "STATUS" <> 'OP'
      THEN "AMOUNT_DUE_REMAINING"::numeric(38,10) ELSE 0 END) AS high_confidence_collections,
  COUNT(DISTINCT "CUSTOMER_ID") AS total_customers,
  COUNT(DISTINCT CASE WHEN "DUE_DATE"::date < CURRENT_DATE THEN "CUSTOMER_ID" END) AS customers_overdue,
  CASE WHEN SUM(CASE WHEN "DUE_DATE"::date < CURRENT_DATE
      THEN "AMOUNT_DUE_REMAINING"::numeric(38,10) ELSE 0 END) > 0
    THEN SUM(CASE WHEN "DUE_DATE"::date >= CURRENT_DATE AND "DUE_DATE"::date <= CURRENT_DATE + INTERVAL '7 days'
        THEN "AMOUNT_DUE_REMAINING"::numeric(38,10) ELSE 0 END)
      / SUM(CASE WHEN "DUE_DATE"::date < CURRENT_DATE
        THEN "AMOUNT_DUE_REMAINING"::numeric(38,10) ELSE 0 END)
    ELSE 999.99
  END AS liquidity_coverage_ratio
FROM {AR}
WHERE "AMOUNT_DUE_REMAINING" IS NOT NULL AND "DUE_DATE" IS NOT NULL
""",

    "predictive_cash_flow_forecast": f"""
CREATE OR REPLACE VIEW predictive_cash_flow_forecast AS
WITH weeks AS (
  SELECT (DATE_TRUNC('week', CURRENT_DATE) + (n * INTERVAL '7 days')) AS forecast_week, n AS week_number
  FROM (SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3
        UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7
        UNION ALL SELECT 8 UNION ALL SELECT 9 UNION ALL SELECT 10 UNION ALL SELECT 11) t
),
hist AS (
  SELECT DATE_TRUNC('week', "DUE_DATE"::date) AS week_start,
    SUM("AMOUNT_DUE_REMAINING"::numeric(38,10)) AS weekly_amount
  FROM {AR}
  WHERE "DUE_DATE" IS NOT NULL AND "AMOUNT_DUE_REMAINING" IS NOT NULL
  GROUP BY 1
),
avg_hist AS (
  SELECT AVG(weekly_amount) AS avg_weekly_inflow,
    STDDEV(weekly_amount::float) AS stddev_weekly_inflow,
    COUNT(*) AS weeks_of_data
  FROM hist
)
SELECT w.forecast_week, w.week_number,
  ROUND(h.avg_weekly_inflow, 2) AS predicted_inflow,
  ROUND(h.avg_weekly_inflow::float - COALESCE(h.stddev_weekly_inflow, 0), 2) AS conservative_inflow,
  ROUND(h.avg_weekly_inflow::float + COALESCE(h.stddev_weekly_inflow, 0), 2) AS optimistic_inflow,
  ROUND(h.avg_weekly_inflow * (w.week_number + 1), 2) AS cumulative_predicted_inflow,
  CASE WHEN h.weeks_of_data >= 12 THEN 'HIGH'
       WHEN h.weeks_of_data >= 8 THEN 'MEDIUM' ELSE 'LOW' END AS confidence_level,
  h.weeks_of_data AS historical_weeks_used,
  'PREDICTED' AS forecast_type
FROM weeks w CROSS JOIN avg_hist h
ORDER BY w.forecast_week
"""
}


if __name__ == '__main__':
    ensure_database()

    print(f"Creating Redshift views in {CLUSTER_ID}/{DATABASE}")
    print(f"  Source data: {ZETL_DB} (Zero ETL)")
    print(f"Region: {REGION}, User: {DB_USER}")
    print("=" * 60)

    failed = []
    for name, sql in VIEWS.items():
        ok = run_sql(sql.strip(), label=name)
        if not ok:
            failed.append(name)

    print("=" * 60)
    if failed:
        print(f"FAILED views: {', '.join(failed)}")
        sys.exit(1)
    else:
        print(f"All {len(VIEWS)} analytical views created successfully.")
