resource "aws_vpc" "this" {
  cidr_block           = var.network_cidr
  enable_dns_support   = var.dns_support
  enable_dns_hostnames = var.dns_hostnames

  tags = {
    Name = var.network_name
  }
}

# subnet for bastion it is public
resource "aws_subnet" "this" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.subnetwork_cidr
  availability_zone = var.availability_zone

  tags = {
    Name = var.subnetwork_name
  }
}

# private subnet — app and db VMs live here, no direct internet access
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnetwork_cidr
  availability_zone = var.availability_zone

  tags = {
    Name = "${var.network_name}-private"
  }
}


# gateway between vpc and public internet
resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.network_name}-igw"
  }
}

# public route table
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



# eip - elastic ip - a fixed public ip (ip changes after destroy/apply) and it makes it static 
# nat gives outbond internet access for (apt update / docker pull) or downloading package
resource "aws_eip" "nat" {
  domain = "vpc"
  tags = {
    Name = "${var.network_name}-nat-eip"
  }
}
# NAT Gateway AWS - allow private VMs to reach internet
# if vm does not have public ip it should have nat gateway to each internet
resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.this.id
  tags          = { 
    Name = "${var.network_name}-nat" 
  }
  depends_on    = [aws_internet_gateway.this]
}


# where to send traffic through NAT (to nat gateway)
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = {
    Name = "${var.network_name}-private-rt"
  }
}


 # connect the private subnet to the private route table
resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# second public subnet in different AZ for ALB
resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.second_public_subnet_cidr
  availability_zone       = var.second_availability_zone
  map_public_ip_on_launch = true

  tags = {
     Name = "${var.network_name}-public-2" 
  }
}

resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.this.id
}