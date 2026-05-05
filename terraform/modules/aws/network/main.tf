resource "aws_vpc" "this" {
  cidr_block           = var.network_cidr
  enable_dns_support   = var.dns_support
  enable_dns_hostnames = var.dns_hostnames

  tags = {
    Name = var.network_name
  }
}

resource "aws_subnet" "this" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.subnetwork_cidr
  availability_zone = var.availability_zone

  tags = {
    Name = var.subnetwork_name
  }
}

# gateway between vpc and public internet
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.network_name}-igw"
  }
}

# traffic going to any public IPv4 address (0.0.0.0/0) should go through the internet gateway
resource "aws_route_table" "this" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = {
    Name = "${var.network_name}-rt"
  }
}

# connect rule of route to a subnet
resource "aws_route_table_association" "this" {
  subnet_id      = aws_subnet.this.id
  route_table_id = aws_route_table.this.id
}
