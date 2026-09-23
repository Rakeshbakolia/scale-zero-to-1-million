#!/usr/bin/env bash
# Phase 7: bulk seed from YOUR machine — only works if DATABASE_URL is reachable (RDS is VPC-private on AWS).
# On AWS lab use: ./scripts/seed-via-ec2.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/backend"

TARGET="${SEED_TARGET:-1000000}"
BATCH="${SEED_BATCH:-5000}"

if [[ -z "${DATABASE_URL:-}" ]]; then
  echo "Set DATABASE_URL to the RDS **primary** connection string." >&2
  echo "Example: export DATABASE_URL=\$(./scripts/terraform-aws.sh output -raw rds_address) — use SSM/terraform for full URL with password." >&2
  echo "For AWS: export DATABASE_URL=\$(aws ssm get-parameter --name /scale-zero-to-million/database_url --with-decryption --query Parameter.Value --output text)" >&2
  exit 1
fi

echo "Seeding toward ${TARGET} users (batch ${BATCH})..."
go run ./cmd/seed -target "$TARGET" -batch "$BATCH"
