#!/usr/bin/env python3
"""
EBS Collections Actions Lambda
READ  -> Redshift analytical views
WRITE -> Oracle EBS ISG REST API (port 8000, deployed via iRep)

All write-back actions use pure ISG REST — NO SSM RunCommand.

Deployed REST services (registered via iRep):
  XxCollectionsRestPkg -> XX_COLLECTIONS_REST_PKG (credit holds, notes)
  XxOrderHoldsPkg      -> XX_ORDER_HOLDS_PKG      (order holds)
  XxCollectionsTaskPkg -> XX_COLLECTIONS_TASK_PKG  (task creation)
"""

import json
import os
import time
import boto3
import logging
import requests
from requests.auth import HTTPBasicAuth

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# -- Config --------------------------------------------------------------------
CLUSTER_ID  = os.environ.get('CLUSTER_ID',  'oracle-ebs-redshift-zetl')
DATABASE    = os.environ.get('DATABASE',    'ebsanalytics')
DB_USER     = os.environ.get('DB_USER',     'admin')
AWS_REGION  = os.environ.get('AWS_REGION_NAME', 'us-east-1')
SECRET_NAME = os.environ.get('SECRET_NAME')  # Set by deploy.sh from deploy-config.json

EBS_HOST    = os.environ.get('EBS_HOST')
EBS_PORT    = os.environ.get('EBS_PORT',    '8000')
EBS_SCHEME  = 'https' if EBS_PORT == '443' else 'http'
EBS_BASE    = f"{EBS_SCHEME}://{EBS_HOST}:{EBS_PORT}/webservices/rest"

_redshift   = None
_ebs_creds  = None


# -- AWS / EBS clients ---------------------------------------------------------
def get_redshift():
    global _redshift
    if _redshift is None:
        _redshift = boto3.client('redshift-data', region_name=AWS_REGION)
    return _redshift


def get_ebs_creds():
    """Return (username, password) for EBS REST calls from Secrets Manager.

    Expected secret JSON shape:
        {"username": "<user>", "password": "<pass>"}

    For backward compatibility, also supports the legacy shape:
        {"sysadmin": "<password>"}  # username defaults to "sysadmin"
    """
    global _ebs_creds
    if _ebs_creds is None:
        sm = boto3.client('secretsmanager', region_name=AWS_REGION)
        secret = sm.get_secret_value(SecretId=SECRET_NAME)
        data = json.loads(secret['SecretString'])

        # Preferred shape: explicit username/password keys
        if 'username' in data and 'password' in data:
            _ebs_creds = (data['username'], data['password'])
        # Legacy shape: {"sysadmin": "<password>"} — username is the key, value is password
        elif 'sysadmin' in data:
            _ebs_creds = ('sysadmin', data['sysadmin'])
        else:
            raise Exception(
                f"Secret {SECRET_NAME} must contain either {{username, password}} or "
                f"{{sysadmin: <password>}} keys"
            )
    return _ebs_creds


# -- EBS REST helpers ----------------------------------------------------------
def ebs_rest_post(service_alias, operation, payload, responsibility='RECEIVABLES_MANAGER',
                  resp_application='AR', org_id='204'):
    """
    POST to EBS ISG REST endpoint.
    URL pattern: http://<host>:<port>/webservices/rest/<alias>/<operation>/
    Body: JSON with InputParameters wrapper including RESTHeader
    """
    user, pwd = get_ebs_creds()
    url = f"{EBS_BASE}/{service_alias}/{operation}/"

    body = {
        "InputParameters": {
            "RESTHeader": {
                "Responsibility": responsibility,
                "RespApplication": resp_application,
                "SecurityGroup": "STANDARD",
                "NLSLanguage": "AMERICAN",
                "Org_Id": org_id
            },
            **payload
        }
    }

    logger.info(f"EBS REST POST {url}")
    resp = requests.post(
        url,
        json=body,
        auth=HTTPBasicAuth(user, pwd),
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        timeout=30,
        verify=True
    )

    logger.info(f"EBS REST response: {resp.status_code} - {resp.text[:500]}")

    if resp.status_code not in (200, 201):
        raise Exception(f"EBS REST error {resp.status_code}: {resp.text[:300]}")

    return resp.json()


