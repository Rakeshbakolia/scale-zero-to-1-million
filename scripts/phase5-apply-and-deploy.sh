#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "Run: aws login" >&2
  exit 1
fi

echo "==> terraform apply (Phase 5 — CloudFront + S3)"
./scripts/terraform-aws.sh apply -auto-approve

echo "==> deploy API (CORS for CloudFront origin + latest binary)"
./scripts/deploy-api.sh

echo "==> deploy frontend"
./scripts/deploy-frontend.sh

URL=$(terraform output -raw frontend_url)
echo "==> smoke test"
curl -sf "$URL/health" || curl -sf "$(terraform output -raw alb_api_url)/health"
echo ""
echo "Open UI: $URL"
