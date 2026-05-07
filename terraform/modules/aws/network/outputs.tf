output "subnet_id" {
  value = aws_subnet.this.id
}

output "network_id" {
  value = aws_vpc.this.id
}


output "private_subnet_id" {
  value = aws_subnet.private.id
}

output "public_subnet_ids" {
  value = [aws_subnet.this.id, aws_subnet.public_2.id]
}