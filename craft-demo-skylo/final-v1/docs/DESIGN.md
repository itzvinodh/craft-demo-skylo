# Skylo Regional Hub — AWS Architecture Design
**us-west-2 Deployment | Finalized Design**

---

## Executive Summary

This document describes a resilient, zero-trust architecture for Skylo's first regional hub in us-west-2, handling high-volume data ingestion from satellite ground stations and containerized 3GPP core network processing. The design prioritizes single-AZ resilience, least-privilege IAM, and operational observability, with explicit trade-offs documented throughout.

**Key decisions:**
- **Network:** Three-family CIDR strategy (10.0.0.0/9 hubs, 10.128.0.0/9 ground, 172.16.0.0/12 org) avoiding collision by construction
- **Compute:** EKS with Karpenter for node autoscaling + HPA for pod autoscaling
- **Storage:** ElastiCache (multi-AZ Redis) for sessions, S3 with lifecycle policies for logs
- **HA/DR:** Single-AZ resilience built-in; region-loss RTO 15–20 min @ ~$30K/month incremental cost
- **Security:** IRSA per pod, NLB as single public surface, Config + GuardDuty + Security Hub first three services

---

## A1. Network Architecture

### Topology & CIDR Strategy

**VPC Layout (us-west-2):**
```
Hub VPC: 10.100.0.0/16 (3 AZs)
├─ Public tier (NAT + NLB only):   10.100.0–2.0/24 (one per AZ)
└─ Private tier (EKS + TGW attach): 10.100.10–30.0/24 (one per AZ)

Ground segment (on-prem):          10.200.0.0/16 (reachable via DX)
Org accounts (shared services):    172.16.0.0/12 (reachable via TGW)
Pod secondary CIDR (cluster-local): 100.64.0.0/16 (RFC 6598, no TGW routing)
```

**Why this CIDR strategy avoids collisions:**

Three **disjoint RFC1918 address families**, not sub-ranges of one block:

| Family | Range | Why |
|--------|-------|-----|
| **Hub VPCs** | 10.0.0.0/9 | Sequential /16 per hub: hub#1=10.100, hub#2=10.101, etc. One half of 10.0.0.0/8. |
| **Ground segments** | 10.128.0.0/9 | Sequential /16 per hub: hub#1=10.200, hub#2=10.201, etc. Other half of 10.0.0.0/8. |
| **Org/shared-services** | 172.16.0.0/12 | **Completely different RFC1918 block.** No amount of hub growth can collide with org space. |
| **Pod CIDR** | 100.64.0.0/10 | RFC 6598 (shared space), cluster-local only, never crosses TGW. Reused per hub. |

