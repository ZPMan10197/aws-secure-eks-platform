# Requirements — Secure EKS Platform

**Status:** Draft
**Owner:** Zeshawn Manzoor
**Last updated:** 2026-07-26

---

## 0. How to Read This Document

Requirements are tagged with a short ID so any single line can be referenced in review
(e.g. "I disagree with NFR-9") without quoting it. `§` means "section".

| Prefix | Meaning | Answers |
|---|---|---|
| **FR** | Functional Requirement | What the system *does* |
| **NFR** | Non-Functional Requirement | How well it does it — security, availability, cost, operability |
| **VS** | Validation Scenario | Exercises that prove a control works |
| **OQ** | Open Question | Not yet decided |

---

## 1. Purpose

Deliver a production-shaped AWS platform that runs a containerized workload on Amazon EKS behind an edge security stack, with a managed relational database, under a defined security baseline.

The platform — not the application — is the deliverable. The application exists solely to give the security controls a real subject: a real network path to segment, real credentials to protect, and a real identity to scope.

---

## 2. System Overview

```
Internet
  → Route 53          (DNS, apex + www)
  → CloudFront        (edge TLS termination, caching)
  → AWS WAF           (managed rule groups, rate limiting)
  → Application LB    (public subnets, TLS)
  → Amazon EKS        (private worker nodes)
  → RDS PostgreSQL    (Multi-AZ, private subnets, no public access)
```

**Region:** `us-east-1` (single region, single environment)
**Domain:** `eks-secure-lab.com`

---

## 3. Scope

### 3.1 In Scope

| Area | Included |
|---|---|
| Networking | VPC, public/private subnets across 2 AZs, IGW, NAT, route tables, security groups |
| Edge | Route 53 hosted zone, ACM certificates, CloudFront distribution, AWS WAF |
| Compute | EKS cluster, managed node group on private subnets, AWS Load Balancer Controller |
| Data | RDS PostgreSQL Multi-AZ, encrypted at rest via KMS, credentials in Secrets Manager |
| Identity | IAM roles, IRSA, Kubernetes RBAC |
| Workload security | Pod Security Standards, Network Policies, image scanning |
| Detection | CloudTrail, AWS Config, GuardDuty, Security Hub, CloudWatch |
| Delivery | Terraform for all infrastructure; container image build pipeline |
| Validation | Four control-validation scenarios (§7) |

### 3.2 Explicitly Out of Scope

Stated so scope creep can be rejected by reference rather than by argument.

- Multi-region, multi-account, or DR failover
- Service mesh (Istio, Linkerd, App Mesh)
- GitOps controllers (ArgoCD, Flux)
- Autoscaling beyond a fixed managed node group
- Observability stacks beyond CloudWatch (Prometheus, Grafana, ELK)
- CI/CD promotion across environments
- Non-trivial application features
- Compliance certification (SOC 2, PCI, HIPAA) — controls may *map* to frameworks, but no audit artifacts

---

## 4. Functional Requirements

| ID | Requirement |
|---|---|
| FR-1 | A containerized HTTP service runs on EKS with at least 2 replicas across 2 AZs. |
| FR-2 | The service exposes `GET /healthz` returning liveness without touching the database. |
| FR-3 | The service exposes `GET /readyz` returning readiness only when its database connection is usable. |
| FR-4 | The service exposes one endpoint that performs a real read against RDS PostgreSQL and returns the result. |
| FR-5 | The service is reachable over HTTPS at the registered domain; HTTP redirects to HTTPS. |
| FR-6 | Database credentials are retrieved at runtime from Secrets Manager. They are never present in source, image layers, environment variables, or Kubernetes Secrets. |
| FR-7 | The entire platform is created and destroyed by Terraform, repeatably, from a clean account state. |

---

## 5. Non-Functional Requirements

### 5.1 Availability

| ID | Requirement |
|---|---|
| NFR-1 | Workload spans two Availability Zones. |
| NFR-2 | RDS runs Multi-AZ with automated backups enabled. |
| NFR-3 | Loss of a single AZ does not make the service unavailable. |

### 5.2 Security

