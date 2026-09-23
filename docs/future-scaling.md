# Beyond Phase 7 — design notes (not built in this lab)

Short interview-style “what’s next” after this repo’s Phase 0–7 path. No Terraform here — ideas only.

---

## Multi-AZ

**Today:** Single-AZ RDS + ASG in default VPC subnets.

**Next:** RDS **Multi-AZ** for automatic failover on primary failure; ASG across **2+ AZs** behind ALB (already AZ-aware). Tradeoff: ~2× RDS instance cost for Multi-AZ; better RTO/RPO for the database tier.

---

## Connection pooling (PgBouncer / RDS Proxy)

**Pain:** Many API instances × connection-per-request patterns can exhaust `max_connections` on `db.t3.micro`.

**Next:** **RDS Proxy** or **PgBouncer** on a small sidecar/EC2; API talks to pooler, pooler talks to Postgres with a bounded connection count. Helps before sharding.

---

## Sharding / partitioning (data > single Postgres)

**Pain:** Phase 7 showed **1M rows** with offset pagination and `COUNT(*)` hurting list latency; at 10M+ users a single writer and one logical DB become the bottleneck.

**Next (conceptual):**

| Approach | When |
|----------|------|
| **Table partitioning** (by `created_at` or hash) | Archive old users; prune scans |
| **Read replicas** (Phase 3) | Scale reads, not writes |
| **Shard by `user_id` or `tenant_id`** | Horizontal scale writes; app routes by shard key |
| **Separate “hot” store** | Feeds/timelines (often DynamoDB/Cassandra) vs profile DB |

This lab’s **keyset** `after_id` API is the prerequisite for sane deep paging before you shard.

---

## Cache strategy at scale

**Today:** Redis caches **page=1** and some `after_id` pages (60s TTL); signup bumps cache version.

**Next:** Cache **only** keyset cursors for admin; drop offset `page` in API. Consider **CDN cache** only for public read models (not admin lists with PII).

---

## Observability (Phase 6 extension)

**Next:** SNS on CloudWatch alarms, **X-Ray** or OpenTelemetry traces on signup vs list paths, **slow query log** on RDS for `COUNT(*)` / `OFFSET` offenders.

---

## References

- [`phase-analysis.md`](phase-analysis.md) — what we actually built and measured  
- [ByteByteGo — Scale from zero to millions](https://bytebytego.com/courses/system-design-interview/scale-from-zero-to-millions-of-users)
