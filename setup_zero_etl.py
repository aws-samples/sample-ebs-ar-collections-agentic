#!/usr/bin/env python3
"""
setup_zero_etl.py — Creates/manages the AWS Glue Zero-ETL integration (Oracle DMS → Amazon Redshift).

Usage:
  python3 setup_zero_etl.py                  # Create integration (or wait if already creating)
  python3 setup_zero_etl.py --status         # Check integration status
  python3 setup_zero_etl.py --create-db      # Show Amazon Redshift DB creation command

Exit codes:
  0 = success (created or already active)
  1 = error
  2 = already exists / in progress (not an error)
"""

import boto3
import json
import os
import subprocess
import sys
import time
import argparse

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def load_config():
    config_path = os.path.join(SCRIPT_DIR, 'deploy-config.json')
    if not os.path.exists(config_path):
        print("ERROR: deploy-config.json not found.")
        sys.exit(1)
    with open(config_path) as f:
        return json.load(f)


def get_account_id():
    return boto3.client('sts').get_caller_identity()['Account']


def get_redshift_namespace_arn(region, cluster_id):
    redshift = boto3.client('redshift', region_name=region)
    resp = redshift.describe_clusters(ClusterIdentifier=cluster_id)
    return resp['Clusters'][0]['ClusterNamespaceArn']


def run_cli(cmd):
    """Run an AWS CLI command. All commands are hardcoded lists - no user input.

    Safe against command injection because:
      - shell=False (no shell interpretation of metacharacters)
      - assert ensures cmd[0] == 'aws' (only AWS CLI is invoked)
      - All cmd values come from deploy-config.json or AWS API responses, not user input
    """
    assert isinstance(cmd, list) and cmd[0] == 'aws', "Only AWS CLI commands allowed"
    # nosemgrep: dangerous-subprocess-use-audit
    result = subprocess.run(cmd, capture_output=True, text=True, shell=False)  # nosec B603
    return result.returncode == 0, result.stdout.strip(), result.stderr.strip()


def get_integration_by_name(region, name):
    """Find integration by name using CLI. Returns dict or None."""
    ok, out, err = run_cli([
        'aws', 'glue', 'describe-integrations', '--region', region, '--output', 'json'
    ])
    if not ok:
        return None
    for integ in json.loads(out).get('Integrations', []):
        if integ.get('IntegrationName') == name:
            return integ
    return None


def require_source_sid(zetl):
    """Return the configured Oracle PDB name or exit with a clear error."""
    source_sid = zetl.get('source_sid')
    if not isinstance(source_sid, str) or not source_sid.strip():
        print("ERROR: zero_etl.source_sid must be set to the Oracle PDB name in deploy-config.json")
        sys.exit(1)
    return source_sid.strip()


def compute_expected_filter(zetl):
    """Build the data filter string from config (must match create_integration logic)."""
    source_sid = require_source_sid(zetl)
    tables = zetl.get('tables', [])
    fallback_schema = zetl.get('source_database', 'APPS')
    parts = []
    for t in tables:
        if '.' in t:
            parts.append(f"include: {source_sid}.{t}")
        else:
            parts.append(f"include: {source_sid}.{fallback_schema}.{t}")
    return ', '.join(parts) if parts else None


def filter_matches(existing_filter, expected_filter):
    """Compare two data filters semantically (order-independent set comparison)."""
    if not existing_filter and not expected_filter:
        return True
    if not existing_filter or not expected_filter:
        return False
    existing_set = {p.strip() for p in existing_filter.split(',') if p.strip()}
    expected_set = {p.strip() for p in expected_filter.split(',') if p.strip()}
    return existing_set == expected_set