| ID | Requirement |
|---|---|
| NFR-4 | Worker nodes and RDS reside in private subnets with no public IP addresses. |
| NFR-5 | No security group permits `0.0.0.0/0` inbound except the ALB on 443 (and 80 for redirect). |
| NFR-6 | Security groups reference other security groups, not CIDR ranges, for intra-VPC traffic. |
| NFR-7 | All data is encrypted at rest (EBS, RDS, S3) using customer-managed KMS keys. |
| NFR-8 | All data is encrypted in transit at the edge and to the database. |
| NFR-9 | Pods obtain AWS permissions via IRSA. The node instance role carries no application permissions. |
| NFR-10 | Every IAM policy is scoped to specific actions and specific resource ARNs. No wildcards in either field without written justification in the design doc. |
| NFR-11 | Kubernetes RBAC follows least privilege. No workload uses `cluster-admin`. |
| NFR-12 | Default-deny Network Policies are enforced; traffic is permitted only by explicit allow. |
| NFR-13 | Pod Security Standards are enforced at `restricted` for application namespaces. |
| NFR-14 | Containers run as non-root with a read-only root filesystem and all Linux capabilities dropped. |
| NFR-15 | Container images are scanned before deployment. Whether failing images are blocked or reported is deferred to Architecture (see OQ-5). |
| NFR-16 | CloudTrail is enabled with log file validation, delivering to an encrypted S3 bucket with public access blocked. |
| NFR-17 | GuardDuty is enabled, including EKS Protection. |
| NFR-18 | AWS Config records resource state with rules covering the controls above. |
| NFR-19 | Security Hub aggregates findings from GuardDuty and Config as the single review surface. |
| NFR-20 | The EKS API server endpoint restricts public access to a known source range, or is private with documented access path. |
| NFR-21 | Kubernetes secrets are encrypted at rest with a KMS key (envelope encryption). |

### 5.3 Operability

| ID | Requirement |
|---|---|
| NFR-22 | Control plane and application logs ship to CloudWatch Logs with defined retention. |
| NFR-23 | An operator can rebuild the platform from an empty account using documented commands. |
| NFR-24 | Teardown removes all billable resources except the Route 53 hosted zone and registered domain. |

### 5.4 Cost

| ID | Requirement |
|---|---|
| NFR-25 | The environment runs only during active work and is destroyed afterward. |
| NFR-26 | Steady-state cost while running must be understood and documented per component before creation. |
| NFR-27 | Cumulative spend must not exceed $150. A billing alarm fires at $50 and $100. |

---

## 6. Constraints & Assumptions

- Single AWS account, single region, single environment.
- Domain is registered in Route 53; the hosted zone persists across teardowns by design so DNS and certificate validation are not rebuilt each session.
- Terraform state is remote and locked.
- The environment is non-production and short-lived. Multi-AZ RDS is used to exercise the pattern, not to meet an SLA.
- No production data. All data is synthetic.

---

## 7. Control Validation Scenarios

Each scenario demonstrates a control by first showing the failure mode it prevents. Each is documented as **attack → observed impact → detection → remediation → verification**, with evidence.

| # | Scenario | Control demonstrated |
|---|---|---|
| VS-1 | Deploy an image with known critical CVEs | Image scanning and admission policy |
| VS-2 | Pod assumes over-permissioned credentials via node role | IRSA and least-privilege IAM |
| VS-3 | Lateral movement between namespaces | Default-deny Network Policies |
| VS-4 | Anomalous API activity from compromised credentials | CloudTrail, GuardDuty, Security Hub investigation |

This list is closed. Additional scenarios are out of scope.

---

## 8. Acceptance Criteria

The platform is complete when all of the following are true:

1. `terraform apply` builds the full platform from a clean account with no manual steps beyond documented bootstrap.
2. The service is reachable over HTTPS at the domain and returns live data from RDS.
3. `terraform destroy` removes all billable resources; a follow-up `apply` reproduces a working platform.
4. Every requirement in §4 and §5 is satisfied, or has a documented, justified exception.
5. All four validation scenarios in §7 are executed and documented with evidence.
6. The repository contains: architecture diagram, threat model, design decision record, runbook, and validation writeups.
7. Total spend is within the §5.4 ceiling.

---

## 9. Open Questions

| # | Question | Status |
|---|---|---|
| OQ-1 | Managed node group vs. Fargate for worker capacity | Open — decide in Architecture |
| OQ-2 | NAT Gateway vs. NAT instance vs. VPC endpoints only, given cost | Open — decide in Architecture |
| OQ-3 | Single NAT Gateway vs. one per AZ (cost vs. AZ independence) | Open — decide in Architecture |
| OQ-4 | Image registry: ECR with enhanced scanning vs. basic scanning | Open — decide in Architecture |
| OQ-5 | Image scanning: report findings only, or block deployment of vulnerable images? If blocking, what mechanism enforces it? | Open — decide in Architecture |

---

## 10. Revision History

| Date | Change |
|---|---|
| 2026-07-26 | Initial draft |
