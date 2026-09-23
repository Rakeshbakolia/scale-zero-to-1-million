# Scaling runbook

Record metrics after each phase before moving on.

## Phase 0 — Local

**Status:** ready for your k6 runs

### Setup

- [x] `docker compose up -d` (Postgres on **localhost:5433** — avoids conflict if you have another Postgres on 5432)
- [x] `go run ./cmd/api` in `backend/`
- [ ] `npm run dev` in `frontend/` (you run locally)

### Manual checks

- [x] Signup creates a user (API smoke test)
- [x] Admin list API returns paginated users
- [ ] Signup + admin in browser at `http://localhost:5173`

### k6 baseline (local Mac, API + Docker Postgres)

| Script | VUs | Duration | RPS | p95 (ms) | Error % | Notes |
|--------|-----|----------|-----|----------|---------|-------|
| signup.js | 10 | 30s | ~61 | ~71 | 0% | Comfortable |
| list-users.js | 10 | 30s | ~83 | ~78 | 0% | Reads faster than writes |
| stress-signup.js | ramp 0→100 | 85s | ~106 peak | ~783 | 0% | Latency rises under load |
| signup.js | 150 | 45s | ~119 | ~1530 | 0% | Still 0 errors; slow |
| signup.js | 250 | 30s | ~117 | ~2600 | 0% | p95 over 2s threshold; CPU/DB bound |

**Rough local ceiling (signup):** ~**115–120 successful signups/sec** with 0% HTTP errors; latency grows sharply above ~100 concurrent VUs. Bottleneck is likely **bcrypt + Postgres writes** on a single API process.

Re-run anytime:

```bash
k6 run loadtests/k6/signup.js
k6 run loadtests/k6/list-users.js
k6 run loadtests/k6/stress-signup.js
k6 run --vus 150 --duration 45s loadtests/k6/signup.js
```

### Exit criteria

- All manual checks pass
- k6 thresholds pass (or bottlenecks documented)

---

## Phase 1 — AWS single server

**Infra:** `main.tf` — EC2 (`t3.micro`) + RDS Postgres (`db.t3.micro`), no ALB. Region default: `ap-south-1`.

**Steps:**

1. `aws login` (or configure credentials)
2. `cd scale-zero-to-1-million && terraform plan` then `terraform apply`
3. `./scripts/deploy-api.sh` — upload Go binary to EC2
4. Point `frontend/.env` `VITE_API_BASE_URL` at `terraform output api_base_url`
5. k6: `BASE_URL=<api_url> ADMIN_API_KEY=<same as tfvars> k6 run loadtests/k6/signup.js`

**Status:** Applied (ap-south-1). API on EC2 public IP:8080 — binary deployed via `scripts/deploy-api.sh`.

**IAM:** Use a dedicated lab IAM user with least privilege for Terraform + deploy scripts.

| Check | Result |
|-------|--------|
| `/health` | OK from internet |
| `/ready` | OK after deploy |

**Frontend:** `frontend/.env` points at AWS API; restart `npm run dev` if it was already running.

**Terraform:** use `./scripts/terraform-aws.sh plan|apply` (pairs `aws login` with Terraform).

**Teardown (when done):** `./scripts/terraform-aws.sh destroy` — **will delete RDS data**.

---

## Phase 2 — ALB + Auto Scaling

**Infra:** Application Load Balancer (HTTP :80) → ASG (`min`/`max` in `terraform.tfvars`) → Go API on :8080. Old single EC2 is **replaced**. API URL becomes `http://<alb-dns>` (no port).

**Steps:**

1. Set `scaling_phase = 2` in `terraform.tfvars` (done).
2. `./scripts/terraform-aws.sh plan` → review (destroys Phase 1 EC2, creates ALB/ASG/S3).
3. `./scripts/terraform-aws.sh apply`
4. `./scripts/deploy-api.sh` — upload binary to S3 + ASG instance refresh
5. Update `frontend/.env` `VITE_API_BASE_URL` to `terraform output -raw api_base_url`
6. k6 via ALB DNS; compare to Phase 1 runbook numbers

**Status:** Applied. ALB: `http://scale-zero-to-million-alb-277154478.ap-south-1.elb.amazonaws.com` — `/health` and `/ready` OK.

### Phase 2 exit criteria

- [x] `curl http://<alb>/health` OK
- [ ] Two instances in ASG (if `asg_max_size >= 2` and scaled) — optional
- [x] k6 `BASE_URL=http://<alb>` completed; notes in table below

| Script | VUs | Duration | RPS | p95 (ms) | Error % | Notes |
|--------|-----|----------|-----|----------|---------|-------|
| signup.js | 10 | 30s | ~22 | ~472 | 0% | ALB; see phase-analysis.md |
| list-users.js | 10 | 30s | ~69 | ~183 | 0% | Use ADMIN_API_KEY from tfvars |

---

## Phase 3 — RDS read replica + read/write split

**Infra:** Same ALB/ASG as Phase 2; Terraform adds **RDS read replica** (`scale-zero-to-million-pg-replica`), SSM `/scale-zero-to-million/database_replica_url`, and tags Phase `3`.

