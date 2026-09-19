terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.primary, aws.secondary]
    }
  }
}

resource "aws_msk_cluster" "primary" {
  provider               = aws.primary
  cluster_name           = "paysecure-msk-mumbai"
  kafka_version          = "3.5.1"
  number_of_broker_nodes = 6

  broker_node_group_info {
    instance_type   = "kafka.m5.2xlarge"
    client_subnets  = var.primary_subnet_ids
    security_groups = [var.primary_security_group_id]
  }

  encryption_info {
    encryption_at_rest_kms_key_arn = var.kms_primary_key_arn
  }
}

resource "aws_msk_cluster" "secondary" {
  provider               = aws.secondary
  cluster_name           = "paysecure-msk-hyd"
  kafka_version          = "3.5.1"
  number_of_broker_nodes = 6

  broker_node_group_info {
    instance_type   = "kafka.m5.2xlarge"
    client_subnets  = var.secondary_subnet_ids
    security_groups = [var.secondary_security_group_id]
  }

  encryption_info {
    encryption_at_rest_kms_key_arn = var.kms_secondary_key_arn
  }
}