# -- Redshift helpers ----------------------------------------------------------
def redshift_query(sql):
    rs = get_redshift()
    resp = rs.execute_statement(
        ClusterIdentifier=CLUSTER_ID, Database=DATABASE, DbUser=DB_USER, Sql=sql
    )
    stmt_id = resp['Id']
    while True:
        s = rs.describe_statement(Id=stmt_id)
        if s['Status'] == 'FINISHED':
            break
        if s['Status'] in ('FAILED', 'ABORTED'):
            raise Exception(f"Redshift query failed: {s.get('Error')}")
        time.sleep(0.5)  # nosemgrep: arbitrary-sleep — required for AWS async API polling
    result = rs.get_statement_result(Id=stmt_id)
    cols = [c['name'] for c in result['ColumnMetadata']]
    rows = []
    for record in result['Records']:
        row = {}
        for i, col in enumerate(cols):
            v = record[i]
            if 'stringValue' in v:   row[col] = v['stringValue']
            elif 'longValue' in v:   row[col] = v['longValue']
            elif 'doubleValue' in v: row[col] = v['doubleValue']
            elif 'isNull' in v:      row[col] = None
            else:                    row[col] = str(v)
        rows.append(row)
    return rows



# -- READ actions (Redshift) ---------------------------------------------------
def get_overdue_customers(params):
    min_amount = float(params.get('min_amount', 0))
    limit      = int(params.get('limit', 50))

    sql = f"""SELECT customer_id,
               CAST(total_invoices AS INT)      AS total_invoices,
               CAST(overdue_invoices AS INT)    AS overdue_invoices,
               CAST(total_outstanding AS FLOAT) AS total_outstanding,
               CAST(overdue_amount AS FLOAT)    AS overdue_amount,
               CAST(avg_invoice_amount AS FLOAT) AS avg_invoice_amount,
               risk_category
        FROM customer_payment_behavior
        WHERE CAST(overdue_amount AS FLOAT) > {min_amount}
        ORDER BY CAST(overdue_amount AS FLOAT) DESC
        LIMIT {limit}
    """
    customers = redshift_query(sql)

    aging_sql = """
        SELECT aging_bucket,
               CAST(invoice_count AS INT)    AS invoice_count,
               CAST(total_amount AS FLOAT)   AS total_amount,
               CAST(unique_customers AS INT) AS unique_customers
        FROM ar_aging_analysis
        ORDER BY CASE aging_bucket
            WHEN 'OVERDUE' THEN 1 WHEN 'DUE_THIS_WEEK' THEN 2
            WHEN 'DUE_THIS_MONTH' THEN 3 ELSE 4 END
    """
    aging = redshift_query(aging_sql)

    return {
        'success': True,
        'customers': customers,
        'customer_count': len(customers),
        'aging_summary': aging
    }


def get_customer_details(params):
    cust_id  = params.get('cust_account_id')
    acct_num = params.get('account_number')

    if not cust_id and not acct_num:
        return {'success': False, 'error': 'Provide cust_account_id or account_number'}

    # Both customer_id and account_number must be numeric.
    # We validate by casting to int — any non-numeric input raises ValueError
    # and is rejected. This avoids string-based SQL interpolation entirely.
    try:
        if cust_id is not None:
            customer_id_value = int(cust_id)
        else:
            customer_id_value = int(acct_num)
    except (TypeError, ValueError):
        return {
            'success': False,
            'error': 'cust_account_id and account_number must be numeric'
        }

    sql = f"""
        SELECT customer_id,
               CAST(total_invoices AS INT)      AS total_invoices,
               CAST(overdue_invoices AS INT)    AS overdue_invoices,
               CAST(total_outstanding AS FLOAT) AS total_outstanding,
               CAST(overdue_amount AS FLOAT)    AS overdue_amount,
               CAST(avg_invoice_amount AS FLOAT) AS avg_invoice_amount,
               risk_category
        FROM customer_payment_behavior
        WHERE customer_id = {customer_id_value}
        LIMIT 1
    """  # nosec B608 - customer_id_value is a validated int, not user-controlled string
    rows = redshift_query(sql)
    return {'success': True, 'customer': rows[0] if rows else None, 'found': len(rows) > 0}


