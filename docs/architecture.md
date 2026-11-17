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

### 1.4 Decision Record: Address Space and Subnet Layout

**Decision.** VPC CIDR `10.0.0.0/16`, divided across two Availability Zones:

| Subnet | CIDR | Usable | Contents |
|---|---|---|---|
| public-a | `10.0.0.0/24` | 251 | ALB network interfaces, NAT Gateway |
| public-b | `10.0.1.0/24` | 251 | ALB network interfaces, NAT Gateway |
| private-a | `10.0.16.0/20` | 4,091 | EKS worker nodes and pods |
| private-b | `10.0.32.0/20` | 4,091 | EKS worker nodes and pods |

Blocks `10.0.2.0`–`10.0.15.255` and everything above `10.0.48.0` remain unallocated.

**Why private subnets are sized an order of magnitude larger.** The Amazon VPC CNI assigns every pod a routable VPC address from its node's subnet — not an overlay address. Nodes additionally pre-allocate a warm pool of addresses ahead of scheduling, so consumption is driven by instance type rather than by running pod count (an `m5.large` claims roughly 30 addresses on join). A `/24` private subnet would therefore cap the cluster near eight nodes irrespective of workload size.

The failure mode is silent: pods remain in `ContainerCreating` with a CNI address-assignment error. Nothing crashes and the scheduler reports no fault, so the symptom is routinely misdiagnosed as an image pull or runtime problem.

Public subnets stay at `/24` because they hold only load balancer interfaces and NAT Gateways.

**Why gaps are left between allocations.** VPC address space carries no cost, and subnet CIDRs cannot be resized after resources occupy them — correcting an undersized range means rebuilding the VPC. Reserving headroom is free; reclaiming it is not.

**Alignment constraint.** A prefix must begin at a multiple of its own size. `10.0.0.0/20` spans blocks 0–15 and would overlap the public subnets, making `10.0.16.0/20` the first legal start; `10.0.32.0/20` is the next.

**Satisfies** NFR-1, NFR-4.

### 1.5 Decision Record: Availability Zone Selection

**Decision.** Availability Zones are resolved at plan time from the `aws_availability_zones` data source, filtered to `available`, and the first two are used. AZ names are never hardcoded.

**Rationale.** AWS maps AZ *names* (`us-east-1a`) to physical zones independently per account, so the same name refers to different infrastructure in different accounts. The stable identifier is the AZ ID (`use1-az1`). Hardcoding names therefore produces configuration that is not portable across accounts and silently changes meaning when reused.

Additionally, not every AZ in a region supports every service or instance type — `us-east-1e` has historically lacked EKS and several instance families. Querying available zones avoids a failure class that cannot be predicted from the name itself.

**Satisfies** NFR-1, NFR-23.

### 1.6 Not Yet Decided

- Remote state backend (S3 bucket and lock table must be bootstrapped)
- Which VPC endpoints are added to reduce NAT data processing charges

---

## 2. Compute

### 2.1 Decision Record: Worker Node Provisioning

**Decision.** EKS **managed node groups** on EC2, placed in the private subnets. Closes OQ-1.

**Alternatives considered.**

| Option | Rejected because |
|---|---|
| AWS Fargate for EKS | Removes node management, but provides no node instance role and no DaemonSet support. VS-2 demonstrates privilege escalation through an over-permissioned node role and its remediation via IRSA — on Fargate that failure mode does not exist, so the scenario cannot be built. DaemonSet support is also a precondition for most runtime security and log collection agents. |
| Self-managed node groups | Equivalent capability, but moves AMI selection, bootstrap scripting, and upgrade orchestration onto the operator for no gain at this scale. |
| Karpenter | The current standard for production autoscaling, but autoscaling is explicitly out of scope (requirements.md §3.2) and it introduces a controller, its own IAM surface, and provisioner CRDs. Adding it would be scope creep. |

**Rationale.** The node instance role is a first-class subject of this platform's security story, not an implementation detail. Managed node groups also match the deployment model the rest of the architecture assumes — NFR-4 places worker nodes in private subnets with no public IP, which presumes nodes the operator owns.

AWS retains responsibility for the control plane; the operator retains responsibility for node AMI version, security group, instance role, and upgrade cadence. That division is the one worth being able to articulate.

**Cost.** EKS control plane bills $0.10/hour (~$73/month continuous) independent of node count. Worker nodes bill at standard EC2 rates. Under NFR-25 the environment is destroyed when idle.

**Satisfies** NFR-4, NFR-9. **Enables** VS-2.

### 2.2 Decision Record: Control Plane Endpoint Access

**Decision.** Both endpoints enabled. The private endpoint serves in-VPC traffic; the public endpoint is restricted to a single operator address supplied as `var.operator_cidr` (a `/32`). The value is provided through `terraform.tfvars` and is not committed.

**Alternatives considered.**

| Option | Rejected because |
|---|---|
| Public only | The API server would accept connections from any source address. Authentication still applies, but the attack surface includes the entire internet for no operational benefit. |
| Private only | The strongest posture, and the correct choice in production. It requires in-VPC access to operate the cluster — a bastion host, VPN, or SSM port forwarding — each of which adds standing cost and setup time that the NFR-27 ceiling does not justify for a single operator. |

**Rationale.** Worker nodes reach the control plane over the private endpoint and are unaffected by the public setting. The public endpoint exists solely so a single operator can run `kubectl` without standing infrastructure.

**Known weaknesses, stated rather than implied.**

- The operator address is residential and dynamic. When it changes the allowlist fails closed, and the tempting remedy is widening the range. Production resolves this with a static egress address or a VPN, not a wider allowlist.
- A CIDR allowlist is a filter, not an authentication control. It reduces exposure; it is not what secures the cluster.

**Defense in depth.** Three independent layers gate the API server: the allowlist governs *where from*, IAM governs *who*, Kubernetes RBAC governs *what*. Each is bypassable in isolation and none is sufficient alone.

**Satisfies** NFR-20.

### 2.3 Not Yet Decided

- Kubernetes version and node AMI type
- Instance type and node group sizing
- Cluster secrets encryption key (NFR-21)
- Cluster authentication mode — EKS access entries vs. `aws-auth` ConfigMap

> **Flag for implementation.** The IAM principal that creates an EKS cluster is automatically granted cluster-admin. Terraform will create this cluster using the operator's SSO role, so that role receives full Kubernetes access with no explicit mapping. Every other principal requires one. Revisit when the authentication mode is decided.

Not started.

## 3. Data

Not started.

## 4. Identity

Not started.

## 5. Detection

Not started.
