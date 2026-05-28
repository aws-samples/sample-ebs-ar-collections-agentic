#!/usr/bin/env python3
"""
WebSocket Lambda Handler — Strands/AgentCore version

Reads the full SSE response from AgentCore Runtime, parses contentBlockDelta
events to extract clean text AND images from tool results / code interpreter,
then sends a single 'response' message to the frontend.
"""

import json
import os
import boto3
from datetime import datetime

AGENT_ARN = os.environ['AGENT_ARN']
CONNECTIONS_TABLE = os.environ['CONNECTIONS_TABLE']
AWS_REGION = os.environ.get('AWS_REGION', 'us-east-1')

# API Gateway WebSocket max frame is 128KB. Use 120KB as safe limit.
MAX_WS_PAYLOAD = 120000

dynamodb = boto3.resource('dynamodb', region_name=AWS_REGION)
agentcore = boto3.client('bedrock-agentcore', region_name=AWS_REGION)
connections_table = dynamodb.Table(CONNECTIONS_TABLE)


def lambda_handler(event, context):
    route_key = event.get('requestContext', {}).get('routeKey')
    connection_id = event.get('requestContext', {}).get('connectionId')

    print(f"Route: {route_key}, Connection: {connection_id}")

    try:
        if route_key == '$connect':
            return handle_connect(event, connection_id)
        elif route_key == '$disconnect':
            return handle_disconnect(connection_id)
        elif route_key == 'sendMessage':
            return handle_message(event, connection_id)
        elif route_key == 'ping':
            return handle_ping(event, connection_id)
        else:
            return {'statusCode': 400, 'body': 'Unknown route'}
    except Exception as e:
        print(f"Error: {str(e)}")
        return {'statusCode': 500, 'body': f'Error: {str(e)}'}


def handle_connect(event, connection_id):
    try:
        authorizer = event.get('requestContext', {}).get('authorizer', {})
        user_id = authorizer.get('userId', 'unknown')
        email = authorizer.get('email', 'unknown')

        connections_table.put_item(
            Item={
                'connectionId': connection_id,
                'userId': user_id,
                'email': email,
                'connectedAt': datetime.utcnow().isoformat(),
                'ttl': int(datetime.utcnow().timestamp()) + 43200
            }
        )
        return {'statusCode': 200, 'body': 'Connected'}
    except Exception as e:
        print(f"Error in handle_connect: {str(e)}")
        return {'statusCode': 500, 'body': f'Error: {str(e)}'}


def handle_disconnect(connection_id):
    try:
        connections_table.delete_item(Key={'connectionId': connection_id})
        return {'statusCode': 200, 'body': 'Disconnected'}
    except Exception as e:
        print(f"Error in handle_disconnect: {str(e)}")
        return {'statusCode': 500, 'body': f'Error: {str(e)}'}


def handle_ping(event, connection_id):
    try:
        send_to_connection(connection_id, {
            'type': 'pong',
            'timestamp': datetime.utcnow().isoformat()
        })
        return {'statusCode': 200, 'body': 'Pong sent'}
    except Exception as e:
        print(f"Error in handle_ping: {str(e)}")
        return {'statusCode': 500, 'body': f'Error: {str(e)}'}


