# aws return endpoint as hotstname:5432 we split to take the hostname (example: mydb.123456789012.us-east-1.rds.amazonaws.com)
output "rds_endpoint" {
    value = split(":", aws_db_instance.this.endpoint)[0]
}