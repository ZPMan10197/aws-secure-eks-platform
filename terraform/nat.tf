resource "aws_eip" "nat_a" {
  domain = "vpc"
  tags = {
    Name = "${var.project}-nat-a-eip"
  }
}

resource "aws_eip" "nat_b" {
  domain = "vpc"
  tags = {
    Name = "${var.project}-nat-b-eip"
  }
}


resource "aws_nat_gateway" "a" {
  allocation_id = aws_eip.nat_a.id
  subnet_id     = aws_subnet.public_a.id
  tags = {
    Name = "${var.project}-nat-a"
  }
  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "b" {
  allocation_id = aws_eip.nat_b.id
  subnet_id     = aws_subnet.public_b.id
  tags = {
    Name = "${var.project}-nat-b"
  }
  depends_on = [aws_internet_gateway.main]
}