#!/bin/bash
# ============================================================================
# Deploy ALL Collections REST Services (end-to-end)
# Run as: applmgr on EBS app server
# Usage:  ./deploy_all_rest_services.sh
#
# This single script does everything:
#   1. Compile PL/SQL packages in the database
#   2. Generate annotated specs for iRep parser
#   3. Run irep_parser.pl to create .ildt files
#   4. FNDLOAD upload to register in iRep
#   5. Deploy as REST services via iSG
#   6. Grant GLOBAL access
#   7. Verify WADL endpoints
#
# Idempotent — safe to run multiple times.
# ============================================================================
# NOTE: No 'set -e' — we want to continue on individual package failures
# ============================================================================

. __EBS_BASE__/EBSapps.env run

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SQL_DIR="${SCRIPT_DIR}/../sql"
WORK_DIR=/tmp/irep_deploy
ANT=$FMW_HOME/modules/org.apache.ant_1.7.1/bin/ant
ISG_DIR=$JAVA_TOP/oracle/apps/fnd/isg/ant
PERL=$IAS_ORACLE_HOME/perl/bin/perl
IREP_PARSER=$FND_TOP/bin/irep_parser.pl

# Verify Integration Repository Parser setup is complete
# Per Oracle: run `perl $FND_TOP/patch/115/bin/IREPParserSetup.pl` with Patch 13602850
# See Oracle E-Business Suite Integrated SOA Gateway Implementation Guide
$PERL -e 'use Class::MethodMaker 1.0; exit 0 if $Class::MethodMaker::VERSION < 2; exit 1' 2>/dev/null || {
  echo "ERROR: Integration Repository Parser is not set up correctly."
  echo ""
  echo "Required: Class::MethodMaker v1.x (not v2.x)"
  echo ""
  echo "Per Oracle EBS 12.2 SOA Gateway Implementation Guide:"
  echo "  1. Download Patch 13602850 (p13602850_R12_GENERIC.zip) from My Oracle Support"
  echo "     to a temp directory on this server"
  echo "  2. Source EBS env:  . __EBS_BASE__/EBSapps.env run"
  echo "  3. Run: perl \$FND_TOP/patch/115/bin/IREPParserSetup.pl"
  echo "  4. When prompted, provide the directory containing p13602850_R12_GENERIC.zip"
  echo "  5. Re-run this script"
  echo ""
  echo "Reference: https://docs.oracle.com/cd/E26401_01/doc.122/e20925/T511175T543269.htm"
  exit 1
}

# Resolve APPS password
# NOTE: For production use, retrieve credentials from AWS Secrets Manager:
#   APPS_PWD=$(aws secretsmanager get-secret-value --secret-id "${SECRET_NAME}" \
#     --query SecretString --output text | python3 -c "import json,sys;print(json.load(sys.stdin)['password'])")
if [ -z "$APPS_PWD" ]; then
  read -sp "Enter APPS password: " APPS_PWD
  echo ""
fi

rm -rf $WORK_DIR && mkdir -p $WORK_DIR

echo "============================================"
echo "  EBS Collections REST - Full Deployment"
echo "============================================"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# STEP 1: Compile PL/SQL packages in the database
# ══════════════════════════════════════════════════════════════════════════════
echo "=== Step 1: Compiling PL/SQL packages ==="
for SQL_FILE in XX_COLLECTIONS_REST_PKG.sql XX_ORDER_HOLDS_PKG.sql XX_COLLECTIONS_TASK_PKG.sql; do
  echo "  Compiling $SQL_FILE ..."
  sqlplus -s apps/${APPS_PWD} <<EOF
SET FEEDBACK ON
SET SERVEROUTPUT ON
@${SQL_DIR}/${SQL_FILE}
EXIT;
EOF
done

echo "  Verifying compilation..."
sqlplus -s apps/${APPS_PWD} <<'SQLEOF'
SET LINESIZE 120 PAGESIZE 20 HEADING ON FEEDBACK OFF
COL object_name FORMAT A30
COL object_type FORMAT A15
COL status FORMAT A10
SELECT object_name, object_type, status
FROM user_objects
WHERE object_name IN ('XX_COLLECTIONS_REST_PKG','XX_ORDER_HOLDS_PKG','XX_COLLECTIONS_TASK_PKG')
ORDER BY object_name, object_type;
EXIT;
SQLEOF
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# STEP 2: Generate annotated specs + iRep parse + FNDLOAD
# ══════════════════════════════════════════════════════════════════════════════
echo "=== Step 2: Registering packages in iRep ==="