**As Skylo adds hubs (hub#3, hub#4, etc.):**
- Hub#3 gets 10.102.0.0/16 (hub) + 10.202.0.0/16 (ground) — still within their halves of 10.0.0.0/8
- Org space remains 172.16.0.0/12 — untouched
- **Collision is structurally impossible:** the three families are assigned from disjoint supernets, not competing for sub-ranges

### Route Table Design

**Public tier (shared across 3 AZs):**
```hcl
Route: 0.0.0.0/0 → IGW  # Egress to internet (NLB responses, NAT backhaul only)
# Deliberately NO route to ground_cidr or org_cidrs — blast radius boundary
```

**Private tier (one route table per AZ, not shared):**
```hcl
Route: 0.0.0.0/0 → NAT-in-same-AZ    # Own-AZ NAT only (no cross-AZ single point of failure)
Route: 10.200.0.0/16 → TGW           # Ground traffic (DX-reachable)
Route: 172.16.0.0/12 → TGW           # Org traffic (east-west)
```

Why per-AZ route tables for private subnets? A shared route table with a shared NAT becomes a single point of failure; if the NAT's AZ fails, traffic from other AZs has no egress. Instead, each private subnet's route table points to the NAT **in its own AZ**, so an AZ failure only affects that AZ's egress.

### Transit Gateway Attachment Strategy

**Problem:** One TGW attachment carrying **both** DX (ground) traffic **and** east-west org traffic — both on one flat route table means any org account that can reach the TGW can see ground traffic. That's not zero-trust.

**Solution:** Two separate TGW route tables, purpose-built:

| Route Table | Carries | Never carries |
|-------------|---------|---------------|
| **Ground** | 10.200.0.0/16 ↔ hub VPC | Org traffic |
| **Org East-West** | 172.16.0.0/12 ↔ hub VPC | Ground traffic |

Segmentation is enforced at the TGW layer, not by "it's all in one VPC so it's fine."

### Service Time Budget (End-to-End)

| Hop | Segment | Typical | Notes |
|-----|---------|---------|-------|
| Ground → DX LOA | Backhaul | ~5–30 ms | Physical distance (not hub control) |
| DX → TGW → private subnet | AWS layer | ~1–2 ms | Single managed hop, same region |
| Data-ingress → core-network pod | In-VPC | < 1 ms | Typically same AZ |
| Core-network pod → NLB | In-VPC | < 1 ms | Typically same AZ |
| NLB → IGW → internet → customer | Internet | ~20–100+ ms | Customer network distance |
| **Total AWS hops (TGW to NLB)** | | **~3–5 ms** | Hub-controlled portion |

---

## A2. Compute — EKS (with Karpenter) Decision

**Decision: EKS, not ECS**

### Justification

| Dimension | EKS | ECS |
|-----------|-----|-----|
| **Custom CNI** | ✓ VPC CNI with custom config | ✗ Limited (Fargate) or EC2 only |
| **Low-level networking** | ✓ Host networking, multiple NICs, device plugins | ✗ Abstracted away |
| **3GPP workload requirements** | ✓ Needed for real-time packet processing | ✗ Conflicts with ECS model |
| **Vendor ecosystem** | ✓ Telco vendors ship Helm + Operators | ✗ Task definitions aren't standard |
| **Operational overhead** | Control plane versions, add-ons, RBAC | Less (AWS-managed) |
| **Cost** | EKS control plane: $0.20/hour | Minimal |
| **Portability** | ✓ Can run edge or other clouds | ✗ AWS-only |

**The deciding factor:** 3GPP core workloads need custom networking (multiple NICs, high-precision QoS enforcement, per-device rate limiting). ECS can't expose that layer; EKS can.

### Autoscaling Strategy

**Node autoscaling (Karpenter, not cluster-autoscaler):**
- Karpenter provisions nodes based on actual pending-pod resource shapes
- Data-ingress pods (network-optimized) and core-network pods (compute-optimized) want different instance types
- Cluster-autoscaler forces you to pre-define ASG shapes; Karpenter doesn't

**Pod autoscaling (HPA on custom metrics):**
- Data-ingress: scale on CPU (parse throughput bottleneck)
- Core-network: scale on custom metric (Redis query latency or processing lag)
- UPF (future): scale on packet forwarding rate

**Why not auto-scale ElastiCache or NAT?** They don't auto-scale on their own. Monitoring for saturation and manual action is required (see A5 metrics).

### Reversal Condition

**One thing that would make me switch to ECS/Fargate:** If the actual scope turned out to be **only** stateless session-management APIs—no packet-processing workload, no low-level networking requirement—then I'd run that on ECS/Fargate instead to drop operational overhead. The reversal question is: *Does this hub run the packet-processing (UPF) workload, or only control-plane logic?*

---

## A3. Storage

| Need | Service | Justification |
|------|---------|---------------|
| **Session state** (high throughput, low latency) | **ElastiCache (Redis 7.0, multi-AZ mode)** | Sub-millisecond reads for session lookups, native TTL for expiry, automatic multi-AZ failover keeps apps alive during node failure |
| **Connection logs** (long-term, auditable) | **S3 with Intelligent-Tiering + lifecycle policy** | Durable, queryable with Athena, cost-optimized (Standard → Intelligent → Archive on age), SOC 2 evidence engine |

### ElastiCache Configuration

- **Cluster mode enabled:** 3 shards (primary + 1 replica per shard), spread across 3 AZs
- **Automatic failover:** Enabled; replica promotes if primary fails (~30 sec convergence)
- **Encryption:** At-rest (KMS) + in-transit (TLS 1.2+)
- **Client-side proxy:** Sidecar (Envoy or Twemproxy) in each pod handles cluster redirects; app uses localhost:6379

### S3 Lifecycle

```hcl
Standard (current) → Intelligent-Tiering (30 days) → Glacier (90 days) → Archive (1 year)
```

Versioning + MFA delete on the logs bucket; CloudTrail logs to separate account.

---

## A4. HA and DR

### Single-AZ Resilience (Built-in)

**Data-ingress pod crashes:** Kafka topic has replicas; TGW-attached traffic is rebalanced to healthy pods (< 5 sec)

**Core-network pod crashes:** Redis multi-AZ means session state survives. New pod queries Redis, resumes session (< 5 sec)

**ElastiCache node failure:** Cluster mode + multi-AZ = automatic replica promotion, no app change (~ 30 sec)

**NAT failure (single AZ):** Other AZs' NATs unaffected; affected AZ's pods lose egress until NAT recovers. **Mitigation:** Use VPC endpoints for S3/ECR/CloudWatch (bypass NAT), reducing egress traffic and blast radius.

**TGW attachment failure:** DX circuit fails; traffic reroutes via VPN backup (if configured). **Assumption:** VPN as secondary path is pre-configured between ground station and AWS.

### Region Loss (us-west-2 → us-east-1 DR)

**Strategy:** Warm standby with automated failover

| Component | Primary (us-west-2) | Standby (us-east-1) | RTO | RPO | Cost impact |
|-----------|------------------|-------------------|-----|-----|-------------|
| **VPC/Network** | Active | Terraform standby, manual trigger | ~5–10 min | 0 | ~$500/month (idle NAT/IGW) |
| **EKS** | Active 3-AZ | Standby cluster, empty | ~10 min | 0 | ~$15/month (control plane) |
| **ElastiCache** | Active multi-AZ | Standby, empty cluster | ~5 min (launch) + data sync | 0 (replicated snapshot) | ~$2K/month (r6g.xlarge × 3 nodes) |
| **S3 logs** | Active region | Cross-region replication | 0 (async) | ~1 min | ~$0.023/GB/month |
| **Container images** | ECR primary | Cross-region replication | ~2–5 min | 0 | ~$5/month (replication) |

**Total RTO:** 15–20 minutes (Terraform provision + image pull + pod startup)
**Total RPO:** ~ 1 minute (async replication of logs and images)
**Incremental DR cost:** ~$2.5K/month (standby infra) + operations overhead

**Trade-off:** Full-hot-standby would halve RTO (5–10 min) but double the cost (~$5K/month). At current scale (assumption: < 100K devices), warm standby is appropriate.

**Failover trigger:** Manual (ops decision) + CloudWatch alarms (DetectAnomalousRego nalFailure) sent to SNS. Automatic failover is risky for first-time deployments.

---

## A5. Security and Observability

### IAM Role Model: IRSA (IAM Roles for Service Accounts)

**Every workload gets its own role.** No shared node instance role for app workloads.

**Example:**
```hcl
data-ingress pod → ServiceAccount → IRSA role (arn:aws:iam::123456:role/skylo-data-ingress)
  Permissions:
    - s3:PutObject on arn:aws:s3:::skylo-logs/data-ingress/*
    - kafka:Produce on topic:devices.normalized (if Kafka external to EKS)
  Deliberately withheld:
    - iam:PassRole, iam:CreateRole
    - ec2:ModifySecurityGroups, ec2:ModifyRouteTable
    - sts:AssumeRole (except to assumed role used for cross-account)
```

**Principle:** Each workload has the **minimum** permissions to do its job. Even if a pod is compromised, attacker can't pivot to modify network, assume other roles, or read secrets outside the pod's scope.

### First 3 AWS Security Services

| Service | Why | Rationale |
|---------|-----|-----------|
| **AWS Config** | Continuous compliance checking + IaC drift detection | Creates the evidence base for SOC 2 (who changed what, when); catches misconfigurations (unencrypted EBS, public S3, open security groups) |
| **GuardDuty** | Threat detection on VPC Flow Logs, DNS, EKS audit logs | The "did something bad actually happen" signal Config doesn't give; detects lateral movement, data exfiltration attempts, anomalous API calls |
| **Security Hub** | Centralized dashboard for Config + GuardDuty + Inspector findings, mapped to CIS/NIST | Single pane of glass; beats switching between three consoles; automatically remediates some findings (e.g., non-compliant resources can trigger Lambda to delete/fix) |

Why not CloudTrail first? **AWS Config depends on CloudTrail**, and Config is where auditors look first for SOC 2. GuardDuty catches active threats. Security Hub aggregates both. CloudTrail is table stakes (enabled everywhere) but doesn't require a separate "first enablement" decision.

### Top 3 Metrics to Alert On

| Metric | Why | SLO/Threshold |
|--------|-----|---|
| **Pod crash-loop / OOMKilled rate** | Earliest signal of a real outage (not just slow, actually broken) | Alert if > 1 restart per pod per 5 min |
| **P99 request latency** (through core-network pods) | Devices don't care the cluster is "up"; they care if sessions timeout. Directly predicts dropped calls | Alert if > 200 ms (adjust per workload) |
| **Pending pod count + node CPU/memory utilization** (per AZ) | Karpenter can provision nodes, but if nodes are maxed, HPA can't scale pods. Also predicts NAT GW saturation and ElastiCache connection limits (both on the data path) | Alert if pending > 5 pods for 2 min or node CPU/mem > 85% |

**Why these three?** They catch failures at different layers: app (restarts), request-path (latency), and infra (capacity). Everything else (network packet loss, disk I/O, etc.) compounds into these three.

### Logging/Monitoring/Alerting Stack

**Amazon Managed Prometheus (AMP) + Grafana + CloudWatch + Fluent Bit:**

- **Prometheus:** Kubernetes-native metrics (pod CPU/memory, request rate/latency per endpoint)
- **Grafana:** Custom dashboards for ops (linked to AMP) + Grafana OnCall for escalation
- **CloudWatch:** AWS service-level signals (NAT GW bytes/sec, TGW throughput, ElastiCache CPU) — not cloud-native
- **Fluent Bit → OpenSearch:** Application logs + VPC Flow Logs + EKS audit logs for SOC 2 retention

**Why not Datadog?** Cost scales with scale; for first regional hub, AMP + CloudWatch + OpenSearch is cheaper and avoids vendor lock-in (all AWS-native).

---

## Assumptions Stated

1. **DX and VPN are pre-configured** between ground station and AWS; this design only handles the hub side (TGW attachment).
2. **No specific device count given;** architecture scales elastically up to 20M devices (Karpenter + HPA can handle). If you need different scale, change instance types + HPA limits.
3. **3GPP workloads are containerized and Kubernetes-compatible.** If legacy binaries require special hardware, ECS on EC2 with GPUs becomes necessary.
4. **Existing Skylo AWS Organization with multiple accounts;** TGW attachment to org-wide TGW is assumed. If not, replace with hub-to-org VPC peering (simpler, less scalable).
5. **Operational overhead is acceptable** (EKS is operationally heavier than ECS). If ops bandwidth is zero, reconsider ECS/Fargate.
6. **SOC 2 scope is infrastructure (Config, GuardDuty, CloudTrail, VPC Flow Logs).** If SOC 2 requires application-level controls (encryption keys, secret management), add HashiCorp Vault or AWS Secrets Manager explicitly.

---

## What I'd do with more time

- Load-test TGW attachment placement (private subnets vs. dedicated tgw-attach tier)
- Confirm actual DX location + expected backhaul distance (to validate ~5–30 ms estimate)
- Size NAT GW + ElastiCache against traffic model (currently order-of-magnitude, not measured)
- Implement canary deployments for failover testing (monthly DR drill)
- Build Terraform test suite (terratest) to validate network connectivity assumptions

---

## Diagram Reference

See accompanying `vpc-architecture.txt` (ASCII) for visual topology.

