# Skylo Regional Hub — Corrected Design Package (Final v2)

**Complete Design Improvements-Corrected Architecture Documentation**

---

## 📦 Package Contents at a Glance

| File | Size | Purpose | Content |
|------|------|---------|---------|
| `DESIGN.md` | 65 KB | Complete AWS architecture | All 10 fixes integrated (A1–A5 sections) |
| `NETWORK-DESIGN.md` | 16 KB | Network topology + CIDR strategy | Corrected 172.16.0.0/12 org CIDR strategy |
| `vpc.tf` | 15 KB | Terraform for VPC/subnets | Corrected CIDR + per-AZ route tables |
| `DESIGN-IMPROVEMENTS.md` | 50 KB | Detailed Design Improvements breakdown | All 10 Design Improvements with Terraform fixes |
| `layer-architecture.svg` | 17 KB | Three-layer pod architecture diagram | Visual reference for pod deployments |
| `README.md` | Quick start guide | How to use this package, interview tips | All 10 fixes summarized |
| `INDEX.md` | This file | Navigation guide | | Quick reference |

**Total:** ~178 KB of production-ready documentation

---

## 🎯 Quick Navigation

### By Use Case

**For Interview Preparation (60 min total):**
1. Read `README.md` (5 min) — Overview of all fixes
2. Read `DESIGN.md` sections A1–A2 (15 min) — Public surface, compute, operator access
3. Read `DESIGN.md` sections A3–A5 (15 min) — Storage, ground connectivity, security
4. Review `DESIGN-IMPROVEMENTS.md` (15 min) — Pick any 3 Design Improvements to practice explaining
5. Practice whiteboard explanation (10 min) — Use `layer-architecture.svg`

**For Implementation (3–4 hours):**
1. Read `vpc.tf` (5 min) — Understand variable structure
2. Read `DESIGN.md` § A2 (Compute) + § A2.1 (Operator Access) (20 min)
3. Reference `DESIGN.md` § A3.1 (NAT optimization) + § A4 (DR/DX failover) (20 min)
4. Copy Terraform from `DESIGN-IMPROVEMENTS.md` § 6 (NAT endpoints) (10 min)
5. Deploy and test (2.5 hours)

**For Code Review / Design Audit:**
1. Check `DESIGN.md` against `NETWORK-DESIGN.md` (cross-reference alignment)
2. Review `DESIGN-IMPROVEMENTS.md` § Summary Table (all 10 marked resolved)
3. Verify Terraform examples compile (sections A2.1, A3.1, A5.1)
4. Spot-check RTO/RPO claims (sections A4, A5.1)

### By Topic

| Topic | File | Section |
|-------|------|---------|
| **Network CIDR strategy** | `NETWORK-DESIGN.md` | § 2 |
| **Pod autoscaling** | `README.md` | Overview / `DESIGN.md` § A2 |
| **Public surface / NLB** | `DESIGN.md` | § A1.1 |
| **TLS termination** | `DESIGN.md` | § A1.2 |
| **Operator access** | `DESIGN.md` | § A2.1 |
| **ElastiCache failover** | `DESIGN.md` | § A3 |
| **NAT optimization** | `DESIGN.md` | § A3.1 |
| **DX/VPN failover** | `DESIGN.md` | § A4 (Ground Connectivity) |
| **ECR DR replication** | `DESIGN.md` | § A4 (DR: Image Registry) |
| **DDoS/WAF strategy** | `DESIGN.md` | § A5.1 |
| **Security controls** | `DESIGN.md` | § A5.2 |

---

## ✅ All 10 Design Improvements — Fixed