# -- WRITE actions (ALL via EBS ISG REST) --------------------------------------

def _update_credit_hold(cust_account_id, credit_hold_flag, reason='',
                        cust_account_profile_id=None, object_version_number=None):
    """
    Update credit hold via ISG REST -> XxCollectionsRestPkg/update_credit_hold/
    Calls XX_COLLECTIONS_REST_PKG.UPDATE_CREDIT_HOLD on EBS.
    """
    # Fetch profile info from EBS if not provided
    if cust_account_profile_id is None:
        profile_info = get_customer_profile_info(cust_account_id)
        cust_account_profile_id = profile_info.get('cust_account_profile_id')
        object_version_number   = profile_info.get('object_version_number')
        logger.info(f"Profile lookup: profile_id={cust_account_profile_id}, ovn={object_version_number}")

    if not cust_account_profile_id:
        return {
            'success': False,
            'error': f'Could not resolve cust_account_profile_id for account {cust_account_id}',
            'cust_account_id': cust_account_id
        }

    try:
        payload = {
            "P_CUST_ACCOUNT_PROFILE_ID": int(cust_account_profile_id),
            "P_CUST_ACCOUNT_ID": int(cust_account_id),
            "P_CREDIT_HOLD": credit_hold_flag,
            "P_OBJECT_VERSION_NUMBER": int(object_version_number)
        }

        data = ebs_rest_post('XxCollectionsRestPkg', 'update_credit_hold', payload)
        out = data.get('OutputParameters', {})
        status = out.get('X_RETURN_STATUS', 'E')
        msg = out.get('X_MSG_DATA', '')
        new_ovn = out.get('X_OBJECT_VERSION_NUMBER', object_version_number)

        success = (status == 'S')

        return {
            'success': success,
            'cust_account_id': cust_account_id,
            'cust_account_profile_id': cust_account_profile_id,
            'credit_hold': credit_hold_flag,
            'return_status': status,
            'message': msg,
            'object_version_number': new_ovn,
            'reason': reason
        }
    except Exception as e:
        logger.error(f"_update_credit_hold error: {e}")
        raise


def get_customer_profile_info(cust_account_id):
    """
    Fetch cust_account_profile_id and object_version_number from EBS REST.
    Calls XxCollectionsRestPkg/get_customer_profile/ which queries HZ_CUSTOMER_PROFILES.
    """
    try:
        payload = {"P_CUST_ACCOUNT_ID": int(cust_account_id)}
        data = ebs_rest_post('XxCollectionsRestPkg', 'get_customer_profile', payload)
        out = data.get('OutputParameters', {})
        if out.get('X_RETURN_STATUS') == 'S':
            profile_id = out.get('X_CUST_ACCOUNT_PROFILE_ID')
            ovn = out.get('X_OBJECT_VERSION_NUMBER')
            logger.info(f"EBS profile lookup success: profile_id={profile_id}, ovn={ovn}")
            return {'cust_account_profile_id': profile_id, 'object_version_number': ovn}
        else:
            logger.warning(f"EBS profile lookup failed: {out.get('X_MSG_DATA')}")
    except Exception as e:
        logger.warning(f"EBS profile REST call failed: {e}")

    return {'cust_account_profile_id': None, 'object_version_number': None}


