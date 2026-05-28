#!/usr/bin/env python3
"""
WebSocket Authorizer Lambda

Validates Cognito JWT tokens for WebSocket connections using python-jose
"""

import os
import json
import urllib.request
from jose import jwt, JWTError

# Environment variables
USER_POOL_ID = os.environ['USER_POOL_ID']
AWS_REGION = os.environ.get('AWS_REGION', 'us-east-1')
APP_CLIENT_ID = os.environ['APP_CLIENT_ID']

# Cognito JWKS URL
JWKS_URL = f'https://cognito-idp.{AWS_REGION}.amazonaws.com/{USER_POOL_ID}/.well-known/jwks.json'

# Module-level JWKS cache
_JWKS_KEYS = None


def _get_jwks_keys():
    """Fetch and cache JWKS keys"""
    global _JWKS_KEYS
    if _JWKS_KEYS is None:
        with urllib.request.urlopen(JWKS_URL) as response:  # nosec B310
            _JWKS_KEYS = json.loads(response.read())['keys']
    return _JWKS_KEYS


def lambda_handler(event, context):
    """Authorize WebSocket connection using Cognito JWT"""
    try:
        token = event.get('queryStringParameters', {}).get('token')
        if not token:
            print("No token provided")
            return generate_policy('user', 'Deny', event['methodArn'])

        user_info = validate_token(token)
        if not user_info:
            print("Invalid token")
            return generate_policy('user', 'Deny', event['methodArn'])

        print(f"Token validated for user: {user_info['sub']}")
        return generate_policy(
            user_info['sub'],
            'Allow',
            event['methodArn'],
            context={
                'userId': user_info['sub'],
                'email': user_info.get('email', 'unknown')
            }
        )
    except Exception as e:
        print(f"Authorization error: {str(e)}")
        return generate_policy('user', 'Deny', event['methodArn'])


def validate_token(token):
    """Validate Cognito JWT token using python-jose"""
    try:
        keys = _get_jwks_keys()
        claims = jwt.decode(
            token,
            keys,
            algorithms=['RS256'],
            audience=APP_CLIENT_ID,
            options={'verify_signature': True, 'verify_exp': True, 'verify_aud': True}
        )

        if claims.get('token_use') != 'id':
            print(f"Invalid token_use: {claims.get('token_use')}")
            return None

        return claims
    except JWTError as e:
        print(f"JWT validation error: {str(e)}")
        return None
    except Exception as e:
        print(f"Error validating token: {str(e)}")
        return None


def generate_policy(principal_id, effect, resource, context=None):
    """Generate IAM policy for API Gateway"""
    policy = {
        'principalId': principal_id,
        'policyDocument': {
            'Version': '2012-10-17',
            'Statement': [
                {
                    'Action': 'execute-api:Invoke',
                    'Effect': effect,
                    'Resource': resource
                }
            ]
        }
    }
    if context:
        policy['context'] = context
    return policy
