variable "project" {
  description = "Name prefix applied to all resources and tags."
  type        = string
  default     = "secure-eks"
}

variable "region" {
  description = "AWS region. Single region by design — see requirements.md §6."
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "VPC address space. See architecture.md §1.4 for the subnet carve-up."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of Availability Zones to span. Two satisfies NFR-1."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2
    error_message = "NFR-1 requires the workload to span at least two Availability Zones."
  }
}