def place_credit_hold(params):
    """Place customer on credit hold via ISG REST -> XxCollectionsRestPkg/update_credit_hold/"""
    cust_account_id         = params.get('cust_account_id')
    reason                  = params.get('reason', 'Collections - overdue balance')
    cust_account_profile_id = params.get('cust_account_profile_id')
    object_version_number   = params.get('object_version_number')
    if not cust_account_id:
        return {'success': False, 'error': 'cust_account_id required'}
    try:
        result = _update_credit_hold(cust_account_id, 'Y', reason,
                                     cust_account_profile_id, object_version_number)
        result['action'] = 'place_credit_hold'
        return result
    except Exception as e:
        logger.error(f"place_credit_hold error: {e}")
        return {'success': False, 'error': str(e), 'action': 'place_credit_hold'}


def release_credit_hold(params):
    """Release credit hold via ISG REST -> XxCollectionsRestPkg/update_credit_hold/"""
    cust_account_id         = params.get('cust_account_id')
    cust_account_profile_id = params.get('cust_account_profile_id')
    object_version_number   = params.get('object_version_number')
    if not cust_account_id:
        return {'success': False, 'error': 'cust_account_id required'}
    try:
        result = _update_credit_hold(cust_account_id, 'N', 'Collections hold released',
                                     cust_account_profile_id, object_version_number)
        result['action'] = 'release_credit_hold'
        return result
    except Exception as e:
        logger.error(f"release_credit_hold error: {e}")
        return {'success': False, 'error': str(e), 'action': 'release_credit_hold'}



def create_collections_note(params):
    """
    Create collections note via ISG REST -> XxCollectionsRestPkg/create_collections_note/
    Calls XX_COLLECTIONS_REST_PKG.CREATE_COLLECTIONS_NOTE on EBS.
    Note type mapping (friendly -> IEX lookup) is handled by the PL/SQL package.
    """
    cust_account_id = params.get('cust_account_id')
    note_text       = params.get('note_text', '')
    note_type       = params.get('note_type', 'CALL')
    if not cust_account_id or not note_text:
        return {'success': False, 'error': 'cust_account_id and note_text required'}

    try:
        payload = {
            "P_SOURCE_OBJECT_ID": int(cust_account_id),
            "P_NOTES": note_text[:2000],
            "P_NOTE_TYPE": note_type
        }

        data = ebs_rest_post('XxCollectionsRestPkg', 'create_collections_note', payload)
        out = data.get('OutputParameters', {})
        status  = out.get('X_RETURN_STATUS', 'E')
        note_id = out.get('X_JTF_NOTE_ID')
        msg     = out.get('X_MSG_DATA', '')

        success = (status == 'S')

        return {
            'success': success,
            'action': 'create_collections_note',
            'cust_account_id': cust_account_id,
            'note_id': note_id,
            'message': msg if not success else f'Note created with ID {note_id}'
        }
    except Exception as e:
        logger.error(f"create_collections_note error: {e}")
        return {'success': False, 'error': str(e), 'action': 'create_collections_note'}


def apply_order_holds(params):
    """Place OM order holds on all open orders for a customer via ISG REST -> XxOrderHoldsPkg/apply_holds/"""
    cust_account_id = params.get('cust_account_id')
    hold_id = params.get('hold_id', 1)
    comment = params.get('comment', 'Collections hold applied by AI agent')
    if not cust_account_id:
        return {'success': False, 'error': 'cust_account_id required'}

    try:
        payload = {
            "P_CUST_ACCOUNT_ID": int(cust_account_id),
            "P_HOLD_ID": int(hold_id),
            "P_HOLD_COMMENT": comment
        }

        data = ebs_rest_post('XxOrderHoldsPkg', 'apply_holds', payload,
                             responsibility='ORDER_MGMT_SUPER_USER',
                             resp_application='ONT')
        out = data.get('OutputParameters', {})
        status = out.get('X_RETURN_STATUS', '')
        msg_data = out.get('X_MSG_DATA', '')
        applied = out.get('X_ORDERS_HELD', '0')
        try:
            applied = int(applied) if applied and str(applied) != 'null' else 0
        except (ValueError, TypeError):
            applied = 0

        if status == 'S':
            return {
                'success': True,
                'action': 'apply_order_holds',
                'cust_account_id': cust_account_id,
                'orders_held': applied,
                'message': f'{applied} orders placed on hold'
            }
        err = msg_data or 'Orders already on hold for this customer'
        return {'success': False, 'error': err, 'action': 'apply_order_holds'}
    except Exception as e:
        logger.error(f"apply_order_holds error: {e}")
        return {'success': False, 'error': str(e), 'action': 'apply_order_holds'}


