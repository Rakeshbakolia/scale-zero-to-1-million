#!/usr/bin/env bash
# Phase 8: destroy all AWS resources created by Terraform (irreversible; RDS data lost).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "Run: aws login" >&2
  exit 1
fi

echo "This will destroy the full lab stack (ALB, ASG, RDS primary+replica, Redis, CloudFront, S3, etc.)."
echo "RDS data and S3 frontend objects will be deleted (see main.tf skip_final_snapshot)."
echo ""

if [[ "${DESTROY_CONFIRM:-}" != "destroy" ]]; then
  echo "To confirm, run:"
  echo "  DESTROY_CONFIRM=destroy ./scripts/teardown.sh"
  exit 1
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGION="${AWS_REGION:-ap-south-1}"
for BUCKET in \
  "scale-zero-to-million-web-${ACCOUNT_ID}" \
  "scale-zero-to-million-artifacts-${ACCOUNT_ID}"; do
  if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
    echo "Emptying s3://${BUCKET} ..."
    aws s3 rm "s3://${BUCKET}" --recursive --region "$REGION"
  fi
done

echo "Note: long destroy may need a fresh 'aws login' if you see ExpiredToken — re-run this script."
./scripts/terraform-aws.sh destroy

echo ""
echo "Verify in console: no EC2, RDS, ALB, ElastiCache, CloudFront for project scale-zero-to-million."
echo "Ongoing AWS cost for this lab should be ~\$0. See docs/cost-estimation.md"
