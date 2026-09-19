terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.primary, aws.secondary]
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "replication_lag" {
  provider            = aws.secondary
  alarm_name          = "paysecure-aurora-cross-region-replication-lag-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "AuroraGlobalDBReplicationLag"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 1000
  alarm_description   = "P1 Alert: Cross-region storage replication lag exceeds 1000ms"
  dimensions          = { DBClusterIdentifier = var.aurora_secondary_cluster_id }
}