def release_order_holds(params):
    """Release OM order holds for a customer via ISG REST -> XxOrderHoldsPkg/release_holds/"""
    cust_account_id = params.get('cust_account_id')
    hold_id = params.get('hold_id', 1)
    release_reason = params.get('release_reason', 'AR_APPROVE')
    if not cust_account_id:
        return {'success': False, 'error': 'cust_account_id required'}

    try:
        payload = {
            "P_CUST_ACCOUNT_ID": int(cust_account_id),
            "P_HOLD_ID": int(hold_id),
            "P_RELEASE_REASON": release_reason
        }

        data = ebs_rest_post('XxOrderHoldsPkg', 'release_holds', payload,
                             responsibility='ORDER_MGMT_SUPER_USER',
                             resp_application='ONT')
        out = data.get('OutputParameters', {})
        status = out.get('X_RETURN_STATUS', '')
        msg_data = out.get('X_MSG_DATA', '')
        released = out.get('X_ORDERS_RELEASED', '0')
        try:
            released = int(released) if released and str(released) != 'null' else 0
        except (ValueError, TypeError):
            released = 0

        if status == 'S':
            return {
                'success': True,
                'action': 'release_order_holds',
                'cust_account_id': cust_account_id,
                'holds_released': released,
                'message': 'No active order holds found' if released == 0 else f'Order holds released for {released} hold source(s)'
            }
        return {'success': False, 'error': msg_data or f'EBS status={status}', 'action': 'release_order_holds'}
    except Exception as e:
        logger.error(f"release_order_holds error: {e}")
        return {'success': False, 'error': str(e), 'action': 'release_order_holds'}




def _lookup_customer_data(cust_account_id):
    """
    Look up customer overdue amount, name, and invoice count from Redshift.
    Used by send_dunning_letter and send_payment_reminder when the agent
    doesn't pass these values (which is the common case).
    Joins with ar.hz_cust_accounts to get the customer/account name.
    """
    try:
        sql = f"""SELECT cpb.customer_id,
                   COALESCE(hca.account_name, 'Customer ' || cpb.customer_id) AS customer_name,
                   CAST(cpb.total_invoices AS INT) AS total_invoices,
                   CAST(cpb.overdue_invoices AS INT) AS overdue_invoices,
                   CAST(cpb.total_outstanding AS FLOAT) AS total_outstanding,
                   CAST(cpb.overdue_amount AS FLOAT) AS overdue_amount,
                   cpb.risk_category
            FROM customer_payment_behavior cpb
            LEFT JOIN ar.hz_cust_accounts hca
              ON cpb.customer_id::varchar = hca.cust_account_id::varchar
            WHERE cpb.customer_id = {int(cust_account_id)}
            LIMIT 1
        """
        rows = redshift_query(sql)
        if rows:
            return rows[0]
    except Exception as e:
        logger.warning(f"Customer data lookup failed for {cust_account_id}: {e}")
    return {}


