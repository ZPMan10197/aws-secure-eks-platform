# Architecture — Secure EKS Platform

**Status:** In progress
**Last updated:** 2026-07-27

---

## 1. Network

### 1.1 Connectivity Model

The following properties of AWS networking drive the subnet and security group design.

| Property | Implication for this design |
|---|---|
| A subnet is "public" only because its route table contains `0.0.0.0/0 → Internet Gateway`. There is no public/private flag. | Subnet tier is a routing decision, reviewable in Terraform. |
| Route tables describe **outbound** paths only. They do not grant inbound access. | Inbound exposure is controlled by security groups and public IP assignment, not routing. |
| Inbound internet reachability requires **three** conditions: an IGW route, a permitting security group, **and** a public IP on the resource. | Worker nodes and RDS are assigned no public IP. This holds even if a routing or SG mistake is made later. |
| Security groups are stateful; return traffic on an established outbound connection is implicitly allowed. | Private subnets can pull container images and reach AWS APIs outbound without any inbound rule. |
| Every VPC route table contains an undeletable `local` route for the VPC CIDR. All subnets can reach all other subnets by private IP. | **Subnets do not provide isolation.** Security groups are the enforcing boundary inside the VPC. |

### 1.2 Design Decisions

- **D-1** — The ALB is placed in public subnets; worker nodes and RDS in private subnets with no public IP addresses. Satisfies NFR-4.
- **D-2** — East-west traffic inside the VPC is restricted by security groups that reference **other security groups**, not CIDR ranges. Because the `local` route makes all subnets mutually reachable, CIDR-based rules would permit any workload in the matching range, and would silently widen as subnets grow. Satisfies NFR-5, NFR-6.
- **D-3** — Private subnets require a NAT Gateway or VPC endpoints for outbound access to container registries and AWS APIs. Node bootstrap and image pulls fail without one. Mechanism and cost tradeoff deferred to OQ-2 / OQ-3.

### 1.3 Not Yet Decided

- Subnet layout: CIDR allocation, count per AZ, sizing
- NAT topology: single NAT Gateway vs. one per AZ (OQ-2, OQ-3)
- Which VPC endpoints, if any, replace NAT traffic

---

## 2. Compute

Not started.

## 3. Data

Not started.

## 4. Identity

Not started.

## 5. Detection

Not started.
