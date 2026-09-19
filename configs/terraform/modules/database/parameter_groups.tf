resource "aws_rds_cluster_parameter_group" "pg" {
  provider    = aws.primary
  name        = "paysecure-aurora-pg15"
  family      = "aurora-postgresql15"
  description = "PaySecure production Aurora PG15 parameters"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
}
