# Subnet layout per architecture.md §1.4.
#
# Public  /24  — holds only ALB interfaces and NAT Gateways.
# Private /20  — holds EKS worker nodes. The VPC CNI assigns every pod a real
#                VPC address, so address consumption scales with instance type
#                rather than pod count. A /24 here would cap the cluster near
#                eight nodes.
#
# map_public_ip_on_launch is false on all four. Nothing in the public subnets
# is an EC2 instance — the ALB draws addresses from the ELB service and the NAT
# Gateway uses an allocated Elastic IP — so auto-assignment serves no purpose
# and would hand a public address to anything launched there by mistake.

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.0.0/24"
  availability_zone       = local.azs[0]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project}-public-a"
    Tier = "public"
  }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = local.azs[1]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project}-public-b"
    Tier = "public"
  }
}

resource "aws_subnet" "private_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.16.0/20"
  availability_zone       = local.azs[0]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project}-private-a"
    Tier = "private"
  }
}

resource "aws_subnet" "private_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.32.0/20"
  availability_zone       = local.azs[1]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.project}-private-b"
    Tier = "private"
  }
}