def parse_sse_stream(resp_body):
    """
    Parse the SSE stream from AgentCore Runtime (Strands SDK).

    Tracks messageStop events to separate intermediate LLM turns from the
    final response, and accumulates text from contentBlockDelta events.
    Only the final turn's text is returned to the client.

    Returns (final_text, images_list).

    images_list is normally empty here — the [IMAGE]url[/IMAGE] tag should
    appear inside the model's text deltas (the system prompt instructs the
    LLM to echo it verbatim) and gets extracted in handle_message.

    Defense in depth: this parser ALSO scans non-text Strands events
    (tool_result blocks, end-of-turn message payloads) for [IMAGE] tags.
    If the LLM forgets to echo the tag, the URL is still in the tool's
    raw return value somewhere in the stream — we surface it from there.
    """
    import re as _re
    IMAGE_TAG_RE = _re.compile(r'\[IMAGE\](https?://[^\[\s\"\']+)\[/IMAGE\]')

    turns_text = []     # list of lists — one per LLM turn
    current_turn = []   # text parts for current turn
    images = []
    seen_urls = set()   # dedupe — same URL can appear in tool result + echoed text

    def _scrape_image_tags(value):
        """Recursively walk JSON-ish structures and pull out any [IMAGE]url[/IMAGE]
        substrings. Bounded to avoid pathological recursion on huge nested events."""
        stack = [(value, 0)]
        max_depth = 10
        while stack:
            v, depth = stack.pop()
            if depth > max_depth:
                continue
            if isinstance(v, str):
                for m in IMAGE_TAG_RE.findall(v):
                    if m not in seen_urls:
                        seen_urls.add(m)
                        images.append(m)
            elif isinstance(v, dict):
                for vv in v.values():
                    stack.append((vv, depth + 1))
            elif isinstance(v, list):
                for vv in v:
                    stack.append((vv, depth + 1))

    for line in resp_body.iter_lines(chunk_size=10):
        if not line:
            continue

        decoded = line.decode('utf-8') if isinstance(line, bytes) else str(line)

        # Strip SSE 'data: ' prefix
        if decoded.startswith('data: '):
            decoded = decoded[6:]
        decoded = decoded.strip()
        if not decoded:
            continue

        # Parse the event as JSON. Strands SDK debug events that aren't valid
        # JSON (Python repr format) are silently dropped here.
        try:
            obj = json.loads(decoded)
        except json.JSONDecodeError:
            continue
        if not isinstance(obj, dict):
            continue

        event = obj.get('event', obj)
        if not isinstance(event, dict):
            continue

        # ── messageStop: end of an LLM turn ──
        if 'messageStop' in event:
            if current_turn:
                turns_text.append(current_turn)
                current_turn = []
            continue

        # ── contentBlockDelta: streaming text tokens ──
        cbd = event.get('contentBlockDelta')
        if cbd and isinstance(cbd, dict):
            delta = cbd.get('delta', {})
            if isinstance(delta, dict):
                text = delta.get('text', '')
                if text:
                    current_turn.append(text)
            continue

        # ── Defense in depth: scrape [IMAGE] tags from ANY other event shape.
        # Tool results are not surfaced as a dedicated wire event by Strands,
        # but they DO appear inside post-turn 'message' payloads and the final
        # 'result' event as part of the conversation history. If the LLM fails
        # to echo the tag in its text response, this catches the URL anyway.
        if 'message' in obj or 'result' in obj or 'toolResult' in event:
            _scrape_image_tags(obj)

    # Flush any remaining text (in case stream ends without a final messageStop)
    if current_turn:
        turns_text.append(current_turn)

    # Use only the LAST turn's text (the final response to the user)
    final_text = ''.join(turns_text[-1]) if turns_text else ''

    print(f"Parsed: {len(turns_text)} turns, final text={len(final_text)} chars, images={len(images)}")
    return final_text, images


def handle_message(event, connection_id):
    try:
        body = json.loads(event.get('body', '{}'))
        question = body.get('question', '')

        # Input validation
        if not question:
            send_to_connection(connection_id, {
                'type': 'error',
                'message': 'No question provided'
            })
            return {'statusCode': 400, 'body': 'No question provided'}
        if len(question) > 2000:
            send_to_connection(connection_id, {
                'type': 'error',
                'message': 'Question must be 1-2000 characters'
            })
            return {'statusCode': 400, 'body': 'Question too long'}

        # Look up user identity from the authoritative source (DynamoDB).
        # The Cognito JWT was validated by the authorizer at $connect time and
        # the user_id was stored in the connections table. We do NOT trust any
        # userId field in the message body — that would let any authenticated
        # user impersonate another.
        user_id = 'unknown'
        try:
            conn_row = connections_table.get_item(Key={'connectionId': connection_id})
            user_id = conn_row.get('Item', {}).get('userId', 'unknown')
        except Exception as e:
            print(f"Warning: failed to look up user for connection {connection_id}: {e}")

        print(f"Processing question for user: {user_id}")

        session_id = f"cash-flow-{connection_id}-session"

        # Tell frontend we're thinking
        send_to_connection(connection_id, {
            'type': 'thinking',
            'message': 'Processing your request...'
        })

        # Invoke AgentCore agent
        response = agentcore.invoke_agent_runtime(
            agentRuntimeArn=AGENT_ARN,
            runtimeSessionId=session_id,
            payload=json.dumps({"question": question}).encode(),
            qualifier='DEFAULT'
        )

        # AgentCore always returns an SSE stream for streaming agents — the
        # iter_lines() path below is the only one we expect to take.
        resp_body = response.get('response')
        if not hasattr(resp_body, 'iter_lines'):
            send_to_connection(connection_id, {
                'type': 'error',
                'message': f'Unexpected agent response type: {type(resp_body).__name__}'
            })
            return {'statusCode': 500, 'body': 'Unexpected agent response type'}

        clean_text, images = parse_sse_stream(resp_body)

        # Extract [IMAGE]url[/IMAGE] tags from text (S3 presigned URLs from
        # generate_chart). The parser already scrapes tool-result events for
        # the same pattern, but the LLM is INSTRUCTED to echo the tag verbatim
        # in its final text — so the user-visible message needs the tag stripped
        # out, and any URLs the LLM did echo need to be merged with the
        # parser's scrapes (deduplicated, order-preserved).
        import re
        image_tag_matches = re.findall(r'\[IMAGE\](https?://[^\[]+)\[/IMAGE\]', clean_text)
        if image_tag_matches:
            existing = set(images)
            for url in image_tag_matches:
                if url not in existing:
                    images.append(url)
                    existing.add(url)
            clean_text = re.sub(r'\[IMAGE\]https?://[^\[]+\[/IMAGE\]', '', clean_text).strip()

        print(f"Extracted text: {len(clean_text)} chars, images: {len(images)}")
        print(f"Text preview: {clean_text[:200]}")

        send_final_response(connection_id, {
            'success': True,
            'response': clean_text,
            'sql': '',
            'record_count': 0,
            'images': images,
        })

        return {'statusCode': 200, 'body': 'Message processed'}

    except Exception as e:
        print(f"Error in handle_message: {str(e)}")
        try:
            send_to_connection(connection_id, {
                'type': 'error',
                'message': f'Error processing request: {str(e)}'
            })
        except:
            pass
        return {'statusCode': 500, 'body': f'Error: {str(e)}'}


