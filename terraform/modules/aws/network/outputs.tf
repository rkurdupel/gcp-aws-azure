output "subnet_id" {
  value = aws_subnet.this.id
}

output "network_id" {
  value = aws_vpc.this.id
}
