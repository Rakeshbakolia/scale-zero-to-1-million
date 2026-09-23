#!/usr/bin/env bash
# Build React app and publish to S3 + CloudFront invalidation (Phase 5+).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export AWS_REGION="${AWS_REGION:-ap-south-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"

BUCKET=$(terraform output -raw frontend_bucket 2>/dev/null || true)
CF_ID=$(terraform output -raw cloudfront_distribution_id 2>/dev/null || true)
API_BASE=$(terraform output -raw api_base_url 2>/dev/null || true)

if [[ -z "$BUCKET" || "$BUCKET" == "null" ]]; then
  echo "Run terraform apply with scaling_phase >= 5 first." >&2
  exit 1
fi

ADMIN_KEY="${ADMIN_API_KEY:-}"
if [[ -z "$ADMIN_KEY" ]]; then
  echo "Set ADMIN_API_KEY (same as admin_api_key in terraform.tfvars)" >&2
  exit 1
fi

echo "Building frontend (VITE_API_BASE_URL=$API_BASE)..."
(
  cd frontend
  npm ci --silent 2>/dev/null || npm install --silent
  VITE_API_BASE_URL="$API_BASE" VITE_ADMIN_API_KEY="$ADMIN_KEY" npm run build
)

if [[ -f "$ROOT/scripts/deploy-frontend-phase5.py" ]]; then
  python3 "$ROOT/scripts/deploy-frontend-phase5.py" "$ROOT/frontend/dist" "$BUCKET" "${CF_ID:-}"
else
  aws s3 sync "$ROOT/frontend/dist/" "s3://$BUCKET/" --delete
  if [[ -n "$CF_ID" && "$CF_ID" != "null" ]]; then
    aws cloudfront create-invalidation --distribution-id "$CF_ID" --paths "/*"
  fi
fi

URL=$(terraform output -raw frontend_url 2>/dev/null || true)
echo ""
echo "Frontend deployed. Open: $URL"
echo "  Signup: $URL/"
echo "  Admin:  $URL/admin"
