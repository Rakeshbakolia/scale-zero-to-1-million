#!/usr/bin/env bash
# Phase 4: apply Terraform, deploy API, verify /ready, run list-users k6.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export AWS_REGION="${AWS_REGION:-ap-south-1}"

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "Run: aws login" >&2
  exit 1
fi

echo "==> terraform apply (Phase 4 — Redis)"
./scripts/terraform-aws.sh apply -auto-approve

echo "==> deploy API"
./scripts/deploy-api.sh

BASE_URL="$(./scripts/terraform-aws.sh output -raw api_base_url)"
echo "==> wait for healthy targets (~90s)"
sleep 90

echo "==> /ready"
curl -sf "$BASE_URL/ready"
echo ""

export BASE_URL
if [[ -z "${ADMIN_API_KEY:-}" ]]; then
  echo "Set ADMIN_API_KEY (same as admin_api_key in terraform.tfvars)" >&2
  exit 1
fi
export ADMIN_API_KEY
echo "==> k6 list-users.js"
k6 run loadtests/k6/list-users.js

echo ""
echo "Done. Append k6 summary to loadtests/k6/results-aws.log and docs/phase-analysis.md Phase 4."