**App:** `ListUsers` → replica pool; `CreateUser` (signup) → primary. EC2 user-data `refresh-env.sh` sets `DATABASE_REPLICA_URL` from SSM.

**Prerequisite:** Phase 2 k6 done (signup + list-users with `ADMIN_API_KEY`).

**Steps:**

1. `aws login` (refresh session if Terraform reports `ExpiredToken`).
2. Confirm `scaling_phase = 3` in `terraform.tfvars` (already set).
3. `./scripts/terraform-aws.sh plan` → expect **primary** `backup_retention_period` → **1** (required for replicas), **new** `aws_db_instance.replica` + SSM replica URL (~10–15 min create).
4. `./scripts/terraform-aws.sh apply`
5. `./scripts/deploy-api.sh` — new binary with dual pools + instance refresh (~3–5 min healthy).
6. `curl -s "$(./scripts/terraform-aws.sh output -raw api_base_url)/ready"` → 200 (pings primary + replica).
7. k6 (same ALB base URL as Phase 2):

```bash
export BASE_URL=$(./scripts/terraform-aws.sh output -raw api_base_url)
export ADMIN_API_KEY="<your-admin-api-key>"   # match terraform.tfvars
k6 run loadtests/k6/list-users.js
k6 run loadtests/k6/mixed.js
k6 run loadtests/k6/signup.js   # writes still hit primary; compare to Phase 2
```

8. In RDS console (or `aws rds describe-db-instances`), note **ReplicaLag** during heavy `list-users.js`.
9. Copy k6 numbers into `docs/phase-analysis.md` Phase 3 section.

**Troubleshooting:** `ExpiredToken` after a long apply — your `aws login` session expired during the 10m backup wait. Run `aws login`, then `./scripts/terraform-aws.sh apply` again (only replica + SSM should remain; **no** second 10m wait if `time_sleep` already succeeded).

**Troubleshooting:** `InvalidDBInstanceState: Automated backups are not enabled` — primary needs `backup_retention_period >= 1` (Phase 3 in `main.tf`). If apply failed **right after** enabling backups, the first automated snapshot may not be ready yet: wait **~10 minutes** and run `apply` again, or let Terraform’s `time_sleep` (~10m) run before replica create on the next apply. Confirm primary: `aws rds describe-db-instances --db-instance-identifier scale-zero-to-million-pg --query 'DBInstances[0].{Retention:BackupRetentionPeriod,Restorable:LatestRestorableTime}'`.

**Status:** Applied and deployed. `/ready` OK; k6 results in `docs/phase-analysis.md`.

### Phase 3 exit criteria

- [x] Terraform shows replica instance + `rds_replica_address` output
- [x] `/ready` OK after deploy
- [x] k6 `list-users.js` + `signup.js` recorded vs Phase 2
- [x] `mixed.js` recorded (Phase 3 + Phase 6 soak on ALB)

---

## Phase 4 — ElastiCache Redis (list cache)

**Infra:** Phase 3 stack + **ElastiCache Redis** cluster, SSM `/scale-zero-to-million/redis_url`.

**App:** `GET /api/v1/users` uses Redis when `REDIS_URL` is set; `/ready` pings Redis too.

**Steps:**

1. `aws login`
2. Confirm `scaling_phase = 4` in `terraform.tfvars`
3. `./scripts/terraform-aws.sh apply` (~5–10 min for Redis)
4. `./scripts/deploy-api.sh` — new binary + instance refresh (user-data loads `REDIS_URL`; refresh env on instances via new LT version or SSM + restart)
5. `curl -s "$(./scripts/terraform-aws.sh output -raw api_base_url)/ready"`
6. k6: `list-users.js` (expect better p95 on warm cache vs Phase 3)
7. Log numbers in `loadtests/k6/results-aws.log` and `docs/phase-analysis.md`

**Local (optional):** `REDIS_URL=redis://localhost:6379/0` with Redis in Docker.

### Phase 4 exit criteria

- [x] ElastiCache cluster + `redis_endpoint` output
- [x] `/ready` OK with Redis
- [x] k6 `list-users.js` vs Phase 3 recorded (~72 RPS, p95 ~58 ms after refresh)

**Note:** Do not run k6 immediately after deploy — wait for instance refresh. `deploy-api-phase2.py` now blocks until refresh + healthy targets.

---

## Phase 5 — CloudFront + S3 frontend

**Infra:** S3 web bucket (private) + CloudFront: static SPA + `/api/*` → ALB. `api_base_url` output becomes **HTTPS CloudFront** URL.

**Steps:**

1. `aws login`
2. `scaling_phase = 5` in `terraform.tfvars`
3. `./scripts/terraform-aws.sh apply` (~5–15 min for CloudFront)
4. `./scripts/deploy-api.sh` — CORS for CloudFront origin + instance refresh
5. `./scripts/deploy-frontend.sh` — `npm run build` + S3 sync + invalidation

Or one shot: `./scripts/phase5-apply-and-deploy.sh`

**k6:** still use direct ALB: `BASE_URL=$(./scripts/terraform-aws.sh output -raw alb_api_url)`

### Phase 5 exit criteria