| # | Title | Design Consideration | Fix Location | RTO/Cost Impact |
|---|-------|----------|--------------|-----------------|
| 1 | CIDR Collision | org_cidrs overlapped hub_cidr | `vpc.tf` line 99 + `NETWORK-DESIGN.md` § 2 | **Critical fix** (collision prevention) |
| 2 | Security Model Contradiction | Diagram ≠ prose on public surface | `DESIGN.md` § A1.1 | Consistency check |
| 3 | TLS Termination | Unstated where TLS terminates | `DESIGN.md` § A1.2 | ~5–10% latency impact |
| 4 | ECR Not in DR | No image registry failover | `DESIGN.md` § A4 (DR) | RTO: 10–15 min |
| 5 | DX/VPN Failover | BGP convergence mechanism unclear | `DESIGN.md` § A4 | RTO: 3–5 min |
| 6 | NAT GW Bottleneck | Unmitigation for egress | `DESIGN.md` § A3.1 | VPC endpoints save ~5 Gbps |
| 7 | DDoS/WAF | No protection for public surface | `DESIGN.md` § A5.1 | Cost: $3K/mo + $15/mo |
| 8 | ElastiCache Failover | Overstated claim | `DESIGN.md` § A3 | Clarified: client proxy required |
| 9 | Control Mapping | Promised but not delivered | `DESIGN.md` § A5.2 | Compliance evidence |
| 10 | Operator Access | No path to private EKS | `DESIGN.md` § A2.1 | Ops feasibility |

---

## 🏗️ Architecture Layers

### Three-Layer Pod Architecture (From Layer-Architecture)

| Layer | Role | Pods | CPU | Replicas |
|-------|------|------|-----|----------|
| **Data-Ingress** | Parse + normalize raw 3GPP | Parse → Kafka | 500m | 5 (HPA 3–100/AZ) |
| **Core-Network** | Session mgmt + routing decisions | Redis queries → gRPC to UPF | 1000m | 5 (HPA 3–100/AZ) |
| **UPF** | Packet forwarding + QoS | Bearer setup → rate limit → forward | 2000m | 5 (HPA 3–100/AZ) |

### Network Tiers (From NETWORK-DESIGN)

| Tier | CIDR | Role | Security |
|------|------|------|----------|
| **Public** | 10.100.0–2/24 (per AZ) | NAT + NLB | One SG (NLB-only internet-facing) |
| **Private** | 10.100.10–30/24 (per AZ) | EKS nodes + pods | SG allows only TGW + NLB |

### CIDR Strategy (Fixed)

| Family | Range | Purpose | Strategy |
|--------|-------|---------|----------|
| **Hub** | 10.0.0.0/9 | Hub VPCs | Sequential /16 per hub |
| **Ground** | 10.128.0.0/9 | Ground segments | Sequential /16 per hub |
| **Org** | **172.16.0.0/12** | Org accounts | **Different RFC1918 block** |
| **Pod** | 100.64.0.0/10 (RFC 6598) | Cluster-local | Reused per hub, no TGW routing |

---

## 📊 Key Metrics & SLAs

### Service Time Budget (End-to-End)

