#!/usr/bin/env bash
# Run Phase 7 seed on an API EC2 instance (RDS is not reachable from your laptop).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "Run: aws login" >&2
  exit 1
fi

python3 "$(dirname "$0")/seed-via-ec2.py"
