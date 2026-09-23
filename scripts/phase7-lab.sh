#!/usr/bin/env bash
# Phase 7 — apply (phase marker), seed, deploy API, optional k6. No inline-comment pitfalls.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "Run: aws login" >&2
  exit 1
fi

SEED_TARGET="${SEED_TARGET:-50000}"
RUN_K6="${RUN_K6:-0}"

echo "==> terraform apply (Phase 7 — no new infra; updates phase output)"
./scripts/terraform-aws.sh apply -auto-approve

echo "==> seed users on API EC2 (RDS is VPC-private; SEED_TARGET=${SEED_TARGET})"
./scripts/seed-via-ec2.sh

echo "==> deploy API (keyset list handler)"
./scripts/deploy-api.sh

if [[ "$RUN_K6" == "1" ]]; then
  echo "==> k6 list-users-deep.js"
  export BASE_URL
  BASE_URL="$(./scripts/terraform-aws.sh output -raw alb_api_url)"
  if [[ -z "${ADMIN_API_KEY:-}" ]]; then
    echo "Set ADMIN_API_KEY (same as admin_api_key in terraform.tfvars)" >&2
    exit 1
  fi
  export ADMIN_API_KEY
  export MAX_PAGE="${MAX_PAGE:-$((SEED_TARGET / 20))}"
  k6 run loadtests/k6/list-users-deep.js
fi

echo "==> done"
echo "Row check: curl -s -H \"X-Admin-Key: \${ADMIN_API_KEY:-...}\" \"\$(./scripts/terraform-aws.sh output -raw alb_api_url)/api/v1/users?after_id=0&limit=1\""
