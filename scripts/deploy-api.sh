#!/usr/bin/env bash
# Build Linux API binary and deploy (Phase 1: SSH, Phase 2: S3 + ASG instance refresh).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v terraform >/dev/null; then
  echo "terraform not found" >&2
  exit 1
fi

export AWS_REGION="${AWS_REGION:-ap-south-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"

echo "Building linux/amd64 API..."
(cd backend && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /tmp/scalelab-api ./cmd/api)

BUCKET=$(terraform output -raw artifacts_bucket 2>/dev/null || true)
ALB=$(terraform output -raw alb_dns_name 2>/dev/null || true)

if [[ -n "$BUCKET" && "$BUCKET" != "null" ]]; then
  echo "Phase 2: S3 upload + ASG refresh (via deploy-api-phase2.py) ..."
  python3 "$(dirname "$0")/deploy-api-phase2.py"
  API_URL=$(terraform output -raw api_base_url)
  echo ""
  echo "Deploy finished (refresh + healthy targets). Verify:"
  ALB=$(terraform output -raw alb_api_url 2>/dev/null || true)
  if [[ -n "$ALB" && "$ALB" != "null" ]]; then
    echo "  curl -s $ALB/ready"
  else
    echo "  curl -s $API_URL/ready"
  fi
  echo "  k6: BASE_URL=\${BASE_URL:-$API_URL} ADMIN_API_KEY=<tfvars> k6 run loadtests/k6/list-users.js"
  echo "  (Phase 5: use alb_api_url for /ready; CloudFront only proxies /api/*)"
  exit 0
fi

IP=$(terraform output -raw ec2_public_ip 2>/dev/null || true)
KEY=$(terraform output -raw ssh_private_key_path 2>/dev/null || true)

if [[ -z "$IP" || "$IP" == "null" ]]; then
  echo "Run terraform apply with scaling_phase >= 1 first." >&2
  exit 1
fi

if [[ -z "$KEY" || ! -f "$KEY" ]]; then
  echo "SSH key not found." >&2
  exit 1
fi

echo "Phase 1: uploading to ec2-user@$IP ..."
scp -i "$KEY" -o StrictHostKeyChecking=accept-new /tmp/scalelab-api "ec2-user@${IP}:/tmp/scalelab-api"
ssh -i "$KEY" -o StrictHostKeyChecking=accept-new "ec2-user@${IP}" <<'REMOTE'
sudo mv /tmp/scalelab-api /opt/scalelab/bin/api
sudo chmod +x /opt/scalelab/bin/api
sudo /opt/scalelab/refresh-env.sh
sudo systemctl restart scalelab-api
sleep 2
curl -sf "http://localhost:8080/health" && echo " — API healthy on instance"
REMOTE

API_URL=$(terraform output -raw api_base_url)
echo ""
echo "Deployed. API URL: $API_URL"
