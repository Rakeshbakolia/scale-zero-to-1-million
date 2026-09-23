# Scale Zero to 1 Million

ByteByteGo-style scaling lab: Go API + React UI + phased AWS infra (Phases **0–8** complete in docs).

**Repository:** [github.com/Rakeshbakolia/scale-zero-to-1-million](https://github.com/Rakeshbakolia/scale-zero-to-1-million)

**AWS:** Terraform in `main.tf`. Use `./scripts/terraform-aws.sh` (requires `aws login`). Tear down with `DESTROY_CONFIRM=destroy ./scripts/teardown.sh`.

## Phase 0 — local

### Prerequisites

- Go 1.22+
- Node 20+
- Docker (for Postgres)
- [k6](https://k6.io/docs/get-started/installation/) (optional, for load tests)

### 1. Database

Postgres listens on **port 5433** on the host (so it does not clash with a local Postgres on 5432).

```bash
docker compose up -d
```

### 2. API

```bash
cd backend
export DATABASE_URL="postgres://scalelab:scalelab@localhost:5433/scalelab?sslmode=disable"
export ADMIN_API_KEY="dev-admin-key-change-me"
go run ./cmd/api
```

API: `http://localhost:8080`

### 3. Frontend

```bash
cd frontend
cp .env.example .env
npm install
npm run dev
```

UI: `http://localhost:5173` — signup at `/`, admin at `/admin`

### 4. Load tests (API running)

```bash
k6 run loadtests/k6/signup.js
k6 run loadtests/k6/list-users.js
k6 run loadtests/k6/mixed.js
```

Record results in `docs/scaling-runbook.md`.

## Phases

| Phase | Description |
|-------|-------------|
| 0 | Local (this README) |
| 1 | AWS EC2 + RDS, no ALB |
| 2 | ALB + Auto Scaling |
| 3 | Read replica |
| 4 | Redis cache |
| 5 | CloudFront + S3 frontend |
| 6 | Observability |
| 7 | ~1M rows, keyset list, `list-users-deep.js` |
| 8 | Wrap-up, [`future-scaling.md`](docs/future-scaling.md), teardown |

## Documentation

| Doc | Purpose |
|-----|---------|
| [`docs/phase-analysis.md`](docs/phase-analysis.md) | Per-phase **what / why / k6 results** + Phase 8 summary table |
| [`docs/scaling-runbook.md`](docs/scaling-runbook.md) | Apply, deploy, seed, load-test checklists |
| [`docs/cost-estimation.md`](docs/cost-estimation.md) | AWS cost ballparks + teardown |
| [`docs/future-scaling.md`](docs/future-scaling.md) | Multi-AZ, pooling, sharding (design notes) |

**Before `git push`:** run `./scripts/verify-safe-to-push.sh`

**Never commit:** `terraform.tfvars`, `terraform.tfstate*`, `.terraform/*.pem`, `frontend/.env`, `frontend/dist/` (build can embed `VITE_ADMIN_API_KEY`). Safe to commit: `terraform.tfvars.example`, `backend/.env.example`, `frontend/.env.example`.
