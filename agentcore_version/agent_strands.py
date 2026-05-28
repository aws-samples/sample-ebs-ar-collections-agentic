#!/usr/bin/env python3
"""
Oracle EBS Cash Flow Analytics Agent — Strands SDK on AgentCore Runtime.

Implements three tools (Redshift query, EBS collections action via Lambda,
matplotlib chart generation via AgentCore Code Interpreter) and exposes them
through the Strands Agent + Bedrock AgentCore runtime entrypoint.
"""

import json
import os
import time
import logging
import boto3
from strands import Agent, tool
from strands.models import BedrockModel
from bedrock_agentcore.runtime import BedrockAgentCoreApp
from bedrock_agentcore.tools.code_interpreter_client import code_session

os.environ["BYPASS_TOOL_CONSENT"] = "true" if os.environ.get("LOCAL_DEV") == "1" else os.environ.get("BYPASS_TOOL_CONSENT", "false")

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# Config
AWS_REGION = os.environ.get('AWS_REGION', 'us-east-1')
CLUSTER_ID = os.environ.get('CLUSTER_ID', 'oracle-ebs-redshift-zetl')
DATABASE = os.environ.get('DATABASE', 'ebsanalytics')
DB_USER = os.environ.get('DB_USER', 'admin')
COLLECTIONS_LAMBDA = os.environ.get('COLLECTIONS_LAMBDA', 'ebs-collections-actions')
MODEL_ID = os.environ.get('MODEL_ID', 'us.anthropic.claude-haiku-4-5-20251001-v1:0')

# Lazy AWS clients
_redshift = None
_lambda_client = None

def get_redshift():
    global _redshift
    if _redshift is None:
        _redshift = boto3.client('redshift-data', region_name=AWS_REGION)
    return _redshift

def get_lambda():
    global _lambda_client
    if _lambda_client is None:
        _lambda_client = boto3.client('lambda', region_name=AWS_REGION)
    return _lambda_client


# ── Redshift Schema (for system prompt) ───────────────────────────────────────
REDSHIFT_SCHEMA = """
Available Redshift views/tables in schema 'public':

Analytical Views (pre-built, use these first):
- current_cash_position(metric, amount, invoice_count, as_of_date)
  Rows: OVERDUE_RECEIVABLES, DUE_THIS_WEEK, DUE_THIS_MONTH, FUTURE_RECEIVABLES,
        OVERDUE_PAYABLES, DUE_PAYABLES, NET_CASH_POSITION
- ar_aging_analysis(aging_bucket, invoice_count, total_amount, unique_customers)
  Buckets: OVERDUE, DUE_THIS_WEEK, DUE_THIS_MONTH, FUTURE
- weekly_cash_flow_summary(week_start, week_end, expected_inflows, expected_outflows,
                           net_cash_flow, cumulative_cash_flow)
- customer_payment_behavior(customer_id, customer_name, total_invoices, overdue_invoices,
                            total_outstanding, overdue_amount, avg_invoice_amount,
                            avg_days_to_pay, risk_category)
  risk_category values: HIGH_RISK, HIGH_VALUE, NORMAL
- liquidity_sufficiency_analysis(obligation_type, amount, coverage_ratio,
                                  sufficient, week_start)
  obligation_type: PAYROLL, ACCOUNTS_PAYABLE, TOTAL_OBLIGATIONS
- predictive_cash_flow_forecast(forecast_week, week_start, week_end,
                                 predicted_inflow, predicted_outflow,
                                 net_cash_flow, confidence_score, forecast_basis)

Base Tables (use when views don't cover the question):
- ap_invoices(invoice_id, vendor_id, vendor_name, invoice_date, due_date,
              amount, amount_paid, status, org_id)
- ap_payment_schedules(invoice_id, due_date, amount_remaining, payment_status)
- ar_payment_schedules(customer_id, customer_name, invoice_id, due_date,
                       amount_due, amount_applied, status, days_overdue)
- customer_accounts(customer_id, customer_name, account_number, credit_limit,
                    credit_hold, payment_terms, risk_tier)
- gl_balances(account_code, account_name, period_name, begin_balance,
              period_net_dr, period_net_cr, end_balance)
- po_headers(po_id, vendor_id, vendor_name, creation_date, total_amount,
             status, org_id)
"""