# --- XX_COLLECTIONS_REST_PKG ---
cat > $WORK_DIR/XX_COLLECTIONS_REST_PKG.pls << 'PLSEOF'
CREATE OR REPLACE PACKAGE XX_COLLECTIONS_REST_PKG
AS
/* $Header: XX_COLLECTIONS_REST_PKG.pls 120.1 2026/03/17 12:00:00 applmgr ship $ */
/*#
 * Collections REST Services API.
 * Credit hold management and collections note creation for Oracle EBS.
 * @rep:scope public
 * @rep:product AR
 * @rep:displayname Collections REST Services
 * @rep:category BUSINESS_ENTITY AR_CUSTOMER
 * @rep:lifecycle active
 * @rep:compatibility S
 */

  PROCEDURE UPDATE_CREDIT_HOLD(
    p_cust_account_profile_id IN  NUMBER,
    p_cust_account_id         IN  NUMBER,
    p_credit_hold             IN  VARCHAR2,
    p_object_version_number   IN  NUMBER,
    x_return_status           OUT VARCHAR2,
    x_msg_count               OUT NUMBER,
    x_msg_data                OUT VARCHAR2,
    x_object_version_number   OUT NUMBER
  )
  /*#
   * Update credit hold flag on a customer account profile.
   * @param p_cust_account_profile_id Customer Account Profile ID
   * @param p_cust_account_id Customer Account ID
   * @param p_credit_hold Credit hold flag Y or N
   * @param p_object_version_number Object version number for optimistic locking
   * @param x_return_status Return status S E or U
   * @param x_msg_count Number of messages
   * @param x_msg_data Error message text
   * @param x_object_version_number New object version number after update
   * @rep:scope public
   * @rep:lifecycle active
   * @rep:displayname Update Credit Hold
   * @rep:category BUSINESS_ENTITY AR_CUSTOMER
   */;

  PROCEDURE CREATE_COLLECTIONS_NOTE(
    p_source_object_id   IN  NUMBER,
    p_notes              IN  VARCHAR2,
    p_note_type          IN  VARCHAR2,
    x_return_status      OUT VARCHAR2,
    x_jtf_note_id        OUT NUMBER,
    x_msg_count          OUT NUMBER,
    x_msg_data           OUT VARCHAR2
  )
  /*#
   * Create a collections note linked to a customer account.
   * @param p_source_object_id Customer Account ID
   * @param p_notes Note text max 2000 chars
   * @param p_note_type Note type CALL DUNNING PROMISE PAYMENT DISPUTE EMAIL GENERAL
   * @param x_return_status Return status S E or U
   * @param x_jtf_note_id Created note ID
   * @param x_msg_count Number of messages
   * @param x_msg_data Error message text
   * @rep:scope public
   * @rep:lifecycle active
   * @rep:displayname Create Collections Note
   * @rep:category BUSINESS_ENTITY AR_CUSTOMER
   */;

  PROCEDURE GET_CUSTOMER_PROFILE(
    p_cust_account_id           IN  NUMBER,
    x_cust_account_profile_id   OUT NUMBER,
    x_object_version_number     OUT NUMBER,
    x_credit_hold               OUT VARCHAR2,
    x_return_status             OUT VARCHAR2,
    x_msg_data                  OUT VARCHAR2
  )
  /*#
   * Get customer profile ID and object version number.
   * @param p_cust_account_id Customer Account ID
   * @param x_cust_account_profile_id Profile ID from HZ_CUSTOMER_PROFILES
   * @param x_object_version_number Object version for optimistic locking
   * @param x_credit_hold Current credit hold flag Y or N
   * @param x_return_status Return status S E or U
   * @param x_msg_data Error message
   * @rep:scope public
   * @rep:lifecycle active
   * @rep:displayname Get Customer Profile
   * @rep:category BUSINESS_ENTITY AR_CUSTOMER
   */;

END XX_COLLECTIONS_REST_PKG;
/
PLSEOF

