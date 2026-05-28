# Zero ETL Prerequisites — Oracle EBS to Amazon Redshift

This document covers the Oracle database and AWS configuration required for Zero ETL (AWS DMS Serverless CDC) replication from Oracle EBS to Amazon Redshift.

---

## Oracle Database Configuration

### 1. ARCHIVELOG Mode

The database must be in ARCHIVELOG mode for AWS DMS CDC to read redo logs.

```sql
-- Check current mode (connect as SYSDBA)
SELECT LOG_MODE FROM V$DATABASE;
```

Expected: `ARCHIVELOG`. If `NOARCHIVELOG`, enable it:

```sql
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;
```

### 2. Supplemental Logging

AWS DMS Binary Reader requires **both** minimal and primary key supplemental logging. This is the most common misconfiguration — missing PK supplemental logging causes tables to sync with 0 rows and eventually error out.

```sql
-- Check current settings (connect as SYSDBA)
SELECT SUPPLEMENTAL_LOG_DATA_MIN, SUPPLEMENTAL_LOG_DATA_PK, SUPPLEMENTAL_LOG_DATA_ALL
FROM V$DATABASE;
```

**Required values:**

| Setting | Required | Purpose |
|---|---|---|
| `SUPPLEMENTAL_LOG_DATA_MIN` | **YES** | Minimum redo information for AWS DMS |
| `SUPPLEMENTAL_LOG_DATA_PK` | **YES** | Logs primary key columns on every UPDATE — required for AWS DMS to identify rows |
| `SUPPLEMENTAL_LOG_DATA_ALL` | NO | Not required (logs all columns — higher redo volume) |

Enable if missing:

```sql
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA (PRIMARY KEY) COLUMNS;
```

> **Symptom if PK supplemental logging is missing:** DMS creates table structures in Amazon Redshift but loads 0 rows. The replication stats will show `TablesErrored: 6` and the full load completes suspiciously fast (seconds instead of minutes). The integration status may still show `ACTIVE` despite all tables being empty.

### 3. Primary Keys on All Target Tables

DMS requires primary keys on every replicated table. Oracle EBS standard tables already have PKs, but verify:

```sql
-- Run from the PDB (ALTER SESSION SET CONTAINER=<PDB_NAME> if CDB)
SELECT OWNER, TABLE_NAME, CONSTRAINT_NAME
FROM ALL_CONSTRAINTS
WHERE CONSTRAINT_TYPE = 'P'
  AND OWNER IN ('AR','AP','GL','PO')
  AND TABLE_NAME IN (
    'AR_PAYMENT_SCHEDULES_ALL',
    'HZ_CUST_ACCOUNTS',
    'AP_INVOICES_ALL',
    'AP_PAYMENT_SCHEDULES_ALL',
    'GL_BALANCES',
    'PO_HEADERS_ALL'
  )
ORDER BY OWNER, TABLE_NAME;
```

All 6 tables must return a PK constraint. If any are missing, create them before enabling Zero ETL.

### 4. CDB/PDB Considerations

Oracle EBS 12.2 on 19c typically runs as a pluggable database (PDB) inside a container database (CDB).

- The DMS source endpoint `DatabaseName` must be set to the **PDB name** (e.g., `ERPUAT`), not the CDB name
- `V$DATABASE` queries for ARCHIVELOG and supplemental logging must be run from the **CDB root** (ORACLE_SID = CDB SID, e.g., `CERPUAT`)
- Table/PK queries must be run from the **PDB** (`ALTER SESSION SET CONTAINER=ERPUAT`)

---

## DMS Source Endpoint Configuration

| Setting | Value | Notes |
|---|---|---|
| Engine | `oracle` | |
| Server | EBS DB private IP | Must be reachable from DMS VPC/subnets |
| Port | `1521` | |
| Database name | PDB name (e.g., `ERPUAT`) | Not the CDB name |
| Username | `apps` or DMS-specific user | Needs SELECT on target schemas + redo log access |
| SSL | `none` | Within VPC |
| **UseLogminerReader** | **`false`** | Binary Reader is required for EC2-hosted Oracle (non-RDS) |
| **UseBFile** | **`true`** | Required with Binary Reader |
| AuthenticationMethod | `password` | Or Secrets Manager |