SYSTEM_PROMPT = f"""You are an Oracle EBS Cash Flow Analytics assistant. You help
collections teams analyze AR data and execute collections actions in Oracle EBS.

You have tools to:
1. Query Redshift for analytics (execute_redshift_query)
2. Execute collections actions in EBS (execute_collections_action)
3. Generate charts/visualizations (generate_chart)

{REDSHIFT_SCHEMA}

Rules:
- For analytics questions, write SQL and use execute_redshift_query
- Use the analytical views first before base tables
- Limit results to 100 rows unless asked for more
- When the user asks for a chart, graph, or visualization, first query the data with
  execute_redshift_query, then use generate_chart with complete Python code that includes
  the data inline and saves to 'chart.png'. Use plt.style.use('dark_background').
- For collections actions, use execute_collections_action with the correct action name
- Available actions: get_overdue_customers, get_customer_details, place_credit_hold,
  release_credit_hold, create_collections_note, apply_order_holds, release_order_holds,
  create_collections_task, send_dunning_letter, send_payment_reminder

RESPONSE FORMAT — CRITICAL:
- Be CONCISE. Maximum 3-5 bullet points for analytics responses.
- Use short dollar amounts like $771.5M not $771,500,000.00
- Do NOT repeat raw data the user can already see in a chart.
- After generating a chart, write only 2-3 key insights, not a full analysis.
- CRITICAL: When generate_chart returns [IMAGE]url[/IMAGE], you MUST include that exact tag verbatim at the START of your response before any text. Do not modify, omit, or paraphrase it.
- After a collections action, confirm what was done in one sentence.
- Never write more than 150 words in your final response.

TEST CONTACTS (for demo/testing dunning letters and payment reminders):
Configure test contacts via environment variables: TEST_CONTACT_1_EMAIL, TEST_CONTACT_2_EMAIL, TEST_CONTACT_3_EMAIL
When the user asks to send a dunning letter or payment reminder, use the contact_email parameter.
If no email is specified, ask the user for the recipient email.
"""


# ── Tools ─────────────────────────────────────────────────────────────────────

@tool
def execute_redshift_query(sql: str) -> dict:
    """Execute a SQL query on Amazon Redshift and return the results.
    Use this for any analytics question about AR aging, cash flow, overdue customers,
    payment behavior, forecasting, or liquidity analysis.
    Write proper Redshift SQL using the available views and tables.
    Returns a dict with success, rows (list of dicts), columns, and row_count.
    """
    # Security: validate SQL is read-only and doesn't reach into system catalogs.
    # This is defense-in-depth — the primary control is Redshift IAM auth scoped
    # to a read-only DbUser; this check rejects obvious LLM mistakes/abuse early.
    sql_stripped = sql.strip()
    if not sql_stripped:
        return {'success': False, 'error': 'Empty SQL', 'sql': sql, 'rows': [], 'columns': []}

    first_keyword = sql_stripped.split()[0].upper()
    if first_keyword not in ('SELECT', 'WITH'):
        return {'success': False, 'error': 'Only SELECT queries are permitted', 'sql': sql, 'rows': [], 'columns': []}

    # Block reads against system catalogs and the raw Zero-ETL replica.
    # The agent should only query the analytical views in the `ebsanalytics` DB.
    sql_lower = sql_stripped.lower()
    DENIED_REFERENCES = (
        'pg_catalog',
        'information_schema',
        'svv_',         # Redshift system views
        'stl_',         # Redshift system logs
        'stv_',         # Redshift system tables
        'pg_proc',
        'pg_user',
        'pg_shadow',
        'ebsanalytics_zetl',  # raw Oracle replica — agent should use views, not raw tables
    )
    for denied in DENIED_REFERENCES:
        if denied in sql_lower:
            return {
                'success': False,
                'error': f'SQL references denied object: {denied}',
                'sql': sql, 'rows': [], 'columns': []
            }

    rs = get_redshift()
    try:
        resp = rs.execute_statement(
            ClusterIdentifier=CLUSTER_ID,
            Database=DATABASE,
            DbUser=DB_USER,
            Sql=sql
        )
        stmt_id = resp['Id']

        # Poll with fast initial checks, then back off
        for attempt in range(120):
            s = rs.describe_statement(Id=stmt_id)
            if s['Status'] == 'FINISHED':
                break
            if s['Status'] in ('FAILED', 'ABORTED'):
                return {'success': False, 'error': s.get('Error', 'Query failed'),
                        'sql': sql, 'rows': [], 'columns': []}
            time.sleep(0.3 if attempt < 10 else 1)  # nosemgrep: arbitrary-sleep — required for AWS async API polling

        result = rs.get_statement_result(Id=stmt_id)
        columns = [c['name'] for c in result['ColumnMetadata']]
        rows = []
        for record in result['Records']:
            row = {}
            for i, col in enumerate(columns):
                v = record[i]
                if 'stringValue' in v:    row[col] = v['stringValue']
                elif 'longValue' in v:    row[col] = v['longValue']
                elif 'doubleValue' in v:  row[col] = v['doubleValue']
                elif 'isNull' in v:       row[col] = None
                else:                     row[col] = str(v)
            rows.append(row)

        return {'success': True, 'rows': rows, 'columns': columns,
                'row_count': len(rows), 'sql': sql}

    except Exception as e:
        logger.error(f"Redshift error: {e}")
        return {'success': False, 'error': str(e), 'sql': sql, 'rows': [], 'columns': []}


