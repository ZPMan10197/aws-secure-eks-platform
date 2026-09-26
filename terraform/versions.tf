# Pin the Terraform CLI and provider versions.
#
# Providers are pinned with a pessimistic constraint (~> 5.0), which permits
# 5.x patch and minor upgrades but blocks 6.0. Major provider releases carry
# breaking resource schema changes; an unpinned provider means a rebuild months
# from now can fail or silently produce different infrastructure.

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # TODO: remote S3 backend with state locking.
  # State is local for now — see architecture.md §1.6.
  # Local state is acceptable for a single operator; it is not acceptable
  # once state is shared, and it is lost if this machine is lost.
}