| Hop | Segment | Latency | Notes |
|-----|---------|---------|-------|
| Ground → TGW | Backhaul | ~5–30 ms | Physical distance (not hub's control) |
| TGW → Private subnet | AWS hop | ~1–2 ms | Same region |
| Data-ingress → Core-network | In-VPC | < 1 ms | Typically same AZ |
| Core-network → NLB | In-VPC | < 1 ms | Same AZ |
| NLB → IGW → Customer | Internet | ~20–100+ ms | Customer network distance |
| **AWS hops total (TGW to NLB)** | | **~3–5 ms** | Hub-controlled portion |

### RTO / RPO by Failure

| Failure Mode | RTO | RPO | Mitigation |
|--------------|-----|-----|-----------|
| Data-ingress pod crash | < 5 sec | 0 | Kafka rebalance |
| Core-network pod crash | < 5 sec | 0 | Redis multi-AZ, session state preserved |
| UPF pod crash | < 100 ms | 0 (packets only) | Automatic failover to healthy pod |
| ElastiCache node failure | ~30 sec | 0 | Cluster-mode replica promotion |
| NAT GW failure | ~60 sec | Minimal | Auto-failover in same AZ, second NAT in other AZ |
| DX circuit failure | ~3–5 min | 0 | BGP convergence to VPN |
| ECR primary region failure | ~10–15 min | 0 | Cross-region replication |

### Scaling Thresholds

| Metric | Normal | Alert | Scale-up Action |
|--------|--------|-------|-----------------|
| Data-ingress CPU | < 60% | > 75% | +3 pods (HPA) |
| Core-network latency (P99) | < 50 ms | > 100 ms | +5 pods (HPA) |
| NAT GW egress | < 30 Gbps | > 40 Gbps | Add NAT GW to AZ |
| ElastiCache CPU | < 70% | > 85% | Upgrade node type |

---

## 🔐 Security Posture

### Least-Privilege IAM
- ✅ IRSA per pod (no shared instance role)
- ✅ No wildcard actions/resources
- ✅ No `PassRole`/`CreateRole` for workloads
- ✅ Network stays platform-owned (pods can't modify SGs/routes)

### Network Segmentation
- ✅ Single public surface (NLB only)
- ✅ Private-only EKS control plane
- ✅ Per-AZ route tables (no cross-AZ single point of failure)
- ✅ TGW route table separation (ground ≠ org traffic)

### Compliance
- ✅ CloudTrail + Config (evidence for SOC 2)
- ✅ GuardDuty + Security Hub (threat detection)
- ✅ VPC Flow Logs (audit trail)
- ✅ CIS + NIST mapping (see `DESIGN.md` § A5.2)

---

## 📝 Before Using This Package

### Checklist for Interview

- [ ] Read all of `README.md` (5 min)
- [ ] Read `DESIGN.md` sections A1–A3 (20 min)
- [ ] Read `DESIGN.md` sections A4–A5 (20 min)
- [ ] Review `DESIGN-IMPROVEMENTS.md` summary table (5 min)
- [ ] Practice explaining all 3 layers (data-ingress, core-network, UPF) from memory
- [ ] Practice explaining why org CIDR is now `172.16.0.0/12` (not 10.x.x.x)
- [ ] Be ready to discuss any Design Consideration + fix in depth

### Checklist for Deployment

- [ ] Confirm `org_cidrs` in `vpc.tf` is `172.16.0.0/12` (line 99)
- [ ] Confirm TGW route table separation is implemented (see `DESIGN.md` § A4)
- [ ] Confirm Session Manager setup for operator access (see `DESIGN.md` § A2.1)
- [ ] Confirm VPC endpoints for S3/ECR are deployed (see `DESIGN.md` § A3.1)
- [ ] Confirm WAF rules are attached to NLB (see `DESIGN.md` § A5.1)

---

## 📚 Integration with Other Deliverables

| Document | Related To | Where |
|----------|-----------|-------|
| `final-v1/docs/LAYER-ARCHITECTURE.md` | Three-layer pod architecture | Complements this network/compute design |
| `final-v1/docs/LAYER-ARCHITECTURE-SUMMARY.md` | Pod interview talking points | Use with `DESIGN.md` for full system explanation |
| `final-v1/diagrams/layer-architecture.svg` | Pod deployment diagram | Visual for three-layer scaling |

---

## 🚀 Next Steps

1. **For Interview:** Read this entire package (90 min total)
2. **For Deployment:** Copy `vpc.tf` and Terraform examples from `DESIGN-IMPROVEMENTS.md`
3. **For Team:** Share `README.md` + `DESIGN.md` with stakeholders
4. **For GitHub:** Upload entire `skylo-demo/` folder as `final-v1/` in your repo

---

## 📞 Quick Reference: Key Sections

- **Why three layers?** → `README.md` + `final-v1/docs/LAYER-ARCHITECTURE.md`
- **Why org CIDR changed?** → `NETWORK-DESIGN.md` § 2 + `DESIGN-IMPROVEMENTS.md` § 1
- **How do operators access the hub?** → `DESIGN.md` § A2.1
- **How does DX failover work?** → `DESIGN.md` § A4 (Ground Connectivity Failover)
- **What about DDoS?** → `DESIGN.md` § A5.1
- **Are we compliant?** → `DESIGN.md` § A5.2 (CIS + NIST mapping)

---

**Version:** skylo-demo v2 (All Design Improvements corrected)

**Status:** ✅ Production ready for interview and implementation

**Good luck! 🚀**

