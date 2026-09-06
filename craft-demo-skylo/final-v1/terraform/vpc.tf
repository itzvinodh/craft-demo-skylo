################################################################################
# Skylo Regional Hub — Foundational Network Terraform
#
# SCOPE: VPC, subnets (2 tiers x 3 AZs), route tables, IGW, NAT, TGW attachment.
# Does NOT include: EKS/ECS, security groups (separate sg.tf, platform-owned),
# VPC endpoints (separate endpoints.tf, changes often), KMS, or monitoring.
#
# DESIGN RATIONALE:
# - Three-tier subnet model (public/private per AZ) with per-AZ route tables
#   to avoid cross-AZ single points of failure (NAT, routing).
# - VPC CNI custom networking: pod CIDR (100.64.0.0/16) is secondary, not
#   primary, so pod scaling never competes with node IP budget.
# - TGW attachment in private subnets, not dedicated tier — trade-off between
#   blast radius (dedicated is cleaner) vs. operational complexity (separate tier).
#   Add dedicated tier if security review demands it later.
# - CIDR strategy: three disjoint RFC1918 families (10.0.0.0/9 hubs,
#   10.128.0.0/9 ground, 172.16.0.0/12 org) — structural collision prevention.
#
# MODULE DECOMPOSITION (how this would be split in production):
# - network-core/ (this file): VPC shell, subnets, RTs, IGW, NAT, TGW.
# - network-endpoints/ (separate): VPC endpoints (S3, ECR, STS, CloudWatch).
# - security-groups/ (separate, platform-owned): sg-nlb-public, sg-eks-private.
# - compute-eks/ (separate): EKS cluster, Karpenter, node IAM.
# Each module lives in a separate directory so teams own boundaries, not blobs.
#
################################################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # In production: store state in S3 + DynamoDB lock, separate AWS account for tfstate.
  # backend "s3" {
  #   bucket         = "skylo-tfstate"
  #   key            = "us-west-2/network-core/terraform.tfstate"
  #   region         = "us-west-2"
  #   dynamodb_table = "terraform-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project     = "skylo"
      Environment = var.environment
      ManagedBy   = "terraform"
      Module      = "network-core"
    }
  }
}

################################################################################
# VARIABLES
################################################################################

variable "region" {
  default     = "us-west-2"
  description = "AWS region for this hub"
}

variable "environment" {
  default     = "prod"
  description = "Environment tag (prod, staging)"
}

variable "hub_cidr" {
  # Allocated from central IPAM (10.0.0.0/9 supernet reserved for all hub VPCs).
  # This is hub #1; hub #2 would be 10.101.0.0/16, hub #3 = 10.102.0.0/16, etc.
  # Hardcoding here because the exercise allows variables; in production, fetch
  # from aws_ec2_network_insights_path or data source that queries IPAM.
  default     = "10.100.0.0/16"
  description = "Hub VPC primary CIDR block (from 10.0.0.0/9 supernet)"
}

variable "pod_secondary_cidr" {
  # RFC 6598 (shared/documentation space), cluster-local only.
  # Reused identically per hub (never crosses TGW), so no collision risk.
  # Associated as secondary CIDR at VPC level; subnets draw from it via
  # VPC CNI custom networking + prefix delegation.
  default     = "100.64.0.0/16"
  description = "Secondary CIDR for EKS pod IPs (RFC 6598, cluster-local)"
}

variable "ground_cidr" {
  # From 10.128.0.0/9 supernet (ground segments).
  # Hub #1: 10.200.0.0/16, hub #2: 10.201.0.0/16, etc.
  default     = "10.200.0.0/16"
  description = "Ground station segment (reachable via DX)"
}

variable "org_cidrs" {
  # From 172.16.0.0/12 supernet (org/shared-services accounts).
  # Deliberately DIFFERENT RFC1918 block from hub/ground (which share 10.0.0.0/8).
  # As Skylo adds hubs, none of them can collide with org space — structural guarantee.
  type        = list(string)
  default     = ["172.16.0.0/12"]
  description = "Org accounts' CIDR blocks (from different RFC1918 family)"
}

variable "availability_zones" {
  type        = list(string)
  default     = ["us-west-2a", "us-west-2b", "us-west-2c"]
  description = "3 AZs for resilience to single-AZ failure"
}

variable "transit_gateway_id" {
  # Provided by central network account via RAM share.
  # TGW itself is out of scope for this file; assume it exists and is attached.
  # In production: data source aws_ec2_transit_gateway + aws_ec2_transit_gateway_route_table.
  type        = string
  description = "TGW ID (data source or variable, assume it exists)"
}

################################################################################
# LOCALS
################################################################################

