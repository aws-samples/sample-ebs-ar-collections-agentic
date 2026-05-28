#!/usr/bin/env python3
"""
Helper for deploy.sh and other shell scripts to safely read values from
deploy-config.json.

Usage:
    python3 _read_config.py <dotted.key.path> [config_file]

Outputs the value to stdout. Lists are converted to comma-joined strings.
Missing keys, nulls, or non-existent paths print an empty string.

Exits 0 always (even for missing keys) so callers can use unset/empty
detection in shell.
"""

import json
import os
import sys


def main():
    if len(sys.argv) < 2 or len(sys.argv) > 3:
        print(f"Usage: {sys.argv[0]} <dotted.key.path> [config_file]", file=sys.stderr)
        sys.exit(2)

    key_path = sys.argv[1]
    config_file = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), 'deploy-config.json'
    )

    if not os.path.exists(config_file):
        print(f"ERROR: config file not found: {config_file}", file=sys.stderr)
        sys.exit(1)

    with open(config_file) as f:
        cfg = json.load(f)

    # Walk the dotted path
    value = cfg
    for key in key_path.split('.'):
        if isinstance(value, dict):
            value = value.get(key)
        else:
            value = None
            break

    # Format output
    if value is None:
        print('')
    elif isinstance(value, list):
        print(','.join(str(x) for x in value))
    elif isinstance(value, bool):
        print('true' if value else 'false')
    else:
        print(value)


if __name__ == '__main__':
    main()
