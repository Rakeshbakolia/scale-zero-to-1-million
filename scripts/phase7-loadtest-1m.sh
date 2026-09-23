#!/usr/bin/env bash
# Seed to 1M users on EC2, then k6 deep list (offset vs keyset mix). Seed can take 30–90+ min on db.t3.micro.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "Run: aws login" >&2
  exit 1
fi

SEED_TARGET="${SEED_TARGET:-1000000}"
export SEED_TARGET
export SEED_SSM_TIMEOUT="${SEED_SSM_TIMEOUT:-14400}"

echo "==> seed to ${SEED_TARGET} users (SSM on API instance; watch AWS Console → Run Command if this hangs)"
./scripts/seed-via-ec2.sh

echo "==> k6 list-users-deep.js (1M profile)"
export BASE_URL
BASE_URL="$(./scripts/terraform-aws.sh output -raw alb_api_url)"
if [[ -z "${ADMIN_API_KEY:-}" ]]; then
  echo "Set ADMIN_API_KEY (same as admin_api_key in terraform.tfvars)" >&2
  exit 1
fi
export ADMIN_API_KEY
export MAX_PAGE="${MAX_PAGE:-50000}"
export MAX_AFTER_ID="${MAX_AFTER_ID:-1000000}"
export DURATION="${DURATION:-2m}"
export VUS="${VUS:-10}"

k6 run loadtests/k6/list-users-deep.js

echo "==> append results to loadtests/k6/results-aws.log and docs/phase-analysis.md Phase 7 (1M row)"