> **Binary Reader vs LogMiner:** For Oracle on EC2 (non-RDS), DMS must use Binary Reader (`UseLogminerReader: false`). LogMiner is only supported for RDS Oracle. Binary Reader reads redo logs directly and requires ARCHIVELOG + supplemental logging.

---

## Amazon Redshift Configuration

### Parameter Group

The Amazon Redshift cluster parameter group must have:

| Parameter | Value | Purpose |
|---|---|---|
| `enable_case_sensitive_identifier` | `true` | Oracle table/schema names are uppercase; without this, Amazon Redshift folds to lowercase |

### Database Creation

The `ebsanalytics` database is **not** a regular Amazon Redshift database — it must be created **from the integration** after the AWS Glue Zero ETL integration is `ACTIVE`:

```sql
CREATE DATABASE "ebsanalytics" FROM INTEGRATION '<integration_uuid>' DATABASE "ERPUAT";
```

The `deploy.sh zero-etl` script handles this automatically. If you need to do it manually, get the UUID from `svv_integration`:

```sql
SELECT integration_id FROM svv_integration;
```

### Resource Policy

The Amazon Redshift namespace must have a resource policy allowing AWS Glue to create the integration. The `deploy.sh zero-etl` script sets this automatically via `setup_zero_etl.py`.

---

## Network Requirements

| Source | Destination | Port | Purpose |
|---|---|---|---|
| DMS subnets | Oracle EBS DB | 1521 | DMS reads redo logs |
| DMS subnets | Amazon Redshift | 5439 | DMS writes to Amazon Redshift |
| DMS subnets | AWS service endpoints | 443 | DMS control plane |

- Use **private subnets** with a NAT gateway for outbound access to AWS services
- Minimum **2 subnets in different AZs** (required by AWS DMS Serverless)
- Security group must allow outbound to the Oracle DB IP on port 1521

---

## AWS Glue Zero ETL Data Filter Syntax

Each table must have its own `include:` prefix, comma-separated. The format is `include: <CDB>.<SCHEMA>.<TABLE>`:

```
include: ERPUAT.AP.AP_INVOICES_ALL, include: ERPUAT.AP.AP_PAYMENT_SCHEDULES_ALL, include: ERPUAT.AR.AR_PAYMENT_SCHEDULES_ALL
```

> **Common mistake:** Using a single `include:` with multiple tables. Each table needs its own `include:` prefix.

---

## Troubleshooting

### Tables sync with 0 rows

**Cause:** Missing `SUPPLEMENTAL_LOG_DATA_PK` on the Oracle database.

**Fix:**
```sql
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA (PRIMARY KEY) COLUMNS;
```
Then delete and recreate the Zero ETL integration (errored tables don't auto-retry).

### Full load completes in seconds (should take minutes)

**Cause:** All tables errored immediately. Check DMS replication stats:
```bash
aws dms describe-replications --profile <PROFILE> --region us-east-1
```
Look for `TablesErrored: 6` and `FullLoadProgressPercent: 100` with 0 `TablesLoaded`.

### `deploy.sh zero-etl` says "Integration already exists" then fails

**Cause:** A previous integration is still in `DELETING` state. Wait 2–5 minutes for it to fully delete, then re-run.

### `ebsanalytics` database not created

**Cause:** The script exited before reaching the database creation step (e.g., integration wait timed out). Re-run `./deploy.sh zero-etl` — it will find the existing ACTIVE integration and create the database.

### DMS error: "Unsupported keys: RESYNC_APPLY, RESYNC_UNLOAD, DATA_RESYNC"

**Cause:** AWS DMS Serverless engine version incompatibility (transient). Delete the integration, wait for full deletion, and recreate.