# ---------------------------------------------------------------------------
# Pre-flight validation
# ---------------------------------------------------------------------------
def validate_connectivity(cfg):
    region = cfg['aws_region']
    source_arn = cfg['zero_etl'].get('source_arn', '')
    cluster_id = cfg['redshift']['cluster_id']
    vpc_cfg = cfg.get('vpc', {})
    ok = True

    if not source_arn:
        print("ERROR: zero_etl.source_arn must be set in deploy-config.json")
        sys.exit(1)

    print("Pre-flight connectivity checks:")

    # DMS endpoint
    try:
        dms = boto3.client('dms', region_name=region)
        resp = dms.describe_endpoints(Filters=[{'Name': 'endpoint-arn', 'Values': [source_arn]}])
        eps = resp.get('Endpoints', [])
        if not eps:
            print(f"  ✗ DMS source endpoint not found: {source_arn}")
            ok = False
        else:
            ep = eps[0]
            print(f"  ✓ DMS source: {ep.get('EngineName')} @ {ep.get('ServerName')} (status: {ep.get('Status')})")
            if ep.get('Status') != 'active':
                print(f"    WARNING: expected 'active'")
    except Exception as e:
        print(f"  ✗ DMS check failed: {e}")
        ok = False

    # Amazon Redshift
    try:
        rs = boto3.client('redshift', region_name=region)
        resp = rs.describe_clusters(ClusterIdentifier=cluster_id)
        status = resp['Clusters'][0].get('ClusterStatus')
        print(f"  ✓ Amazon Redshift cluster: {cluster_id} (status: {status})")
        if status not in ('available', 'integration-creating'):
            print(f"    WARNING: expected 'available'")
            ok = False
    except Exception as e:
        print(f"  ✗ Amazon Redshift check failed: {e}")
        ok = False

    # VPC
    subnet_ids = vpc_cfg.get('subnet_ids', '')
    sg_id = vpc_cfg.get('security_group_id', '')
    if not subnet_ids or not sg_id:
        print("  ✗ vpc.subnet_ids and vpc.security_group_id required")
        ok = False
    else:
        print(f"  ✓ VPC: subnets={subnet_ids}, sg={sg_id}")

    print()
    if not ok:
        print("Pre-flight checks failed.")
        sys.exit(1)


# ---------------------------------------------------------------------------
# Amazon Redshift resource policy
# ---------------------------------------------------------------------------
def set_redshift_resource_policy(cfg, account_id):
    """Set Amazon Redshift resource policy to allow inbound integration from DMS source.

    Only the DMS source ARN needs to be authorized for integration creation.
    CREATE DATABASE FROM INTEGRATION does not require the AWS Glue integration ARN
    in the policy — it uses the integration_id from SVV_INTEGRATION directly.
    """
    region = cfg['aws_region']
    cluster_id = cfg['redshift']['cluster_id']
    source_arn = cfg['zero_etl']['source_arn']
    namespace_arn = get_redshift_namespace_arn(region, cluster_id)

    policy = json.dumps({
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": {"Service": ["redshift.amazonaws.com"]},
                "Action": ["redshift:AuthorizeInboundIntegration"],
                "Resource": namespace_arn,
                "Condition": {"StringEquals": {"aws:SourceArn": source_arn}}
            },
            {
                "Effect": "Allow",
                "Principal": {"AWS": account_id},
                "Action": ["redshift:CreateInboundIntegration", "redshift:ModifyInboundIntegration"],
                "Resource": namespace_arn
            }
        ]
    })

    print(f"Setting Amazon Redshift resource policy on {namespace_arn}")
    rs = boto3.client('redshift', region_name=region)
    rs.put_resource_policy(ResourceArn=namespace_arn, Policy=policy)
    print(f"  ✓ Resource policy set")
    print()