def send_dunning_letter(params):
    """
    Generate a formatted dunning letter using Bedrock, store as EBS note via ISG REST,
    and optionally send via SES. Level 3 also places a credit hold.
    """
    cust_account_id  = params.get('cust_account_id')
    dunning_level    = int(params.get('dunning_level', 1))
    customer_name    = params.get('customer_name', '')
    overdue_amount   = params.get('overdue_amount', 0)
    contact_email    = params.get('contact_email', '')
    if not cust_account_id:
        return {'success': False, 'error': 'cust_account_id required'}

    # Auto-lookup customer data from Redshift if not provided by agent
    if not overdue_amount or float(overdue_amount) == 0 or not customer_name:
        cust_data = _lookup_customer_data(cust_account_id)
        if not overdue_amount or float(overdue_amount) == 0:
            overdue_amount = cust_data.get('overdue_amount', 0)
        if not customer_name:
            customer_name = cust_data.get('customer_name', f'Customer {cust_account_id}')
    overdue_amount = float(overdue_amount)

    level_labels = {1: 'First Notice', 2: 'Second Notice / Warning', 3: 'Final Notice - Immediate Action Required'}
    level_label  = level_labels.get(dunning_level, 'Notice')

    # Generate letter body
    letter_text = _generate_dunning_letter_text(
        customer_name, cust_account_id, overdue_amount, dunning_level, level_label
    )

    # Store letter as DUNNING note in EBS via ISG REST
    note_result = create_collections_note({
        'cust_account_id': cust_account_id,
        'note_text': letter_text[:2000],
        'note_type': 'DUNNING'
    })

    # Send via SES if email provided
    email_result = None
    if contact_email:
        email_result = _send_ses_email(
            to_address=contact_email,
            subject=f"Payment Overdue Notice - {level_label}",
            body_text=letter_text,
            body_html=_letter_to_html(letter_text, level_label)
        )

    # Level 3 = final notice -> also place credit hold via ISG REST
    hold_result = None
    if dunning_level >= 3:
        hold_result = place_credit_hold({
            'cust_account_id': cust_account_id,
            'reason': f'Final dunning notice - Level {dunning_level}'
        })

    return {
        'success': note_result.get('success', False),
        'action': 'send_dunning_letter',
        'cust_account_id': cust_account_id,
        'dunning_level': dunning_level,
        'letter_preview': letter_text[:300] + '...',
        'note_created': note_result,
        'email_sent': email_result,
        'credit_hold_placed': hold_result
    }


def _generate_dunning_letter_text(customer_name, cust_account_id, overdue_amount,
                                   dunning_level, level_label):
    """Generate dunning letter body"""
    import datetime
    today = datetime.date.today().strftime('%B %d, %Y')

    escalation_note = {
        1: "We kindly request that you arrange payment at your earliest convenience.",
        2: "Failure to settle this balance within 7 days may result in suspension of credit facilities.",
        3: "Unless payment is received within 48 hours, we will place your account on credit hold and refer this matter to our collections team."
    }.get(dunning_level, "Please contact us immediately.")

    letter = f"""Date: {today}

Dear {customer_name},

RE: OVERDUE ACCOUNT NOTICE - {level_label}
Account Reference: {cust_account_id}

We are writing to bring to your attention that your account has an outstanding overdue balance of ${overdue_amount:,.2f} which is now past due.

{escalation_note}

To make a payment or discuss a payment arrangement, please contact our Accounts Receivable team immediately.

If you have already made payment, please disregard this notice and accept our apologies for any inconvenience.

Yours sincerely,
Accounts Receivable Team
Oracle EBS Collections"""

    return letter


def _letter_to_html(letter_text, subject):
    """Wrap plain text letter in simple HTML for email"""
    body = letter_text.replace('\n', '<br>')
    return f"""<html><body style="font-family:Arial,sans-serif;max-width:600px;margin:auto;padding:20px">
<h2 style="color:#c0392b">{subject}</h2>
<hr/>
<p>{body}</p>
<hr/>
<p style="font-size:11px;color:#888">This is an automated message from the Oracle EBS Collections system.</p>
</body></html>"""


def _send_ses_email(to_address, subject, body_text, body_html):
    """Send email via AWS SES"""
    SES_SENDER = os.environ.get('SES_SENDER_EMAIL', 'collections@example.com')
    try:
        ses = boto3.client('ses', region_name=AWS_REGION)
        resp = ses.send_email(
            Source=SES_SENDER,
            Destination={'ToAddresses': [to_address]},
            Message={
                'Subject': {'Data': subject, 'Charset': 'UTF-8'},
                'Body': {
                    'Text': {'Data': body_text, 'Charset': 'UTF-8'},
                    'Html': {'Data': body_html, 'Charset': 'UTF-8'}
                }
            }
        )
        logger.info(f"SES email sent to {to_address}: MessageId={resp['MessageId']}")
        return {'success': True, 'message_id': resp['MessageId'], 'to': to_address}
    except Exception as e:
        logger.error(f"SES send error: {e}")
        return {'success': False, 'error': str(e), 'to': to_address}



