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
