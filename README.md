# Scale Zero to 1 Million

Hands-on lab inspired by the [ByteByteGo — *Scale From Zero To Millions Of Users*](https://bytebytego.com/courses/system-design-interview/scale-from-zero-to-millions-of-users) chapter: Go API + React UI, phased AWS Terraform, and k6 load tests (Phases **0–8** documented).

**Repository:** [github.com/Rakeshbakolia/scale-zero-to-1-million](https://github.com/Rakeshbakolia/scale-zero-to-1-million)

**AWS:** Terraform in `main.tf`. Use `./scripts/terraform-aws.sh` (requires `aws login`). Tear down with `DESTROY_CONFIRM=destroy ./scripts/teardown.sh`.

---

## Architecture evolution (ByteByteGo → this repo)

Each phase adds one idea from the course (single server → separate DB → load balancer → replication → cache → CDN → ops → data scale). Diagrams below match **this lab’s** stack; see [`docs/phase-analysis.md`](docs/phase-analysis.md) for metrics.

### Journey overview

```mermaid
flowchart LR
  P0["Phase 0\nLocal monolith"]
  P1["Phase 1\nEC2 + RDS"]
  P2["Phase 2\nALB + ASG"]
  P3["Phase 3\nRead replica"]
  P4["Phase 4\nRedis cache"]
  P5["Phase 5\nCloudFront + S3"]
  P6["Phase 6\nCloudWatch"]
  P7["Phase 7\n~1M rows"]
  P0 --> P1 --> P2 --> P3 --> P4 --> P5 --> P6 --> P7
```

| ByteByteGo topic | Course idea | This repo (phase) |
|------------------|-------------|-------------------|
| Single server setup | App + DB on one box | Phase **0** (Docker on laptop) |
| Database | Web tier vs data tier | Phase **1** (EC2 + RDS) |
| Load balancer | Scale-out web tier | Phase **2** (ALB + ASG) |
| Database replication | Read slaves | Phase **3** (RDS replica, read/write split in Go) |
| Cache tier | Read-through cache | Phase **4** (ElastiCache Redis) |
| CDN | Static assets at the edge | Phase **5** (S3 + CloudFront; `/api/*` → ALB) |
| Monitoring / scale data | Ops + growth | Phase **6–7** (dashboard + 1M user seed, keyset API) |

### Phase 0 — Single server (local)

*ByteByteGo: everything on one server (Figures 1–2).*

```mermaid
flowchart LR
  Browser --> Vite["React (Vite :5173)"]
  k6 --> API["Go API :8080"]
  Vite --> API
  API --> PG[("Postgres\nDocker :5433")]
```

### Phase 1 — Web tier + data tier

*ByteByteGo: separate web and database servers (Figure 3).*

```mermaid
flowchart LR
  Client["Browser / k6"] --> EC2["EC2\nt3.micro"]
  EC2 --> RDS[("RDS Postgres\nprimary")]
```

### Phase 2 — Load balancer + horizontal web tier

*ByteByteGo: load balancer in front of multiple web servers (Figures 4, 6).*

```mermaid
flowchart LR
  Client --> ALB["ALB :80"]
  ALB --> TG["Target group :8080"]
  TG --> EC2a["ASG instance"]
  TG --> EC2b["ASG instance (optional)"]
  EC2a --> RDS[("RDS primary")]
  EC2b --> RDS
```

### Phase 3 — Database replication (read replica)

*ByteByteGo: master/slave — writes to primary, reads to replicas (Figure 5).*

```mermaid
flowchart LR
  Client --> ALB --> ASG["ASG API"]
  ASG -->|signup writes| RDS_P[("RDS primary")]
  ASG -->|list reads| RDS_R[("RDS replica")]
  RDS_P -.->|replication| RDS_R
```

### Phase 4 — Cache tier

*ByteByteGo: cache in front of DB for hot reads (Figures 7–8, 11).*

```mermaid
flowchart LR
  Client --> ALB --> ASG
  ASG --> Redis[("ElastiCache\nRedis")]
  ASG --> RDS_R[("Replica")]
  ASG --> RDS_P[("Primary")]
  Redis -.->|cache miss| RDS_R
```

### Phase 5 — CDN (static) + API path

*ByteByteGo: static JS/CSS/images from CDN; origin for cache miss (Figures 9–11).*

```mermaid
flowchart LR
  Browser --> CF["CloudFront HTTPS"]
  CF -->|"/ static"| S3["S3 SPA"]
  CF -->|"/api/*"| ALB["ALB"]
  ALB --> ASG --> Redis
  ASG --> RDS_P
  ASG --> RDS_R
```

### Phase 6 — Observability

*Lab extension: metrics and alarms on the Phase 5 stack.*

```mermaid
flowchart TB
  subgraph traffic [Traffic path]
    Client --> CF --> ALB --> ASG
  end
  subgraph observe [CloudWatch]
    ALB --> Dash["Dashboard\nALB / ASG / RDS / Redis"]
    ALB --> Alarms["Alarms\n5xx, CPU, replica lag"]
  end
```

### Phase 7 — Data scale (~1M users)

*ByteByteGo later topics: data growth; this lab uses **row count** + **keyset pagination** (`after_id`), not 1M concurrent users.*

```mermaid
flowchart LR
  k6["k6 deep list"] --> ALB --> ASG
  ASG -->|offset page\nCOUNT + OFFSET| RDS_R
  ASG -->|after_id keyset| RDS_R
  Seed["seed-via-ec2\nCOPY batches"] --> RDS_P[("Primary\n~1M rows")]
```

---

## Phase 0 — local quick start

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

---

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

---

## Documentation

| Doc | Purpose |
|-----|---------|
| [`docs/phase-analysis.md`](docs/phase-analysis.md) | Per-phase **what / why / k6 results** + Phase 8 summary table |
| [`docs/scaling-runbook.md`](docs/scaling-runbook.md) | Apply, deploy, seed, load-test checklists |
| [`docs/cost-estimation.md`](docs/cost-estimation.md) | AWS cost ballparks + teardown |
| [`docs/future-scaling.md`](docs/future-scaling.md) | Multi-AZ, pooling, sharding (design notes) |

**Before `git push`:** run `./scripts/verify-safe-to-push.sh`

**Never commit:** `terraform.tfvars`, `terraform.tfstate*`, `.terraform/*.pem`, `frontend/.env`, `frontend/dist/` (build can embed `VITE_ADMIN_API_KEY`). Safe to commit: `terraform.tfvars.example`, `backend/.env.example`, `frontend/.env.example`.

---

## Reference

- **[ByteByteGo — Scale From Zero To Millions Of Users](https://bytebytego.com/courses/system-design-interview/scale-from-zero-to-millions-of-users)** — system design interview course chapter this project follows (single server, load balancer, DB replication, cache, CDN, and scaling concepts). Diagrams in the course use Figures 1–11; the Mermaid diagrams above are **this repository’s** implementation of that progression.
