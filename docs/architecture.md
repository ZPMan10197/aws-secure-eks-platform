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
- **D-3** — Private subnets require outbound egress for node bootstrap, container image pulls, and AWS API calls. Node registration and image pulls fail without it. Mechanism decided in D-4.
- **D-4** — Egress is provided by **managed NAT Gateways, one per Availability Zone (two total)**. See §1.3. Closes OQ-2 and OQ-3.

### 1.3 Decision Record: NAT Topology

**Decision.** Two managed NAT Gateways, one per AZ, each in that AZ's public subnet. Each private subnet routes `0.0.0.0/0` to the NAT Gateway in its own AZ.

**Alternatives considered.**

| Option | Rejected because |
|---|---|
| Single NAT Gateway, shared across AZs | Halves cost, but creates a cross-AZ dependency: an AZ failure removes egress for workloads in the surviving AZ, so a Multi-AZ workload is not actually AZ-independent. Also incurs cross-AZ data transfer charges on all egress from the non-local AZ. |
| Self-managed NAT instance | Cheaper at this scale, but shifts patching, monitoring, and failover onto the operator. Contradicts the operability posture of the rest of the platform, and an unpatched internet-facing instance is a security liability. |
| VPC endpoints only, no NAT | Interface and gateway endpoints cover AWS services (ECR, S3, Secrets Manager, STS) but not arbitrary internet destinations. Insufficient for node bootstrap and general egress. Revisit as a **cost reduction on top of** NAT, not a replacement. |

**Rationale.** AZ-independent egress is a capability this platform is built to demonstrate, not an incidental property — a Multi-AZ workload whose egress depends on a single AZ is Multi-AZ in name only. Per-AZ NAT also avoids cross-AZ data transfer charges on egress.

**Cost.** ~$0.045/hour per NAT Gateway plus per-GB processing; ~$33/month each if run continuously. Under NFR-25 the environment is destroyed when idle, so realistic exposure is a few cents per working session. Does not threaten the NFR-27 ceiling.

**Note.** Latency is *not* a justification. Cross-AZ round trips are sub-millisecond and immaterial here.

### 1.4 Not Yet Decided

- Subnet layout: CIDR allocation, count per AZ, sizing
- Which VPC endpoints are added to reduce NAT data processing charges

---

## 2. Compute

Not started.

## 3. Data

Not started.

## 4. Identity

Not started.

## 5. Detection

Not started.