# --- XX_ORDER_HOLDS_PKG ---
cat > $WORK_DIR/XX_ORDER_HOLDS_PKG.pls << 'PLSEOF'
CREATE OR REPLACE PACKAGE XX_ORDER_HOLDS_PKG
AS
/* $Header: XX_ORDER_HOLDS_PKG.pls 120.1 2026/03/07 12:00:00 applmgr ship $ */
/*#
 * Order Holds Management API.
 * Apply and release order holds at customer level.
 * @rep:scope public
 * @rep:product ONT
 * @rep:displayname Order Holds Management
 * @rep:category BUSINESS_ENTITY ONT_SALES_ORDER
 * @rep:lifecycle active
 * @rep:compatibility S
 */

  PROCEDURE APPLY_HOLDS(
    p_cust_account_id IN  NUMBER,
    p_hold_id         IN  NUMBER   DEFAULT 1,
    p_hold_comment    IN  VARCHAR2 DEFAULT 'Collections hold applied',
    x_return_status   OUT NOCOPY VARCHAR2,
    x_msg_count       OUT NOCOPY NUMBER,
    x_msg_data        OUT NOCOPY VARCHAR2,
    x_orders_held     OUT NOCOPY NUMBER
  )
  /*#
   * Apply customer-level order hold to all open orders.
   * @param p_cust_account_id Customer account ID
   * @param p_hold_id Hold definition ID default 1
   * @param p_hold_comment Hold comment
   * @param x_return_status Return status S E or U
   * @param x_msg_count Number of messages
   * @param x_msg_data Error message text
   * @param x_orders_held Number of orders held
   * @rep:scope public
   * @rep:lifecycle active
   * @rep:displayname Apply Order Holds
   * @rep:category BUSINESS_ENTITY ONT_SALES_ORDER
   */;

  PROCEDURE RELEASE_HOLDS(
    p_cust_account_id IN  NUMBER,
    p_hold_id         IN  NUMBER   DEFAULT 1,
    p_release_reason  IN  VARCHAR2 DEFAULT 'AR_APPROVE',
    x_return_status   OUT NOCOPY VARCHAR2,
    x_msg_count       OUT NOCOPY NUMBER,
    x_msg_data        OUT NOCOPY VARCHAR2,
    x_orders_released OUT NOCOPY NUMBER
  )
  /*#
   * Release customer-level order hold from all held orders.
   * @param p_cust_account_id Customer account ID
   * @param p_hold_id Hold definition ID default 1
   * @param p_release_reason Release reason code default AR_APPROVE
   * @param x_return_status Return status S E or U
   * @param x_msg_count Number of messages
   * @param x_msg_data Error message text
   * @param x_orders_released Number of orders released
   * @rep:scope public
   * @rep:lifecycle active
   * @rep:displayname Release Order Holds
   * @rep:category BUSINESS_ENTITY ONT_SALES_ORDER
   */;

END XX_ORDER_HOLDS_PKG;
/
PLSEOF

# --- XX_COLLECTIONS_TASK_PKG ---
cat > $WORK_DIR/XX_COLLECTIONS_TASK_PKG.pls << 'PLSEOF'
CREATE OR REPLACE PACKAGE XX_COLLECTIONS_TASK_PKG
AS
/* $Header: XX_COLLECTIONS_TASK_PKG.pls 120.1 2026/03/17 12:00:00 applmgr ship $ */
/*#
 * Collections Task Management API.
 * Create collections follow-up tasks in Oracle EBS.
 * @rep:scope public
 * @rep:product AR
 * @rep:displayname Collections Task Management
 * @rep:category BUSINESS_ENTITY AR_CUSTOMER
 * @rep:lifecycle active
 * @rep:compatibility S
 */

  PROCEDURE CREATE_TASK(
    p_cust_account_id  IN  NUMBER,
    p_task_name        IN  VARCHAR2 DEFAULT 'Collections Follow-up',
    p_task_notes       IN  VARCHAR2 DEFAULT NULL,
    p_due_date         IN  VARCHAR2 DEFAULT NULL,
    x_return_status    OUT NOCOPY VARCHAR2,
    x_msg_count        OUT NOCOPY NUMBER,
    x_msg_data         OUT NOCOPY VARCHAR2,
    x_task_id          OUT NOCOPY NUMBER
  )
  /*#
   * Create a collections follow-up task linked to a customer account.
   * @param p_cust_account_id Customer Account ID
   * @param p_task_name Task name or subject
   * @param p_task_notes Task description
   * @param p_due_date Due date in YYYY-MM-DD format
   * @param x_return_status Return status S E or U
   * @param x_msg_count Number of messages
   * @param x_msg_data Error message text
   * @param x_task_id Created task ID
   * @rep:scope public
   * @rep:lifecycle active
   * @rep:displayname Create Collections Task
   * @rep:category BUSINESS_ENTITY AR_CUSTOMER
   */;

END XX_COLLECTIONS_TASK_PKG;
/
PLSEOF

# Set LIBPATH (required by irep_parser per Oracle docs)
export LIBPATH=$LIBPATH:$FMW_HOME/webtier/lib

