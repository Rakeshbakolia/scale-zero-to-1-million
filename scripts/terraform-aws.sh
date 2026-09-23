#!/usr/bin/env bash
# Wrap terraform with aws login session credentials (required for Terraform + aws login).
set -euo pipefail
export AWS_REGION="${AWS_REGION:-ap-south-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  echo "AWS credentials missing or expired. Run: aws login" >&2
  exit 1
fi

if [[ "${1:-}" == "apply" ]] && grep -qE 'scaling_phase\s*=\s*3' terraform.tfvars 2>/dev/null && ! grep -qE 'scaling_phase\s*=\s*[4-9]' terraform.tfvars 2>/dev/null; then
  echo "Note: Phase 3 apply can take 20–30+ minutes (RDS backup wait + replica create)."
  echo "      Run 'aws login' right before apply so the session does not expire mid-run."
  echo "      If apply fails with ExpiredToken, run 'aws login' and 'apply' again (safe to retry)."
  echo ""
fi

if [[ "${1:-}" == "apply" ]] && grep -qE 'scaling_phase\s*=\s*4' terraform.tfvars 2>/dev/null && ! grep -qE 'scaling_phase\s*=\s*5' terraform.tfvars 2>/dev/null; then
  echo "Note: Phase 4 adds ElastiCache Redis (~5–10 min). Refresh 'aws login' before apply."
  echo ""
fi

if [[ "${1:-}" == "apply" ]] && grep -qE 'scaling_phase\s*=\s*5' terraform.tfvars 2>/dev/null && ! grep -qE 'scaling_phase\s*=\s*6' terraform.tfvars 2>/dev/null; then
  echo "Note: Phase 5 adds CloudFront (~5–15 min). Then: ./scripts/deploy-api.sh && ./scripts/deploy-frontend.sh"
  echo "      Or: ./scripts/phase5-apply-and-deploy.sh"
  echo ""
fi

if [[ "${1:-}" == "apply" ]] && grep -qE 'scaling_phase\s*=\s*6' terraform.tfvars 2>/dev/null && ! grep -qE 'scaling_phase\s*=\s*7' terraform.tfvars 2>/dev/null; then
  echo "Note: Phase 6 adds CloudWatch dashboard + alarms (~1–2 min). No redeploy required."
  echo "      Then open: terraform output -raw cloudwatch_dashboard_url"
  echo ""
fi

if [[ "${1:-}" == "apply" ]] && grep -qE 'scaling_phase\s*=\s*7' terraform.tfvars 2>/dev/null && ! grep -qE 'scaling_phase\s*=\s*8' terraform.tfvars 2>/dev/null; then
  echo "Note: Phase 7 is data scale — no new infra. Seed: ./scripts/seed-via-ec2.sh"
  echo "      k6: loadtests/k6/list-users-deep.js"
  echo ""
fi

if [[ "${1:-}" == "apply" ]] && grep -qE 'scaling_phase\s*=\s*8' terraform.tfvars 2>/dev/null; then
  echo "Note: Phase 8 — tag update only. Teardown: DESTROY_CONFIRM=destroy ./scripts/teardown.sh"
  echo "      Docs: docs/phase-analysis.md (Phase 8), docs/future-scaling.md"
  echo ""
fi

eval "$(aws configure export-credentials --format env)"
exec terraform "$@"
