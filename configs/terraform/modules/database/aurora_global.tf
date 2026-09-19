terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.primary, aws.secondary]
    }
  }
}

# Standalone Global Cluster Declaration (Resolves Brief Error 4 Circular Dependency)
resource "aws_rds_global_cluster" "paysecure" {
  provider                  = aws.primary
  global_cluster_identifier = "paysecure-global"
  engine                    = "aurora-postgresql"
  engine_version            = "15.4"
  storage_encrypted         = true
  deletion_protection       = true
}

resource "aws_db_subnet_group" "primary" {
  provider   = aws.primary
  name       = "paysecure-mumbai-db-subnets"
  subnet_ids = var.primary_db_subnet_ids
}

resource "aws_db_subnet_group" "secondary" {
  provider   = aws.secondary
  name       = "paysecure-hyd-db-subnets"
  subnet_ids = var.secondary_db_subnet_ids
}

# Primary Cluster in Mumbai attaches to Global Cluster
resource "aws_rds_cluster" "primary" {
  provider                  = aws.primary
  cluster_identifier        = "paysecure-primary"
  engine                    = aws_rds_global_cluster.paysecure.engine
  engine_version            = aws_rds_global_cluster.paysecure.engine_version
  global_cluster_identifier = aws_rds_global_cluster.paysecure.id
  master_username           = var.db_master_username
  master_password           = var.db_master_password
  db_subnet_group_name      = aws_db_subnet_group.primary.name
  vpc_security_group_ids    = [var.primary_security_group_id]
  kms_key_id                = var.kms_primary_key_arn
  storage_encrypted         = true
  backup_retention_period   = 30
  preferred_backup_window   = "19:00-20:00"

  tags = { Environment = var.environment, Region = "ap-south-1", DR-Role = "primary-writer" }
}

resource "aws_rds_cluster_instance" "primary_writer" {
  provider             = aws.primary
  cluster_identifier   = aws_rds_cluster.primary.id
  instance_class       = "db.r6g.2xlarge"
  engine               = aws_rds_cluster.primary.engine
  engine_version       = aws_rds_cluster.primary.engine_version
  db_subnet_group_name = aws_db_subnet_group.primary.name
}

# Secondary Cluster in Hyderabad
resource "aws_rds_cluster" "secondary" {
  provider                  = aws.secondary
  cluster_identifier        = "paysecure-secondary"
  engine                    = aws_rds_global_cluster.paysecure.engine
  engine_version            = aws_rds_global_cluster.paysecure.engine_version
  global_cluster_identifier = aws_rds_global_cluster.paysecure.id
  db_subnet_group_name      = aws_db_subnet_group.secondary.name
  vpc_security_group_ids    = [var.secondary_security_group_id]
  kms_key_id                = var.kms_secondary_key_arn
  storage_encrypted         = true

  depends_on = [aws_rds_cluster_instance.primary_writer]
  tags       = { Environment = var.environment, Region = "ap-south-2", DR-Role = "standby-reader" }
}

resource "aws_rds_cluster_instance" "secondary_reader" {
  provider             = aws.secondary
  cluster_identifier   = aws_rds_cluster.secondary.id
  instance_class       = "db.r6g.2xlarge"
  engine               = aws_rds_cluster.secondary.engine
  engine_version       = aws_rds_cluster.secondary.engine_version
  db_subnet_group_name = aws_db_subnet_group.secondary.name
}
