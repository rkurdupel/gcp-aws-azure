# rds subnet group - tell rds which subnet to use
resource "aws_db_subnet_group" "this" {
    name = "${var.network_name}-rds-subnet-group"
    subnet_ids = var.private_subnet_ids
    tags = {
        Name = "${var.network_name}-rds-subnet-group"
    }
}

# firewall rules , allow only traffic from app group security group is allowed on port 5432
resource "aws_security_group" "rds" {
    name = "${var.network_name}-rds-sg"
    vpc_id = var.vpc_id

    ingress {
        description = "PostgresSQL from app group VMs only"
        from_port = 5432
        to_port = 5432
        protocol = "tcp"
        security_groups = [var.app_security_group_id]
    }

    egress {
        from_port = 0
        to_port = 0
        protocol = "-1"
        cidr_blocks = ["0.0.0.0/0"]
    }

    tags = {
        Name = "${var.network_name}-rds-sg"
    }
}

# disable ssl requirements 
# ssl - encrypt connections to rds
resource "aws_db_parameter_group" "this" {
    name = "${var.network_name}-pg15"
    family = "postgres15"

    parameter {
        name = "rds.force_ssl"
        value = "0"
    }
}

# create rds instance
resource "aws_db_instance" "this" {
    identifier = "${var.network_name}-postgres"
    engine = "postgres"
    engine_version = "15"
    instance_class = "db.t3.micro"
    allocated_storage = 20
    storage_encrypted = true

    db_name = var.db_name
    username = var.db_user
    password = var.db_password

    db_subnet_group_name = aws_db_subnet_group.this.name
    vpc_security_group_ids = [aws_security_group.rds.id]
    parameter_group_name = aws_db_parameter_group.this.name

    publicly_accessible = false # block any public internet access to rds instance
    skip_final_snapshot = true  # when terraform destroy - do not create a backup snapshot  of the database
    backup_retention_period = 0 # disable automatic daily backups (= 7 means AWS creates a backup every day and keeps the last 7 days of those backups.)

    # tags in console or cost tracking
    tags = {
        Name = "${var.network_name}-rds"
    }
}