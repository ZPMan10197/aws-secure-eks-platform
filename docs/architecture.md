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

### 2.3 Decision Record: Kubernetes Version and Node AMI

**Decision.** Kubernetes **1.37** on **Amazon Linux 2023** worker nodes.

**Version rationale.** 1.37 is the EKS default version, which AWS assigns only after a release has proven stable in the field, so the add-on and tooling immaturity that normally argues for trailing one release behind does not apply. It also carries the longest standard-support runway (ending 2027-11-30), avoiding both a forced upgrade and the extended-support price increase.

**Support lifecycle and its cost.** EKS versions move through standard support (~14 months, $0.10/hour), extended support (a further 12 months, **$0.60/hour**), then forced upgrade. The 6x increase is deliberate: remaining on an unsupported version is priced to be more expensive than upgrading. Version currency is therefore a cost control, not only a security one.

**AMI rationale.** Amazon Linux 2023 is the default for managed node groups and the dominant choice in production, so node-level controls demonstrated here — IMDSv2 enforcement, instance role scoping, patch cadence — transfer directly to real environments.

**Alternative considered.**

| Option | Rejected because |
|---|---|
| Bottlerocket | Materially more hardened: read-only root filesystem, no shell, no package manager, updates by immutable image swap, so container escape yields a far less useful host. Rejected here because the hardening is supplied by the image rather than demonstrated by the operator, and because debugging requires a separate admin container rather than familiar tooling. It would be the stronger choice for a production security-sensitive workload. |

**Note.** AWS defaults optimize for compatibility and least surprise, not for security posture — the default security group, the default network ACL, and this AMI selection are all examples. "It is the default" is not a security justification.

### 2.4 Decision Record: Node Group Sizing

**Decision.** Two `t3.medium` nodes, one per Availability Zone. Minimum 2, maximum 2, desired 2.

**Rationale.** Two nodes is the minimum that satisfies NFR-1 and NFR-3 — a single node means an AZ failure takes the workload with it. Autoscaling is out of scope (requirements.md §3.2), so minimum and maximum are pinned rather than left to range.

`t3.medium` is selected on pod capacity rather than CPU. Pods per node is bounded by ENI limits, not compute: `t3.medium` allows 3 ENIs × 6 IPv4 addresses = 18, less one for the node itself = **17 pods**. Expected load is roughly four pods per node — two DaemonSets (`aws-node`, `kube-proxy`), plus CoreDNS and application replicas — so the ceiling is not approached. `t3.small` was rejected on memory headroom once kube-system DaemonSets are scheduled; `m5.large` pays for capacity that is not used.

**Address consumption.** Two nodes claim roughly 34 addresses from a 4,091-address `/20`. The sizing in §1.4 is what makes this a non-issue.

**Noted but not adopted.** VPC CNI prefix delegation raises per-node pod capacity by allocating `/28` prefixes to ENI slots rather than single addresses, lifting `t3.medium` past the Kubernetes default cap of 110 pods per node. It is the correct first remedy for pod-density pressure — before larger instances — but it allocates address space in whole blocks and requires contiguous `/28` ranges, trading instance cost for subnet fragmentation risk. Not needed at this scale.

### 2.5 Decision Record: Secrets Encryption

**Decision.** Kubernetes Secrets are encrypted with envelope encryption using a **customer-managed KMS key**.

**Rationale.** EKS encrypts etcd with an AWS-owned key by default, which the account holder can neither inspect nor revoke. A customer-managed key adds a second layer: Kubernetes generates a data key per secret, KMS encrypts the data key, and both ciphertexts are stored in etcd. Reading etcd directly yields nothing usable.

The operational properties are what matter: key usage is recorded in CloudTrail, the key policy is auditable, and revoking the key renders the secrets permanently unreadable — a containment control for a compromised cluster.

**Cost.** $1/month per key plus request charges. The key persists through `terraform destroy`: KMS enforces a 7–30 day waiting period before deletion, so this is a small standing charge rather than a per-session one.

**Satisfies** NFR-7, NFR-21.

### 2.6 Decision Record: Cluster Authentication Mode

**Decision.** EKS **access entries** (`API` authentication mode).

**Alternative considered.**

| Option | Rejected because |
|---|---|
| `aws-auth` ConfigMap | Stores IAM-to-Kubernetes mappings as a ConfigMap in `kube-system`. Because the data lives in etcd rather than behind an AWS API, changes are invisible to CloudTrail, cannot be restricted by IAM, and are not manageable as Terraform-tracked state. A malformed edit removes all administrative access with no AWS-side recovery path. AWS is migrating away from it. |

**Rationale.** Access entries are a first-class AWS API: mappings are Terraform-managed resources, changes appear in CloudTrail, and access is governed by IAM rather than by who can edit a ConfigMap.

**Bootstrap behavior.** The IAM principal that creates the cluster receives cluster-admin automatically through a bootstrap access entry. This platform is created by the operator's SSO role, so that role has full Kubernetes access without explicit configuration. Every other principal requires an explicit `aws_eks_access_entry`. This is convenient for a single operator and a real consideration in a team: cluster access can originate from who ran `terraform apply` rather than from declared policy.

**Satisfies** NFR-11.

### 2.7 Not Yet Decided

- Node group remote access configuration (SSH key vs. SSM-only)

## 3. Data

Not started.

## 4. Identity

Not started.

## 5. Detection

Not started.