def create_collections_task(params):
    """
    Create a JTF collections task via ISG REST -> XxCollectionsTaskPkg/create_task/
    Calls XX_COLLECTIONS_TASK_PKG.CREATE_TASK on EBS.
    """
    cust_account_id = params.get('cust_account_id')
    task_name       = params.get('task_name', 'Collections Follow-up')
    task_notes      = params.get('task_notes', '')
    due_date        = params.get('due_date', '')
    if not cust_account_id:
        return {'success': False, 'error': 'cust_account_id required'}

    import datetime
    if not due_date:
        due_date = (datetime.date.today() + datetime.timedelta(days=7)).strftime('%Y-%m-%d')

    try:
        payload = {
            "P_CUST_ACCOUNT_ID": int(cust_account_id),
            "P_TASK_NAME": task_name[:80],
            "P_TASK_NOTES": task_notes[:2000],
            "P_DUE_DATE": due_date
        }

        data = ebs_rest_post('XxCollectionsTaskPkg', 'create_task', payload)
        out = data.get('OutputParameters', {})
        status  = out.get('X_RETURN_STATUS', 'E')
        task_id = out.get('X_TASK_ID')
        msg     = out.get('X_MSG_DATA', '')

        success = (status == 'S')
        return {
            'success': success,
            'action': 'create_collections_task',
            'cust_account_id': cust_account_id,
            'task_id': task_id,
            'task_name': task_name,
            'due_date': due_date,
            'message': msg if not success else f'Task created with ID {task_id}'
        }
    except Exception as e:
        logger.error(f"create_collections_task error: {e}")
        return {'success': False, 'error': str(e), 'action': 'create_collections_task'}