# Parse and load each package
for PKG in XX_COLLECTIONS_REST_PKG XX_ORDER_HOLDS_PKG XX_COLLECTIONS_TASK_PKG; do
  echo ""
  echo "  --- $PKG ---"
  cp $WORK_DIR/${PKG}.pls $FND_TOP/patch/115/sql/
  cd $WORK_DIR

  echo "  Running irep_parser.pl..."
  PARSER_LOG=$WORK_DIR/${PKG}_parser.log
  $PERL $IREP_PARSER \
    -g -v \
    -outdir=$WORK_DIR \
    -username=sysadmin \
    fnd:patch/115/sql:${PKG}.pls:120.1=$WORK_DIR/${PKG}.pls \
    > $PARSER_LOG 2>&1
  PARSER_EXIT=$?
  echo "  Parser exit code: $PARSER_EXIT"

  ILDT_FILE=$(ls $WORK_DIR/${PKG}*.ildt 2>/dev/null | head -1)
  if [ -z "$ILDT_FILE" ]; then
    echo "  ERROR: No .ildt generated for $PKG — parser log:"
    cat $PARSER_LOG | sed 's/^/    /'
    continue
  fi
  echo "  Generated: $ILDT_FILE"

  echo "  Running FNDLOAD upload..."
  $FND_TOP/bin/FNDLOAD apps/${APPS_PWD} 0 Y UPLOAD \
    $FND_TOP/patch/115/import/wfirep.lct \
    "$ILDT_FILE" \
    - WARNING=YES UPLOAD_MODE=REPLACE CUSTOM_MODE=FORCE 2>&1 | tail -5

  echo "  $PKG registered ✓"
done

echo ""

# ══════════════════════════════════════════════════════════════════════════════
# STEP 3: Deploy REST services via iSG
# ══════════════════════════════════════════════════════════════════════════════
echo "=== Step 3: Deploying REST services ==="
cd $ISG_DIR

deploy_service() {
  local IREP_NAME=$1
  local ALIAS=$2
  echo "  Deploying $ALIAS..."
  $ANT -f $ISG_DIR/isgDesigner.xml \
    -Dactions=deploy \
    -DserviceType=REST \
    -DirepNames="$IREP_NAME" \
    -Dalias=$ALIAS \
    -Dpolicy=BASIC \
    -Dverbose=ON \
    2>&1 | grep -E "Class Id|Error|Exception|already deployed|SUCCESSFUL" || true
}

deploy_service "XX_COLLECTIONS_REST_PKG"  "XxCollectionsRestPkg"
deploy_service "XX_ORDER_HOLDS_PKG"       "XxOrderHoldsPkg"
deploy_service "XX_COLLECTIONS_TASK_PKG"  "XxCollectionsTaskPkg"
deploy_service "HZ_CUSTOMER_PROFILE_V2PUB" "HzCustomerProfileV2"

echo ""

# ══════════════════════════════════════════════════════════════════════════════
# STEP 4: Grant GLOBAL access
# ══════════════════════════════════════════════════════════════════════════════
echo "=== Step 4: Granting GLOBAL access ==="
for PKG in XX_COLLECTIONS_REST_PKG XX_ORDER_HOLDS_PKG XX_COLLECTIONS_TASK_PKG; do
  $ANT -f $ISG_DIR/isgDesigner.xml \
    -Dactions=create \
    -DserviceType=GRANT \
    -DirepNames=$PKG \
    -DgranteeType=GLOBAL \
    -Dverbose=ON \
    2>&1 | grep -E "Grant|grant|Error|SUCCESSFUL" || true
done
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# STEP 5: Verify
# ══════════════════════════════════════════════════════════════════════════════
echo "=== Step 5: Verification ==="
echo "  iRep status:"
sqlplus -s apps/${APPS_PWD} <<'SQLEOF'
SET LINESIZE 200 PAGESIZE 20 HEADING ON FEEDBACK OFF
COL class_name FORMAT A60
COL deployed_flag FORMAT A5
SELECT class_name, deployed_flag
FROM fnd_irep_classes
WHERE UPPER(class_name) LIKE '%XX_COLLECTIONS%'
   OR UPPER(class_name) LIKE '%XX_ORDER_HOLDS%'
ORDER BY class_name;
EXIT;
SQLEOF

echo ""
echo "  WADL endpoints:"
for ALIAS in XxCollectionsRestPkg XxOrderHoldsPkg XxCollectionsTaskPkg HzCustomerProfileV2; do
  HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
    -u sysadmin:${APPS_PWD} \
    "${EBS_SCHEME:-http}://${EBS_VERIFY_HOST:-localhost}:${EBS_VERIFY_PORT:-8000}/webservices/rest/${ALIAS}/?WADL" 2>/dev/null)
  if [ "$HTTP_CODE" = "200" ]; then
    echo "    $ALIAS: ✓ HTTP 200"
  else
    echo "    $ALIAS: ✗ HTTP $HTTP_CODE"
  fi
done

echo ""
echo "============================================"
echo "  Deployment complete!"
echo "============================================"
