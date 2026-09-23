# Cost estimation

**Region:** `ap-south-1` (Mumbai)  
**Last updated:** 2026-09-23  

Prices are **approximate** on-demand USD. Check [Billing](https://console.aws.amazon.com/billing/) after teardown.

---

## One-day project plan (your goal)

**Scope:** build app → load test on AWS → push stats to **GitHub** → **`terraform destroy` the same day** → no long-running infra.

| Item | Cost |
|------|------|
| **GitHub** (public repo, README + results) | **$0** |
| **Local dev** (Docker, Vite, k6 on your Mac) | **$0** (electricity only) |
| **AWS after destroy** | **$0 / month** ongoing — nothing left billing |

### AWS total for ~1 day (Phase 1 only — recommended)

Keep **only** what you have now: **1× EC2 `t3.micro` + 1× RDS `db.t3.micro`**.  
**Do not** enable Phase 2 (ALB) for a 1-day lab — ALB alone can add **~$0.50–$1+** even for part of a day.

| Resource | ~Hours in 1-day lab | Rough one-day cost (USD) |
|----------|---------------------|---------------------------|
| EC2 `t3.micro` | ≤ 24 h (from first `apply` to `destroy`) | **~$0.25 – $0.40** |
| RDS `db.t3.micro` | same window | **~$0.35 – $0.50** |
| EBS (EC2 disk + RDS 20 GB), prorated | 1 day | **~$0.05 – $0.15** |
| Public IPv4 on EC2 | per hour attached | **~$0.10 – $0.15** |
| Data transfer (k6 + browser) | light lab | **~$0 – $0.50** |
| SSM / IAM | — | **~$0** |
| **Total AWS (list price, 1 day)** | | **~$1 – $2** |

**If Free Tier still applies** (new account, eligible): EC2 + RDS compute for **24 h** is usually **within 750 h/month** → often **$0 – $0.50** total (you may still see a small charge for **public IPv4** or transfer).

**After `terraform destroy`:** no EC2/RDS charges; your **final bill** for this project is roughly the table above (plus any hours the stack already ran **before** you destroy — e.g. if Phase 1 was up overnight, count **all hours from first apply to destroy**, not calendar “1 day” only).

### What to publish on GitHub (no extra AWS cost)

- `docs/scaling-runbook.md` — local vs AWS k6 numbers  
- `docs/cost-estimation.md` — this file  
- Optional: architecture diagram, `loadtests/k6/` scripts  

Do **not** commit: `terraform.tfvars`, `.pem` keys, `.env` with secrets.

### Teardown (stop all charges)

```bash
cd scale-zero-to-1-million
./scripts/terraform-aws.sh destroy
```

Confirm EC2 and RDS are gone in the console. **Expected ongoing AWS cost: $0.**

---

## Phase 1 steady-state (if you left it running — not your plan)

**Phase:** 1 only (single EC2 + RDS, **no ALB**, no CloudFront, no Redis)

---

## What is running today

| Resource | ID / name | Config (from Terraform) |
|----------|-----------|---------------------------|
| **EC2** | (example instance) | `t3.micro`, Amazon Linux 2023, public IP, API :8080 |
| **RDS** | `scale-zero-to-million-pg` | PostgreSQL **16**, `db.t3.micro`, **20 GB** `gp3`, single-AZ, backup retention **0** |
| **VPC** | Default VPC | No extra VPC/NAT charge |
| **SSM** | `/scale-zero-to-million/*` | 2 SecureString parameters |
| **IAM** | `scale-zero-to-million-ec2` role + instance profile | No direct charge |
| **Key pair** | `scale-zero-to-million-phase1` | No charge |

**Not deployed (no cost from these yet):** Application Load Balancer, Auto Scaling (extra instances), read replica, ElastiCache, S3/CloudFront for frontend, NAT Gateway.

---

## Estimated monthly cost (24×7, ap-south-1)

| Line item | Rough monthly (USD) | Notes |
|-----------|---------------------|--------|
| EC2 `t3.micro` (Linux) | **~$8 – $11** | On-demand compute, ~730 h/mo |
| EC2 EBS (root volume) | **~$1 – $3** | Default AL2023 root disk (typically 8–30 GB gp3) |
| RDS `db.t3.micro` | **~$12 – $16** | Instance hours, single-AZ |
| RDS storage 20 GB gp3 | **~$2 – $3** | `allocated_storage = 20` in `main.tf` |
| RDS backup | **~$0** | `backup_retention_period = 0` |
| Public IPv4 (EC2) | **~$3 – $4** | AWS charges for public IPv4 in many regions (since 2024); varies by account/region |
| Data transfer (out to internet) | **~$0 – $2** | Lab/k6 traffic; first tier often small |
| SSM Parameter Store (standard) | **~$0** | Few parameters, low API usage |
| **Total (list price, ballpark)** | **~$26 – $40 / month** | If everything runs full month |

### If your account still has **AWS Free Tier** (12 months, eligible services)

Many new accounts get:

- **750 h/mo** of `t2.micro` / `t3.micro` **EC2** (Linux)
- **750 h/mo** of `db.t2.micro` / `db.t3.micro` **RDS** + **20 GB** storage

For a **single** `t3.micro` EC2 and **single** `db.t3.micro` RDS running 24×7, compute may be **mostly or fully covered** in the first year, but you may still pay for:

- **Public IPv4** address
- **EBS** beyond free allowances
- **Data transfer** out
- Any usage **after** free tier expires or if limits are exceeded

**Practical range for a careful lab in year 1:** often **~$0 – $15 / month**; after free tier: expect closer to the **~$26 – $40** band above.

---

## Cost drivers for *this* project

| Driver | Phase 1 impact |
|--------|------------------|
| **RDS always on** | Usually the largest fixed cost after free tier |
| **EC2 always on** | Second fixed cost |
| **bcrypt signup load tests** | Mostly **CPU** on EC2 + **writes** to RDS; small $ impact unless huge traffic |
| **No ALB** | Saves **~$16–22+/mo** (why Phase 1 skipped it) |

---

## How to see your *actual* cost

1. **AWS Console** → **Billing and Cost Management** → **Bills** / **Cost Explorer**  
2. Filter by **Service**: EC2, RDS  
3. Filter by **Region**: Asia Pacific (Mumbai) `ap-south-1`  
4. Optional: tag filter `Project = scale-zero-to-million` (resources are tagged in Terraform)

---

## Stop or reduce spend

| Action | Effect |
|--------|--------|
| **Destroy lab** | `./scripts/terraform-aws.sh destroy` — removes EC2 + RDS (**data deleted**) |
| **Stop EC2** (console) | Saves EC2 compute; RDS still bills |
| **Delete RDS snapshot** | N/A if `skip_final_snapshot = true` on destroy |
| **Phase 2+** | ALB, second EC2, replica, Redis, CloudFront **add** fixed + usage cost — see runbook phases |

---

## Planned phase cost hints (not deployed)

| Phase | Extra services | Extra rough monthly |
|-------|----------------|---------------------|
| **2** | ALB + ASG (2× EC2) | **+$16–22** ALB + **+$8–11** per extra `t3.micro` |
| **3** | RDS read replica | **+$12–16** (another `db.t3.micro` class) |
| **4** | ElastiCache Redis | **+$12–15+** (cache node size) |
| **5** | S3 + CloudFront | Often **low** for static SPA traffic |
| **6** | CloudWatch alarms/dashboards | Usually **<$5** at lab scale |

---

## References

- [EC2 On-Demand Pricing](https://aws.amazon.com/ec2/pricing/on-demand/)
- [RDS PostgreSQL Pricing](https://aws.amazon.com/rds/postgresql/pricing/)
- [VPC Public IPv4 Pricing](https://aws.amazon.com/vpc/pricing/)
- Project infra: [`main.tf`](../main.tf), [`terraform.tfvars`](../terraform.tfvars) (local, gitignored)

---

## Total cost — one-day project (end-to-end)

**Phase 1 only** (single EC2 + RDS, no ALB):

Assumes load tests, **GitHub publish**, then **`terraform destroy`** within ~24 hours of first deploy.

| Category | One-day total (USD) |
|----------|---------------------|
| AWS (list / on-demand) | **~$1.00 – $2.00** |
| AWS (with Free Tier, if eligible) | **~$0.00 – $0.50** |
| GitHub (public repository) | **$0.00** |
| Local tools (Docker, k6, Vite) | **$0.00** |

### **Grand total (typical)**

| | |
|--|--|
| **Most likely (Free Tier account, destroy same day)** | **~$0 – $1** |
| **Without Free Tier (destroy same day)** | **~$1 – $2** |
| **After destroy — ongoing monthly cost** | **$0** |

*Total = sum of all hours from first `terraform apply` until `destroy`, not calendar days only. If the stack runs longer than 24 hours before teardown, add roughly **~$0.03 – $0.05 per extra hour** (EC2 + RDS + IPv4, ballpark).*

### Full lab stack (Phases 2–7 — what this repo deployed)

Rough **extra** vs Phase 1 if left up **24 hours** (ALB, 1–2× EC2, 2× RDS, Redis, CloudFront/S3, CloudWatch):

| Extra | ~One-day add-on (USD) |
|-------|------------------------|
| ALB | ~$0.50 – $1.00 |
| Second RDS (replica) | ~$0.35 – $0.50 |
| ElastiCache `cache.t3.micro` | ~$0.35 – $0.50 |
| CloudFront + S3 (lab traffic) | ~$0 – $0.25 |
| **Ballpark total full stack / day** | **~$3 – $6** (list); often less with Free Tier |

Teardown: `DESTROY_CONFIRM=destroy ./scripts/teardown.sh` → **$0** ongoing for these resources.
