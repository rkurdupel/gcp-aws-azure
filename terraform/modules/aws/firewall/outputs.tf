output "bastion_security_group_id" {
  value = aws_security_group.bastion.id
}

output "private_security_group_id" {
  value = aws_security_group.private.id
}

output "lb_security_group_id" {
  value = aws_security_group.lb.id
}

output "db_security_group_id" {
  value = aws_security_group.db.id
}