def send_final_response(connection_id, result):
    """Send the final response, chunking if needed to stay under WS frame limit."""
    response_text = result.get('response', '')
    images = result.get('images', [])
    sql = result.get('sql', '')
    record_count = result.get('record_count', 0)

    # Build text-only payload
    text_payload = {
        'type': 'response',
        'response': response_text,
        'sql': sql,
        'record_count': record_count,
        'images': [],
    }

    payload_json = json.dumps(text_payload)
    payload_size = len(payload_json.encode('utf-8'))
    print(f"Text payload size: {payload_size} bytes")

    if payload_size > MAX_WS_PAYLOAD:
        # Text too large — chunk it
        chunk_size = 80000
        for i in range(0, len(response_text), chunk_size):
            chunk = response_text[i:i + chunk_size]
            is_last = (i + chunk_size) >= len(response_text)
            send_to_connection(connection_id, {
                'type': 'response_chunk',
                'chunk': chunk,
                'sql': sql if i == 0 else '',
                'record_count': record_count if i == 0 else 0,
                'is_last': is_last and not images
            })
    else:
        send_to_connection(connection_id, text_payload)

    # Send images separately — chunk if over WS frame limit
    for idx, img in enumerate(images):
        img_payload_size = len(json.dumps({'type': 'image', 'image': img, 'index': idx}).encode('utf-8'))
        if img_payload_size <= MAX_WS_PAYLOAD:
            send_to_connection(connection_id, {
                'type': 'image',
                'image': img,
                'index': idx
            })
        else:
            # Chunk the base64 string into pieces that fit in WS frames
            # Reserve ~200 bytes for JSON wrapper
            chunk_size = MAX_WS_PAYLOAD - 200
            total_chunks = (len(img) + chunk_size - 1) // chunk_size
            print(f"Image {idx}: {len(img)} chars, splitting into {total_chunks} chunks")
            for ci in range(0, len(img), chunk_size):
                chunk = img[ci:ci + chunk_size]
                is_last = (ci + chunk_size) >= len(img)
                send_to_connection(connection_id, {
                    'type': 'image_chunk',
                    'chunk': chunk,
                    'index': idx,
                    'is_last': is_last
                })


def send_to_connection(connection_id, data):
    try:
        domain_name = os.environ['WEBSOCKET_DOMAIN']
        stage = os.environ['WEBSOCKET_STAGE']

        apigw_management = boto3.client(
            'apigatewaymanagementapi',
            endpoint_url=f'https://{domain_name}/{stage}'
        )

        apigw_management.post_to_connection(
            ConnectionId=connection_id,
            Data=json.dumps(data).encode()
        )
    except Exception as e:
        if 'GoneException' in str(type(e)):
            print(f"Connection {connection_id} is gone, removing from table")
            connections_table.delete_item(Key={'connectionId': connection_id})
        else:
            print(f"Error sending to connection {connection_id}: {str(e)}")
            raise