- [x] `frontend_url` loads React app — `https://dbczpee0qtbbv.cloudfront.net`
- [x] Signup and admin list work over HTTPS (via CloudFront `/api/*`)

**Note:** `/ready` is **not** on CloudFront (only `/api/*` proxies to ALB). Use `curl "$(terraform output -raw alb_api_url)/ready"` or `curl https://<cf>/api/v1/users?...` with admin key.

---

## Phase 6 — CloudWatch dashboard & alarms

**Infra:** No new compute — **CloudWatch dashboard** + **metric alarms** (ALB 5xx, RDS CPU, replica lag). No SNS/email in lab.

**Steps:**

1. `aws login`
2. `scaling_phase = 6` in `terraform.tfvars`
3. `./scripts/terraform-aws.sh apply` (fast — minutes)
4. Open dashboard: `./scripts/terraform-aws.sh output -raw cloudwatch_dashboard_url`
5. Soak test while watching metrics:

```bash
export BASE_URL=$(./scripts/terraform-aws.sh output -raw alb_api_url)
export ADMIN_API_KEY="<your-admin-api-key>"
k6 run loadtests/k6/mixed.js
```

6. Check **Alarms** in CloudWatch console; note any **ALARM** state during load.
7. Update `docs/phase-analysis.md` Phase 6 with soak notes.

### Phase 6 exit criteria

- [x] Dashboard `scale-zero-to-million-ops` exists
- [x] `mixed.js` soak — ~33 RPS, p95 ~725 ms, 0% errors (see `phase-analysis.md`)
- [ ] Optional: alarms stayed OK vs triggered during load

---

## Phase 7 — ~1M users + keyset pagination

**Infra:** No new AWS resources — `scaling_phase = 7` is a phase marker; work is **seed + API + k6**.

**Steps:**

1. `aws login`
2. `scaling_phase = 7` in `terraform.tfvars` (already set)
3. One paste-safe path (recommended):

```bash
aws login
cd "/Users/rakeshbakolia/work/system design/scale-zero-to-1-million"
SEED_TARGET=50000 RUN_K6=1 ./scripts/phase7-lab.sh
```

For ~1M rows: `SEED_TARGET=1000000 ./scripts/phase7-lab.sh` (long on `db.t3.micro`).

RDS is **not** reachable from your laptop; seed runs on an ASG instance via SSM (`seed-via-ec2.sh`).

**1M row load test** (long seed on `db.t3.micro`):

```bash
aws login
cd "/Users/rakeshbakolia/work/system design/scale-zero-to-1-million"
./scripts/phase7-loadtest-1m.sh
```

Or seed only, then k6 yourself:

```bash
SEED_TARGET=1000000 SEED_SSM_TIMEOUT=14400 ./scripts/seed-via-ec2.sh
export BASE_URL=$(./scripts/terraform-aws.sh output -raw alb_api_url)
export ADMIN_API_KEY="<your-admin-api-key>"
export MAX_PAGE=50000
export MAX_AFTER_ID=1000000
export DURATION=2m
k6 run loadtests/k6/list-users-deep.js
```

Or step by step — **do not** put comments on the same line as `terraform apply` (extra words become Terraform arguments):

```bash
./scripts/terraform-aws.sh apply -auto-approve
export DATABASE_URL=$(aws ssm get-parameter --name /scale-zero-to-million/database_url --with-decryption --query Parameter.Value --output text)
SEED_TARGET=50000 ./scripts/seed-1m-users.sh
./scripts/deploy-api.sh
export BASE_URL=$(./scripts/terraform-aws.sh output -raw alb_api_url)
export ADMIN_API_KEY="<your-admin-api-key>"
export MAX_PAGE=2500
k6 run loadtests/k6/list-users-deep.js
```

7. Record offset vs keyset p95 in `docs/phase-analysis.md` and `loadtests/k6/results-aws.log`.

### Phase 7 exit criteria

- [x] Row count — **~1M** seed + k6 (2026-09-23)
- [x] `list-users-deep.js` @ 1M — ~18.5 RPS, p95 ~1.28 s, 0% errors (vs ~65 RPS / ~87 ms @ 50k)
- [x] Documented in `phase-analysis.md` + `results-aws.log`

---

## Phase 8 — Wrap-up

**Infra:** No new resources — `scaling_phase = 8` updates tags only.

**Docs:**

- Journey + metrics: `docs/phase-analysis.md` (Phase 8 table)
- What's next (multi-AZ, pooling, sharding): `docs/future-scaling.md`
- Cost: `docs/cost-estimation.md`

**Steps:**

1. `aws login`
2. `scaling_phase = 8` in `terraform.tfvars` (done)
3. `./scripts/terraform-aws.sh apply -auto-approve` (optional; fast)
4. Push repo to GitHub (exclude secrets — see README)
5. When finished with AWS:

```bash
DESTROY_CONFIRM=destroy ./scripts/teardown.sh
```

6. Confirm in console: no RDS, EC2, ALB, Redis, CloudFront for this project.

### Phase 8 exit criteria

- [x] Documentation complete
- [ ] `teardown.sh` run when you want **$0** ongoing AWS cost