@tool
def execute_collections_action(action: str, params: dict) -> dict:
    """Execute a collections action in Oracle EBS via the collections Lambda.

    Available actions:
    - get_overdue_customers: params={min_amount: float, limit: int}
    - get_customer_details: params={cust_account_id: int} or {account_number: str}
    - place_credit_hold: params={cust_account_id: int, reason: str}
    - release_credit_hold: params={cust_account_id: int}
    - create_collections_note: params={cust_account_id: int, note_text: str, note_type: str}
      note_type: CALL, EMAIL, PROMISE, LETTER, OTHER
    - apply_order_holds: params={cust_account_id: int, reason: str}
    - release_order_holds: params={cust_account_id: int}
    - create_collections_task: params={cust_account_id: int, task_name: str, description: str, due_days: int}
    - send_dunning_letter: params={cust_account_id: int, dunning_level: int, contact_email: str}
      dunning_level: 1=reminder, 2=warning, 3=final notice
      contact_email: recipient email address (required to send the email)
    - send_payment_reminder: params={cust_account_id: int, contact_email: str}
      contact_email: recipient email address (required)

    Returns the Lambda response with success status and action result.
    """
    ALLOWED_ACTIONS = ['get_overdue_customers', 'get_customer_details', 'place_credit_hold',
                       'release_credit_hold', 'create_collections_note', 'apply_order_holds',
                       'release_order_holds', 'create_collections_task', 'send_dunning_letter',
                       'send_payment_reminder']
    if action not in ALLOWED_ACTIONS:
        return {'success': False, 'error': f'Invalid action: {action}. Allowed: {ALLOWED_ACTIONS}'}

    lam = get_lambda()
    payload = {'action': action, 'params': params}
    try:
        resp = lam.invoke(
            FunctionName=COLLECTIONS_LAMBDA,
            InvocationType='RequestResponse',
            Payload=json.dumps(payload).encode()
        )
        result = json.loads(resp['Payload'].read())

        # Lambda returns {statusCode, body} where body is JSON-encoded action result
        body = result.get('body', '{}')
        if isinstance(body, str):
            body = json.loads(body)
        return body

    except Exception as e:
        logger.error(f"Collections action error: {e}")
        return {'success': False, 'error': str(e), 'action': action}




# ── Code Interpreter (custom tool using code_session + S3 presigned URL) ──────


