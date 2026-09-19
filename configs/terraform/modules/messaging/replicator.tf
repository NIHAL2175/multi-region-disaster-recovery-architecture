resource "aws_msk_replicator" "paysecure_replicator" {
  provider        = aws.primary
  replicator_name = "paysecure-replicator"
  service_execution_role_arn = "arn:aws:iam::123456789012:role/paysecure-msk-replicator-role"

  kafka_cluster {
    amazon_msk_cluster {
      msk_cluster_arn = aws_msk_cluster.primary.arn
    }
    vpc_config {
      subnet_ids          = var.primary_subnet_ids
      security_groups_ids = [var.primary_security_group_id]
    }
  }

  kafka_cluster {
    amazon_msk_cluster {
      msk_cluster_arn = aws_msk_cluster.secondary.arn
    }
    vpc_config {
      subnet_ids          = var.secondary_subnet_ids
      security_groups_ids = [var.secondary_security_group_id]
    }
  }

  replication_info_list {
    source_kafka_cluster_arn = aws_msk_cluster.primary.arn
    target_kafka_cluster_arn = aws_msk_cluster.secondary.arn
    target_compression_type  = "NONE"
    
    topic_replication {
      topic_name_configuration {
        type = "PREFIXED_WITH_SOURCE_CLUSTER_ALIAS"
      }
      topics_to_replicate = ["payment-events", "settlement-triggers", "audit-log-events"]
    }
  }
}