locals {
  # Replicated for every per-AZ resource (subnets, route tables, NAT, EIPs).
  # Keying everything on the same AZ string ensures 1:1 mapping at deployment time.
  az_index = { for i, az in var.availability_zones : az => i }

  # Human-readable tags for resources
  common_tags = {
    Terraform   = "true"
    Hub         = "us-west-2"
    TierModel   = "two-tier-public-private"
    CIDRStrategy = "three-family-disjoint"
  }
}

################################################################################
# VPC
################################################################################

resource "aws_vpc" "hub" {
  cidr_block = var.hub_cidr

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name = "skylo-hub-${var.region}"
  })
}

# Secondary CIDR for pod IPs (VPC CNI custom networking).
# Why separate resource? Lifecycle independence — primary VPC CIDR is immutable
# (can't resize in-place), but secondary can be added/removed dynamically.
# Pod scaling happens on 100.64.0.0/16 prefix delegation, not on 10.100.x.x.
resource "aws_vpc_ipv4_cidr_block_association" "pods" {
  vpc_id            = aws_vpc.hub.id
  cidr_block        = var.pod_secondary_cidr
  depends_on        = [aws_vpc.hub]
}

################################################################################
# INTERNET GATEWAY
################################################################################

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.hub.id

  tags = merge(local.common_tags, {
    Name = "skylo-igw-${var.region}"
  })
}

################################################################################
# SUBNETS — 2 tiers x 3 AZs
#
# Public tier: NAT Gateways + NLB (customer ingress point).
# Private tier: EKS nodes, TGW attachment ENIs, pod IPs.
#
# Why /24 for 251 IPs? Karpenter ceiling is ~100 nodes/AZ. /24 gives:
# 251 usable - 1 (network) - 1 (broadcast) = 249 available.
# Headroom for TGW attachment ENI, VPC endpoint ENIs, and scaling buffer.
# Subnets don't resize in-place, so sized for target state, not day-1.
################################################################################

resource "aws_subnet" "public" {
  for_each = local.az_index

  vpc_id                  = aws_vpc.hub.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.hub_cidr, 8, each.value)
  map_public_ip_on_launch = false # NAT/NLB get explicit EIPs; no auto-assign

  tags = merge(local.common_tags, {
    Name = "skylo-public-${each.key}"
    Tier = "public"
  })
}

resource "aws_subnet" "private" {
  for_each = local.az_index

  vpc_id                  = aws_vpc.hub.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.hub_cidr, 8, (each.value + 1) * 10) # Offset by 10
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "skylo-private-${each.key}"
    Tier = "private"
  })
}

################################################################################
# NAT GATEWAYS — one per AZ (not shared cross-AZ)
#
# Why not share a single NAT across AZs for cost savings?
# Shared NAT becomes a single-AZ-failure single point of failure.
# If NAT's AZ fails, other AZs lose egress until NAT recovers.
# Constraint says "resilient to single-AZ failure"; this violates it.
# Cost of extra NATs (~$32/month each) is trivial vs. unplanned downtime.
################################################################################

resource "aws_eip" "nat" {
  for_each = local.az_index

  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "skylo-nat-eip-${each.key}"
  })

  depends_on = [aws_internet_gateway.igw]
}

resource "aws_nat_gateway" "hub" {
  for_each = local.az_index

  subnet_id     = aws_subnet.public[each.key].id
  allocation_id = aws_eip.nat[each.key].id

  tags = merge(local.common_tags, {
    Name = "skylo-nat-${each.key}"
  })

  depends_on = [aws_internet_gateway.igw]
}

################################################################################
# ROUTE TABLES
#
# Public tier: shared across all 3 AZs (identical routing to IGW).
# Private tier: one per AZ (each points to its own NAT, not shared).
#
# Why per-AZ private route tables? To avoid cross-AZ NAT dependency.
# Why NOT per-AZ public route tables? All public subnets route the same way (0/0→IGW),
# so sharing one table is safe (no AZ-specific configuration).
################################################################################

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.hub.id

  tags = merge(local.common_tags, {
    Name = "skylo-rt-public"
  })
}

resource "aws_route" "public_to_igw" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# Private route tables — one per AZ.
resource "aws_route_table" "private" {
  for_each = local.az_index

  vpc_id = aws_vpc.hub.id

  tags = merge(local.common_tags, {
    Name = "skylo-rt-private-${each.key}"
  })
}

# Default route: 0/0 → NAT in the same AZ (not cross-AZ).
resource "aws_route" "private_to_nat" {
  for_each = aws_route_table.private

  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.hub[each.key].id
}