@tool
def generate_chart(code: str) -> str:
    """Execute Python code to generate a matplotlib chart. The code should create a chart and save it using plt.savefig('chart.png', bbox_inches='tight', dpi=150).
    Use this when the user asks for any chart, graph, pie chart, bar chart, or visualization.
    The data variables from execute_redshift_query results should be embedded directly in the code.

    Args:
        code: Complete Python code including data, imports, and matplotlib chart generation.
              Must save output to 'chart.png'.

    Returns a string with the chart URL or error message.
    """
    import uuid

    s3_client = boto3.client('s3', region_name=AWS_REGION)
    account_id = boto3.client('sts', region_name=AWS_REGION).get_caller_identity()['Account']
    bucket_name = f'cash-flow-charts-{account_id}'
    chart_key = f'charts/chart_{uuid.uuid4().hex[:8]}.png'

    # Ensure bucket exists. The 1-day expiration lifecycle rule is set at
    # deploy time by deploy.sh (the runtime's assumed-role session policy
    # strips s3:PutLifecycleConfiguration even when the role has admin perms).
    # If the bucket somehow doesn't exist (e.g. someone deleted it manually),
    # try to create it but don't attempt lifecycle here.
    try:
        s3_client.head_bucket(Bucket=bucket_name)
    except Exception:
        try:
            if AWS_REGION == 'us-east-1':
                s3_client.create_bucket(Bucket=bucket_name)
            else:
                s3_client.create_bucket(Bucket=bucket_name, CreateBucketConfiguration={'LocationConstraint': AWS_REGION})
            print(f"[generate_chart] created bucket {bucket_name} (lifecycle should be set via deploy.sh)", flush=True)
        except Exception as create_err:
            print(f"[generate_chart] bucket head/create failed: {create_err}", flush=True)

    # Generate presigned PUT URL for upload from sandbox
    presigned_url = s3_client.generate_presigned_url(
        'put_object',
        Params={'Bucket': bucket_name, 'Key': chart_key, 'ContentType': 'image/png'},
        ExpiresIn=300
    )

    # Auto-correct matplotlib code
    if "plt.savefig" not in code and "savefig" not in code:
        code = code.replace("plt.show()", "plt.savefig('chart.png', bbox_inches='tight', dpi=150)") if "plt.show()" in code else code + "\nplt.savefig('chart.png', bbox_inches='tight', dpi=150)\n"
    code = code.replace("plt.close()", "")

    # S3 upload code injected after chart generation (same as sample repo)
    s3_upload_code = f'''
import requests as _req, os as _os
_chart_path = '/tmp/chart.png' if _os.path.exists('/tmp/chart.png') else 'chart.png'
try:
    with open(_chart_path, 'rb') as _f:
        _resp = _req.put('{presigned_url}', data=_f.read(), headers={{'Content-Type': 'image/png'}})
    print("[S3_SUCCESS]" if _resp.status_code == 200 else f"[S3_ERROR]HTTP {{_resp.status_code}}[/S3_ERROR]")
except Exception as _e:
    print(f"[S3_ERROR]{{str(_e)}}[/S3_ERROR]")
'''
    full_code = code + "\n" + s3_upload_code

    try:
        with code_session(AWS_REGION) as session:
            response = session.invoke("executeCode", {
                "code": full_code,
                "language": "python",
            })

            result_text = ""
            for event in response.get("stream", []):
                if "result" in event:
                    result = event["result"]
                    if isinstance(result, dict):
                        if 'structuredContent' in result:
                            result_text += str(result['structuredContent'].get('stdout', ''))
                            result_text += str(result['structuredContent'].get('stderr', ''))
                        else:
                            for item in result.get('content', []):
                                if isinstance(item, dict) and item.get('type') == 'text':
                                    result_text += item.get('text', '')
                    else:
                        result_text += str(result)

        if "[S3_SUCCESS]" in result_text:
            get_url = s3_client.generate_presigned_url(
                'get_object',
                Params={'Bucket': bucket_name, 'Key': chart_key},
                ExpiresIn=3600
            )
            # Lightweight diagnostic — single line per chart, lets us correlate
            # a broken-image symptom in the UI with the actual S3 object that
            # should have been written. The presigned URL itself is omitted
            # from logs (it's a short-lived bearer token).
            print(f"[generate_chart] uploaded s3://{bucket_name}/{chart_key} (presigned GET 1h)", flush=True)
            return f"[IMAGE]{get_url}[/IMAGE]"
        else:
            print(
                f"[generate_chart] S3 upload did NOT report success. "
                f"target=s3://{bucket_name}/{chart_key} "
                f"sandbox_output={result_text[:500]!r}",
                flush=True,
            )
            return f"Chart generation failed. Output: {result_text[:500]}"

    except Exception as e:
        return f"Error: {str(e)}"


# ── AgentCore App + Strands Agent ─────────────────────────────────────────────

app = BedrockAgentCoreApp()

# Create agent at module level with callback_handler=None for streaming
model = BedrockModel(
    model_id=MODEL_ID,
    region_name=AWS_REGION
)

agent = Agent(
    model=model,
    system_prompt=SYSTEM_PROMPT,
    tools=[execute_redshift_query, execute_collections_action, generate_chart],
    callback_handler=None
)


@app.entrypoint
async def invoke(payload, context):
    """AgentCore Runtime entrypoint — receives {"question": "..."} and yields
    the agent's stream events directly.
    """
    question = payload.get('question', '')
    if not question:
        yield json.dumps({'success': False, 'response': 'Please provide a question.'})
        return

    logger.info(f"Processing: {question}")
    # Boundary-only diagnostics — print directly to stdout (with flush) so the
    # markers survive the runtime's logger buffering. Per-event traces were
    # used during the SSE-stream debugging in May 2026; stripped after we
    # confirmed the stream completes naturally to keep CloudWatch noise down.
    # Keep: INVOKE_ENTER (request received), STREAM_DONE (stream finished
    # cleanly), STREAM_EXCEPTION (error path). These give us turn-count
    # observability without flooding logs (~3 lines/request vs ~250).
    def _ev_ck(tag, **kw):
        try:
            extra = " ".join(f"{k}={v}" for k, v in kw.items())
            print(f"[INVOKE] {tag} {extra}", flush=True)
        except Exception:
            pass

    _ev_ck("ENTER", q_len=len(question))

    try:
        event_count = 0
        async for event in agent.stream_async(question):
            event_count += 1
            yield event
        _ev_ck("STREAM_DONE", events=event_count)

    except Exception as e:
        _ev_ck("EXCEPTION", exc_type=type(e).__name__, exc_msg=str(e)[:200])
        logger.error(f"Agent error: {e}", exc_info=True)
        yield json.dumps({
            'success': False,
            'response': f'Agent error: {str(e)}',
            'error': str(e)
        })


if __name__ == "__main__":
    app.run()
