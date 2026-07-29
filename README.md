# aws-secure-eks-platform

A multi-AZ Amazon EKS platform on AWS, built design-first: requirements and architecture decisions are written and reviewed before infrastructure is provisioned.

**Current phase: architecture.** The network layer is specified; Terraform has not been written yet. See [Status](#status) for exactly what exists today.

---

## Target Architecture

```
Internet
  → Route 53          DNS
  → CloudFront        edge TLS termination, caching
  → AWS WAF           managed rule groups, rate limiting
  → Application LB    public subnets
  → Amazon EKS        private worker nodes
  → RDS PostgreSQL    Multi-AZ, private subnets, no public access
```

Single region (`us-east-1`), single account, two Availability Zones.

The workload itself is deliberately trivial — one container, one endpoint, one database read. It exists to give the security controls something real to protect: a network path to segment, credentials to scope, and an identity to constrain. **The platform is the deliverable, not the application.**

---

## Documentation

| Document | Contents |
|---|---|
| [Requirements](docs/requirements.md) | Scope, functional and non-functional requirements, control validation scenarios, acceptance criteria |
| [Architecture](docs/architecture.md) | Design decisions and rejected alternatives, recorded as ADRs |

Requirements carry stable IDs (`FR-*`, `NFR-*`) so architecture decisions can cite the requirement they satisfy.

---

## Status

| Area | State |
|---|---|
| Requirements specification | Complete |
| Architecture — network | Decided (subnet layout outstanding) |
| Architecture — compute, data, identity, detection | Not started |
| Threat model | Not started |
| Terraform | Not started |
| Control validation scenarios | Not started |

---

## Security Posture

The controls this platform is being built to enforce:

- Worker nodes and RDS in private subnets, no public IP addresses
- Security groups reference other security groups rather than CIDR ranges — subnets do not isolate, security groups do
- Pod-level AWS permissions via IRSA; no application permissions on the node instance role
- Database credentials resolved at runtime from Secrets Manager, never in source, images, or environment variables
- Encryption at rest with customer-managed KMS keys, including Kubernetes secrets
- Default-deny Kubernetes Network Policies; Pod Security Standards enforced at `restricted`
- Detection via CloudTrail, AWS Config, GuardDuty, and Security Hub

Each control is validated by an exercise that first demonstrates the failure it prevents — see §7 of the requirements.

---

## Operating Model

The environment is provisioned only during active work and destroyed afterward. All infrastructure is defined in Terraform so that a rebuild is a single apply. Spend is tracked against a defined ceiling with billing alarms — see §5.4 of the requirements.

---

## Why Design-First

The expensive mistakes in platform work are design mistakes, not syntax mistakes. Recording rejected alternatives alongside chosen ones keeps the reasoning reviewable, and makes it obvious when a later change contradicts an earlier decision.

---

## License

[MIT](LICENSE)
