resource "aws_security_group" "bastion" {
  name   = "${var.network_name}-bastion-sg"
  vpc_id = var.network_id

  ingress {
    description = "SSH from operator IP"
    from_port   = var.ports
    to_port     = var.ports
    protocol    = var.protocol
    cidr_blocks = [var.cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.network_name}-bastion-sg"
  }
}

resource "aws_security_group" "db" {
  name   = "${var.network_name}-db-sg"
  vpc_id = var.network_id

  ingress {
    description     = "SSH from bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  ingress {
    description     = "PostgreSQL from app VMs"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.private.id]
  }

  ingress {
    description     = "RabbitMQ from app VMs"
    from_port       = 5672
    to_port         = 5672
    protocol        = "tcp"
    security_groups = [aws_security_group.private.id]
  }

  ingress {
    description     = "Redis from app VMs"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.private.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.network_name}-db-sg" }
}

resource "aws_security_group" "private" {
  name   = "${var.network_name}-private-sg"
  vpc_id = var.network_id

  ingress {
    description = "SSH from bastion security group"
    from_port   = var.ports
    to_port     = var.ports
    protocol    = var.protocol
    # allow access from bastion
    security_groups = [aws_security_group.bastion.id]
  }

  ingress {
    description = "Private VM to private VM SSH"
    from_port   = var.ports
    to_port     = var.ports
    protocol    = var.protocol
    # allow connection between each other
    self = true
  }

  # app vm only accept http from alb , not directly from internet
  ingress {
    description =  "HTTP to app vm only through ALB"
    from_port = 80
    to_port = 80
    protocol = "tcp"
    security_groups = [aws_security_group.lb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.network_name}-private-sg"
  }
}

resource "aws_security_group" "lb" {
  name = "${var.network_name}-lb-sg"
  vpc_id = var.network_id

  ingress {
    from_port = 80
    to_port = 80
    protocol = var.protocol
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # allow traffic out from all ports and all protocols
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.network_name}-lb-sg"
  }
}

