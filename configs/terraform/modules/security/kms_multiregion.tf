terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.primary, aws.secondary]
    }
  }
}

resource "aws_kms_key" "primary" {
  provider                = aws.primary
  description             = "PaySecure Multi-Region Master Key (PCI DSS CDE)"
  deletion_window_in_days = 30
  multi_region            = true
  enable_key_rotation     = true
  tags                    = { Name = "mrk-cde-mumbai-master", Role = "Primary-Key" }
}

resource "aws_kms_replica_key" "secondary" {
  provider                = aws.secondary
  description             = "PaySecure Multi-Region Replica Key (Hyderabad CDE)"
  deletion_window_in_days = 30
  primary_key_arn         = aws_kms_key.primary.arn
  tags                    = { Name = "mrk-cde-hyd-replica", Role = "Replica-Key" }
}
