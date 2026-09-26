# Availability Zones are resolved at plan time rather than hardcoded.
# AZ names map to different physical zones in different accounts, and not
# every zone supports every service. See architecture.md §1.5.

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}