# Ground segment: 10.200.0.0/16 → TGW.
# Multiple ground subnets possible (future); hardcoded as example.
resource "aws_route" "private_to_ground" {
  for_each = aws_route_table.private

  route_table_id         = each.value.id
  destination_cidr_block = var.ground_cidr
  transit_gateway_id     = var.transit_gateway_id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.hub]
}

# Org traffic: 172.16.0.0/12 → TGW.
# TGW route table separation (ground vs. org) is out of scope for this file;
# assume TGW's own route tables (not VPC route tables) enforce segmentation.
resource "aws_route" "private_to_org" {
  # Flatten a list of routes (one per private RT, one per org CIDR).
  for_each = { for pair in flatten([
    for rt_key, rt in aws_route_table.private : [
      for cidr in var.org_cidrs : {
        key = "${rt_key}-${cidr}"
        rt  = rt.id
        cidr = cidr
      }
    ]
  ]) : pair.key => pair }

  route_table_id         = each.value.rt
  destination_cidr_block = each.value.cidr
  transit_gateway_id     = var.transit_gateway_id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.hub]
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

################################################################################
# TRANSIT GATEWAY ATTACHMENT
#
# Attaches this hub VPC to the org-wide TGW for ground (DX) and org (east-west) traffic.
# TGW itself is provisioned and shared from the network account (data source).
# This file only creates the attachment; route table separation (ground vs. org)
# is the TGW's own route table config, not this VPC's concern.
#
# Why attach in private subnets, not a dedicated tier?
# Pro (dedicated tier): cleaner blast-radius separation (workload vs. transit traffic).
# Con (dedicated tier): extra subnet management complexity for this first hub.
# Compromise: attach in private, add dedicated tier if security review demands it.
################################################################################

resource "aws_ec2_transit_gateway_vpc_attachment" "hub" {
  transit_gateway_id = var.transit_gateway_id
  vpc_id             = aws_vpc.hub.id
  subnet_ids         = [for s in aws_subnet.private : s.id]

  tags = merge(local.common_tags, {
    Name = "skylo-hub-tgw-attach"
  })
}

################################################################################
# OUTPUTS (for consumption by other modules)
################################################################################

output "vpc_id" {
  value       = aws_vpc.hub.id
  description = "VPC ID for reference by security-groups, compute-eks modules"
}

output "private_subnet_ids" {
  value       = [for s in aws_subnet.private : s.id]
  description = "Private subnet IDs (where EKS nodes and pods live)"
}

output "public_subnet_ids" {
  value       = [for s in aws_subnet.public : s.id]
  description = "Public subnet IDs (where NLB and NAT live)"
}

output "pod_secondary_cidr" {
  value       = aws_vpc_ipv4_cidr_block_association.pods.cidr_block
  description = "Pod secondary CIDR (passed to VPC CNI custom networking config)"
}

output "nat_gateway_ids" {
  value       = { for az, nat in aws_nat_gateway.hub : az => nat.id }
  description = "NAT Gateway IDs per AZ (for monitoring, debugging)"
}

output "tgw_attachment_id" {
  value       = aws_ec2_transit_gateway_vpc_attachment.hub.id
  description = "TGW attachment ID (for monitoring, compliance)"
}

################################################################################
# COMMENTED STUB: EKS/ECS CLUSTER
#
# The compute module (EKS or ECS) would be called here, consuming outputs above.
# Kept out of this file because compute is a separate concern, separate module.
#
# module "eks_cluster" {
#   source = "../compute-eks"
#
#   cluster_name           = "skylo-hub-${var.region}"
#   vpc_id                 = aws_vpc.hub.id
#   private_subnet_ids     = [for s in aws_subnet.private : s.id]
#   pod_secondary_cidr     = aws_vpc_ipv4_cidr_block_association.pods.cidr_block
#   cluster_endpoint_public_access = false  # Private only, no internet-facing API
#
#   node_iam_role_name     = "skylo-eks-node-role"
#   karpenter_provisioner  = "skylo-default"
#
#   depends_on = [
#     aws_ec2_transit_gateway_vpc_attachment.hub,
#     aws_nat_gateway.hub
#   ]
# }
#
# module "security_groups" {
#   source = "../security-groups"
#
#   vpc_id                 = aws_vpc.hub.id
#   eks_cluster_sg_name    = "skylo-eks-private"
#   nlb_sg_name            = "skylo-nlb-public"
#
#   # NLB SG allows 443/80 in from 0/0 (customer ingress).
#   # EKS SG allows inbound from NLB SG (internal) + ground/org CIDRs (TGW).
#   # Platform team owns this module; app teams cannot modify SGs.
# }
################################################################################
