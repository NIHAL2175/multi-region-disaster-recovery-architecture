terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.primary, aws.secondary]
    }
  }
}

resource "aws_elasticache_subnet_group" "primary" {
  provider   = aws.primary
  name       = "paysecure-mumbai-cache-subnets"
  subnet_ids = var.primary_cache_subnet_ids
}

resource "aws_elasticache_subnet_group" "secondary" {
  provider   = aws.secondary
  name       = "paysecure-hyd-cache-subnets"
  subnet_ids = var.secondary_cache_subnet_ids
}

resource "aws_elasticache_replication_group" "primary" {
  provider                   = aws.primary
  replication_group_id       = "paysecure-redis-primary"
  description                = "PaySecure Primary Redis Cluster (Mumbai)"
  engine                     = "redis"
  node_type                  = "cache.r6g.xlarge"
  num_cache_clusters         = 2
  subnet_group_name          = aws_elasticache_subnet_group.primary.name
  security_group_ids         = [var.primary_security_group_id]
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
}

resource "aws_elasticache_global_replication_group" "redis" {
  provider                           = aws.primary
  global_replication_group_id_suffix = "global"
  primary_replication_group_id       = aws_elasticache_replication_group.primary.id
}