# ---------------------------------------------------------------------------
# Create integration (via CLI to avoid boto3 version issues)
# ---------------------------------------------------------------------------
def create_integration(cfg):
    region = cfg['aws_region']
    zetl = cfg['zero_etl']
    rs_cfg = cfg['redshift']
    vpc_cfg = cfg.get('vpc', {})

    source_arn = zetl['source_arn']
    target_arn = get_redshift_namespace_arn(region, rs_cfg['cluster_id'])

    data_filter = compute_expected_filter(zetl)

    integration_config = json.dumps({
        "SourceProperties": {
            "SubnetIds": vpc_cfg['subnet_ids'],
            "VpcSecurityGroupIds": vpc_cfg['security_group_id'],
        }
    })

    print(f"Creating Zero-ETL integration:")
    print(f"  Name:   {zetl['integration_name']}")
    print(f"  Source: {source_arn}")
    print(f"  Target: {target_arn}")
    if data_filter:
        print(f"  Filter: {data_filter}")

    cmd = [
        'aws', 'glue', 'create-integration',
        '--integration-name', zetl['integration_name'],
        '--source-arn', source_arn,
        '--target-arn', target_arn,
        '--description', zetl.get('description', 'Oracle EBS to Amazon Redshift Zero-ETL'),
        '--integration-config', integration_config,
        '--region', region,
        '--output', 'json',
    ]
    if data_filter:
        cmd.extend(['--data-filter', data_filter])
    kms_key = zetl.get('kms_key_id', '')
    if kms_key:
        cmd.extend(['--kms-key-id', kms_key])

    ok, out, err = run_cli(cmd)
    if not ok:
        if 'ConflictException' in err or 'AlreadyExists' in err:
            # Could be a real duplicate OR a stale resource from a recently deleted integration.
            # Check if the integration actually exists before assuming it's a duplicate.
            existing = get_integration_by_name(region, zetl['integration_name'])
            if existing:
                print("  Integration already exists.")
                return existing.get('IntegrationArn')
            # Stale conflict — wait and retry
            print("  Conflict detected (stale resources from previous integration). Waiting 60s and retrying...")
            time.sleep(60)  # nosemgrep: arbitrary-sleep — required for AWS async API polling
            ok, out, err = run_cli(cmd)
            if not ok:
                if 'ConflictException' in err or 'AlreadyExists' in err:
                    print("  Still conflicting. Wait a few minutes for old DMS resources to clean up, then re-run.")
                else:
                    print(f"  ERROR: {err}")
                sys.exit(1)
        else:
            print(f"  ERROR: {err}")
            sys.exit(1)

    resp = json.loads(out)
    print(f"  ✓ Created: {resp.get('IntegrationArn')}")
    print(f"  Status: {resp.get('Status')}")
    return resp.get('IntegrationArn')


# ---------------------------------------------------------------------------
# Wait for ACTIVE
# ---------------------------------------------------------------------------
def wait_for_active(cfg):
    region = cfg['aws_region']
    name = cfg['zero_etl']['integration_name']

    print(f"Waiting for integration '{name}' to become ACTIVE...")
    for i in range(60):
        integ = get_integration_by_name(region, name)
        status = integ.get('Status', 'UNKNOWN') if integ else 'NOT_FOUND'
        print(f"  Status: {status} ({i+1}/60)")

        if status == 'ACTIVE':
            print(f"  ✓ Integration is ACTIVE")
            return True
        if status in ('FAILED', 'ERROR'):
            print(f"  ✗ Integration failed")
            sys.exit(1)
        if status == 'NOT_FOUND':
            print(f"  ✗ Integration not found")
            sys.exit(1)

        time.sleep(30)  # nosemgrep: arbitrary-sleep — required for AWS async API polling

    print("  Timed out (30 min). Check: python3 setup_zero_etl.py --status")
    sys.exit(1)


# ---------------------------------------------------------------------------
# Status / create-db
# ---------------------------------------------------------------------------
def check_status(cfg):
    region = cfg['aws_region']
    ok, out, err = run_cli([
        'aws', 'glue', 'describe-integrations', '--region', region, '--output', 'json'
    ])
    if not ok:
        print(f"ERROR: {err}")
        return

    integrations = json.loads(out).get('Integrations', [])
    if not integrations:
        print("No Zero-ETL integrations found.")
        return

    for integ in integrations:
        print(f"  Name:   {integ.get('IntegrationName', 'N/A')}")
        print(f"  ARN:    {integ.get('IntegrationArn', 'N/A')}")
        print(f"  Status: {integ.get('Status', 'N/A')}")
        print(f"  Source: {integ.get('SourceArn', 'N/A')}")
        print(f"  Target: {integ.get('TargetArn', 'N/A')}")
        print()