def send_payment_reminder(params):
    """
    Send a payment reminder email via AWS SES with outstanding balance details.
    Also creates a collections note in EBS via ISG REST to record the contact.
    """
    cust_account_id = params.get('cust_account_id')
    contact_email   = params.get('contact_email', '')
    customer_name   = params.get('customer_name', '')
    overdue_amount  = float(params.get('overdue_amount', 0))
    invoice_count   = int(params.get('invoice_count', 0))
    payment_link    = params.get('payment_link', os.environ.get('PAYMENT_PORTAL_URL', 'https://payments.example.com'))

    if not cust_account_id:
        return {'success': False, 'error': 'cust_account_id required'}
    if not contact_email:
        return {'success': False, 'error': 'contact_email required'}

    # Auto-lookup customer data from Redshift if not provided by agent
    if overdue_amount == 0 or invoice_count == 0 or not customer_name:
        cust_data = _lookup_customer_data(cust_account_id)
        if overdue_amount == 0:
            overdue_amount = float(cust_data.get('overdue_amount', 0))
        if invoice_count == 0:
            invoice_count = int(cust_data.get('overdue_invoices', cust_data.get('total_invoices', 0)))
        if not customer_name:
            customer_name = cust_data.get('customer_name', f'Customer {cust_account_id}')

    import datetime
    today = datetime.date.today().strftime('%B %d, %Y')

    subject = f"Payment Reminder: Outstanding Balance of ${overdue_amount:,.2f}"

    body_text = f"""Dear {customer_name},

This is a friendly reminder that your account has an outstanding balance of ${overdue_amount:,.2f} across {invoice_count} invoice(s).

To view your invoices and make a payment, please visit:
{payment_link}

If you have already arranged payment, please disregard this message.

For queries, please contact our Accounts Receivable team.

Date: {today}
Account: {cust_account_id}

Thank you for your business.
Accounts Receivable Team"""

    body_html = f"""<html><body style="font-family:Arial,sans-serif;max-width:600px;margin:auto;padding:20px">
<h2 style="color:#2c3e50">Payment Reminder</h2>
<p>Dear <strong>{customer_name}</strong>,</p>
<p>This is a friendly reminder that your account has an outstanding balance:</p>
<table style="border-collapse:collapse;width:100%;margin:16px 0">
  <tr style="background:#f2f2f2">
    <td style="padding:10px;border:1px solid #ddd"><strong>Account</strong></td>
    <td style="padding:10px;border:1px solid #ddd">{cust_account_id}</td>
  </tr>
  <tr>
    <td style="padding:10px;border:1px solid #ddd"><strong>Outstanding Balance</strong></td>
    <td style="padding:10px;border:1px solid #ddd;color:#c0392b"><strong>${overdue_amount:,.2f}</strong></td>
  </tr>
  <tr style="background:#f2f2f2">
    <td style="padding:10px;border:1px solid #ddd"><strong>Invoices</strong></td>
    <td style="padding:10px;border:1px solid #ddd">{invoice_count}</td>
  </tr>
  <tr>
    <td style="padding:10px;border:1px solid #ddd"><strong>Date</strong></td>
    <td style="padding:10px;border:1px solid #ddd">{today}</td>
  </tr>
</table>
<p style="text-align:center;margin:24px 0">
  <a href="{payment_link}" style="background:#2980b9;color:white;padding:12px 28px;text-decoration:none;border-radius:4px;font-size:16px">
    Pay Now
  </a>
</p>
<p>If you have already arranged payment, please disregard this message.</p>
<hr/>
<p style="font-size:11px;color:#888">This is an automated message from the Oracle EBS Collections system. Date: {today}</p>
</body></html>"""

    email_result = _send_ses_email(contact_email, subject, body_text, body_html)

    # Log the contact as a collections note in EBS via ISG REST
    note_result = create_collections_note({
        'cust_account_id': cust_account_id,
        'note_text': f"Payment reminder email sent to {contact_email}. Outstanding: ${overdue_amount:,.2f} ({invoice_count} invoices).",
        'note_type': 'EMAIL'
    })

    return {
        'success': email_result.get('success', False),
        'action': 'send_payment_reminder',
        'cust_account_id': cust_account_id,
        'email_sent': email_result,
        'note_created': note_result,
        'overdue_amount': overdue_amount,
        'contact_email': contact_email
    }


# -- Action router -------------------------------------------------------------
ACTIONS = {
    'get_overdue_customers':    get_overdue_customers,
    'get_customer_details':     get_customer_details,
    'place_credit_hold':        place_credit_hold,
    'release_credit_hold':      release_credit_hold,
    'send_dunning_letter':      send_dunning_letter,
    'create_collections_note':  create_collections_note,
    'apply_order_holds':        apply_order_holds,
    'release_order_holds':      release_order_holds,
    'create_collections_task':  create_collections_task,
    'send_payment_reminder':    send_payment_reminder,
}


def lambda_handler(event, context):
    """Direct-invoke Lambda handler for collections actions.

    Invoked by the Strands agent via `lambda:InvokeFunction` with payload
    `{"action": "<name>", "params": {...}}`. Returns `{statusCode, body}` where
    body is a JSON-encoded action result.
    """
    logger.info(f"Event: {json.dumps(event)}")

    action = event.get('action')
    params = event.get('params', {}) or {}

    if not action:
        body = {'success': False, 'error': 'No action specified',
                'available': list(ACTIONS.keys())}
        return {'statusCode': 400, 'body': json.dumps(body)}

    logger.info(f"Action: {action}, Params: {params}")

    handler = ACTIONS.get(action)
    if not handler:
        body = {'success': False, 'error': f'Unknown action: {action}',
                'available': list(ACTIONS.keys())}
        return {'statusCode': 400, 'body': json.dumps(body)}

    try:
        body = handler(params)
        return {'statusCode': 200, 'body': json.dumps(body)}
    except Exception as e:
        logger.error(f"Action {action} failed: {e}", exc_info=True)
        return {
            'statusCode': 500,
            'body': json.dumps({'success': False, 'error': str(e), 'action': action})
        }
