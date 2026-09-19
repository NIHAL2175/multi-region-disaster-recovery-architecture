terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.primary, aws.secondary]
    }
  }
}

resource "aws_dynamodb_table" "idempotency" {
  provider         = aws.primary
  name             = "paysecure-idempotency-sessions"
  billing_mode     = "PROVISIONED"
  read_capacity    = 10000
  write_capacity   = 5000
  hash_key         = "PK"
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  attribute {
    name = "PK"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  replica {
    region_name = "ap-south-2"
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = { Environment = var.environment, CostCenter = "FINTECH-CORE-DR" }
}