def create_redshift_database(cfg, integration_arn=None):
    """Create the Amazon Redshift database from the integration.

    Oracle Zero-ETL requires:
      CREATE DATABASE "<dbname>" FROM INTEGRATION '<integration_id_uuid>' DATABASE "<SID>"
    where:
      - integration_id_uuid is SVV_INTEGRATION.integration_id (UUID only, NOT the full AWS Glue ARN)
      - SID is the configured Oracle source PDB name
      - Identifiers must be double-quoted (enable_case_sensitive_identifier=true folds unquoted to lowercase)

    If the database already exists but is NOT linked to the integration (created standalone),
    it is dropped and recreated FROM INTEGRATION.
    """
    region = cfg['aws_region']
    rs_cfg = cfg['redshift']
    zetl = cfg['zero_etl']
    source_sid = require_source_sid(zetl)

    if not integration_arn:
        integ = get_integration_by_name(region, zetl['integration_name'])
        if integ:
            integration_arn = integ.get('IntegrationArn')
    if not integration_arn:
        print("ERROR: Could not find integration ARN")
        sys.exit(1)

    rs = boto3.client('redshift-data', region_name=region)

    def _exec_and_wait(sql, database='dev', timeout=60):
        """Execute SQL and wait for completion. Returns (success, error, statement_id)."""
        r = rs.execute_statement(
            ClusterIdentifier=rs_cfg['cluster_id'], Database=database,
            DbUser=rs_cfg['db_user'], Sql=sql
        )
        stmt_id = r['Id']
        for _ in range(timeout):
            s = rs.describe_statement(Id=stmt_id)
            if s['Status'] == 'FINISHED':
                return True, None, stmt_id
            if s['Status'] in ('FAILED', 'ABORTED'):
                return False, s.get('Error', 'unknown error'), stmt_id
            time.sleep(1)  # nosemgrep: arbitrary-sleep — required for AWS async API polling
        return False, 'timed out', stmt_id

    # Step 1: Query SVV_INTEGRATION to get the integration_id UUID
    # (Amazon Redshift expects the UUID, not the full AWS Glue ARN, in CREATE DATABASE FROM INTEGRATION)
    print("Looking up integration_id from SVV_INTEGRATION...")
    ok, err, stmt_id = _exec_and_wait("SELECT integration_id FROM svv_integration")
    if not ok:
        print(f"  ERROR querying svv_integration: {err}")
        sys.exit(1)

    try:
        res = rs.get_statement_result(Id=stmt_id)
        records = res.get('Records', [])
        if not records:
            print("  ERROR: No integrations found in svv_integration. Integration may not be registered yet.")
            sys.exit(1)
        integration_id = records[0][0].get('stringValue', '').strip()
        if not integration_id:
            print("  ERROR: Empty integration_id in svv_integration")
            sys.exit(1)
        print(f"  ✓ integration_id: {integration_id}")
    except Exception as e:
        print(f"  ERROR reading svv_integration result: {e}")
        sys.exit(1)

    # Step 2: Try CREATE DATABASE FROM INTEGRATION with quoted identifiers + DATABASE clause
    db_name = rs_cfg['database'] + '_zetl'
    create_sql = f'CREATE DATABASE "{db_name}" FROM INTEGRATION \'{integration_id}\' DATABASE "{source_sid}"'  # nosec B608
    print(f"Creating Amazon Redshift database '{db_name}' from integration (source SID: {source_sid})...")
    ok, err, _ = _exec_and_wait(create_sql, timeout=60)

    if ok:
        print(f"  ✓ Database '{db_name}' created from integration")
        return

    if err and 'has already been established' in err.lower():
        # Integration + remote DB pair already has a linked Amazon Redshift database
        # (possibly under a different name). Nothing to do.
        print(f"  ✓ Integration already linked to an Amazon Redshift database — skipping")
        return

    if err and 'already exists' in err.lower():
        # Database exists — check if linked to integration
        print(f"  Database '{db_name}' exists. Checking if linked to integration...")
        check_sql = f"SELECT integration_id FROM svv_integration WHERE database_name = '{db_name}'"  # nosec B608
        # svv_integration may not have database_name column in all versions; fall back to a simpler heuristic
        ok2, _, stmt_id2 = _exec_and_wait(check_sql)
        is_linked = False
        if ok2:
            try:
                res = rs.get_statement_result(Id=stmt_id2)
                is_linked = res.get('TotalNumRows', 0) > 0
            except Exception:
                pass

        if is_linked:
            print(f"  ✓ Database '{db_name}' already linked to integration")
            return

        print(f"  Database exists but is NOT linked to integration. Dropping and recreating...")
        ok3, err3, _ = _exec_and_wait(f'DROP DATABASE "{db_name}"')
        if not ok3:
            print(f"  ERROR dropping database: {err3}")
            sys.exit(1)
        print(f"  ✓ Dropped standalone database")

        ok4, err4, _ = _exec_and_wait(create_sql, timeout=60)
        if not ok4:
            print(f"  ERROR creating database from integration: {err4}")
            sys.exit(1)
        print(f"  ✓ Database '{db_name}' recreated from integration")
        return

    print(f"  ERROR: {err}")
    print(f"  SQL: {create_sql}")
    sys.exit(1)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Manage Zero-ETL integration')
    parser.add_argument('--status', action='store_true')
    parser.add_argument('--create-db', action='store_true')
    args = parser.parse_args()

    cfg = load_config()

    if args.status:
        check_status(cfg)
        sys.exit(0)

    if args.create_db:
        create_redshift_database(cfg)
        sys.exit(0)

    # --- Default: create or wait ---
    region = cfg['aws_region']
    name = cfg['zero_etl']['integration_name']
    account_id = get_account_id()

    validate_connectivity(cfg)

    # Check if integration already exists
    existing = get_integration_by_name(region, name)
    if existing:
        status = existing.get('Status', 'UNKNOWN')
        print(f"Integration '{name}' already exists (status: {status})")

        # Validate the existing integration's data filter matches the current config
        existing_filter = existing.get('DataFilter', '')
        expected_filter = compute_expected_filter(cfg['zero_etl'])
        if not filter_matches(existing_filter, expected_filter):
            print()
            print("  ✗ DATA FILTER MISMATCH — existing integration was created with a different config.")
            print(f"    Existing: {existing_filter}")
            print(f"    Expected: {expected_filter}")
            print()
            print("  The existing integration will NOT replicate the tables you want.")
            print("  To fix this, delete the integration and re-run this script:")
            print()
            print(f"    1. Drop the linked Amazon Redshift database (if any):")
            print(f"       echo 'DROP DATABASE \"{cfg['redshift']['database']}_zetl\"' | aws redshift-data execute-statement ...")
            print(f"    2. Delete the integration:")
            print(f"       aws glue delete-integration --integration-identifier {existing.get('IntegrationArn')} --region {region}")
            print(f"    3. Wait ~5-10 min for full deletion, then re-run: python3 setup_zero_etl.py")
            sys.exit(1)
        print(f"  ✓ Data filter matches current config")

        if status in ('CREATING', 'MODIFYING'):
            wait_for_active(cfg)
        elif status == 'ACTIVE':
            print("  ✓ Already ACTIVE")
        else:
            print(f"  Status: {status} — check manually: python3 setup_zero_etl.py --status")
            sys.exit(1)
        create_redshift_database(cfg, existing.get('IntegrationArn'))
        sys.exit(2)

    # New integration
    set_redshift_resource_policy(cfg, account_id)
    integration_arn = create_integration(cfg)
    wait_for_active(cfg)
    integ = get_integration_by_name(region, name)
    integration_arn = integ.get('IntegrationArn') if integ else integration_arn
    create_redshift_database(cfg, integration_arn)
