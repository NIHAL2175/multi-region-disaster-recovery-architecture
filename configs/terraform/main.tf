# Terraform Root Configuration - PaySecure Multi-Region DR Architecture
# Terraform Version: 1.5+
# Regions: Primary ap-south-1 (Mumbai), Secondary ap-south-2 (Hyderabad)

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "paysecure-tf-state-mumbai-master"
    key            = "multi-region-dr/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "paysecure-terraform-locks"
    encrypt        = true
  }
}

provider "aws" {
  alias  = "primary"
  region = var.primary_region

  default_tags {
    tags = {
      Project     = "PaySecure"
      Environment = var.environment
      CostCenter  = "FINTECH-CORE-DR"
      DR-Tier     = var.dr_tier
      ManagedBy   = "Terraform"
    }
  }
}

provider "aws" {
  alias  = "secondary"
  region = var.secondary_region

  default_tags {
    tags = {
      Project     = "PaySecure"
      Environment = var.environment
      CostCenter  = "FINTECH-CORE-DR"
      DR-Tier     = var.dr_tier
      ManagedBy   = "Terraform"
    }
  }
}

# Module 1: Networking (VPCs and Transit Gateway)
module "networking" {
  source = "./modules/networking"

  providers = {
    aws.primary   = aws.primary
    aws.secondary = aws.secondary
  }

  environment          = var.environment
  dr_tier              = var.dr_tier
  primary_vpc_cidr     = var.primary_vpc_cidr
  secondary_vpc_cidr   = var.secondary_vpc_cidr
  primary_azs          = var.primary_azs
  secondary_azs        = var.secondary_azs
}

# Module 2: Security (Multi-Region KMS, WAFv2, Shield)
module "security" {
  source = "./modules/security"

  providers = {
    aws.primary   = aws.primary
    aws.secondary = aws.secondary
  }

  environment = var.environment
  dr_tier     = var.dr_tier
}

# Module 3: Database (Aurora PostgreSQL Global Database)
module "database" {
  source = "./modules/database"

  providers = {
    aws.primary   = aws.primary
    aws.secondary = aws.secondary
  }

  environment               = var.environment
  dr_tier                   = var.dr_tier
  db_master_username        = var.db_master_username
  db_master_password        = var.db_master_password
  primary_db_subnet_ids     = module.networking.primary_data_subnet_ids
  secondary_db_subnet_ids   = module.networking.secondary_data_subnet_ids
  primary_security_group_id = module.networking.primary_db_security_group_id
  secondary_security_group_id = module.networking.secondary_db_security_group_id
  kms_primary_key_arn       = module.security.kms_primary_key_arn
  kms_secondary_key_arn     = module.security.kms_secondary_key_arn
}

# Module 4: DynamoDB Global Tables
module "dynamodb" {
  source = "./modules/dynamodb"

  providers = {
    aws.primary   = aws.primary
    aws.secondary = aws.secondary
  }

  environment = var.environment
  dr_tier     = var.dr_tier
}

# Module 5: ElastiCache Redis Global Datastore
module "cache" {
  source = "./modules/cache"

  providers = {
    aws.primary   = aws.primary
    aws.secondary = aws.secondary
  }

  environment                 = var.environment
  dr_tier                     = var.dr_tier
  primary_cache_subnet_ids    = module.networking.primary_data_subnet_ids
  secondary_cache_subnet_ids  = module.networking.secondary_data_subnet_ids
  primary_security_group_id   = module.networking.primary_cache_security_group_id
  secondary_security_group_id = module.networking.secondary_cache_security_group_id
}

# Module 6: Messaging (Amazon MSK with Replicator)
module "messaging" {
  source = "./modules/messaging"

  providers = {
    aws.primary   = aws.primary
    aws.secondary = aws.secondary
  }

  environment               = var.environment
  dr_tier                   = var.dr_tier
  primary_subnet_ids        = module.networking.primary_data_subnet_ids
  secondary_subnet_ids      = module.networking.secondary_data_subnet_ids
  primary_security_group_id = module.networking.primary_msk_security_group_id
  secondary_security_group_id = module.networking.secondary_msk_security_group_id
  kms_primary_key_arn       = module.security.kms_primary_key_arn
  kms_secondary_key_arn     = module.security.kms_secondary_key_arn
}

# Module 7: Compute (EKS Clusters in Mumbai and Hyderabad)
module "compute" {
  source = "./modules/compute"

  providers = {
    aws.primary   = aws.primary
    aws.secondary = aws.secondary
  }

  environment           = var.environment
  dr_tier               = var.dr_tier
  primary_subnet_ids    = module.networking.primary_app_subnet_ids
  secondary_subnet_ids  = module.networking.secondary_app_subnet_ids
  primary_vpc_id        = module.networking.primary_vpc_id
  secondary_vpc_id      = module.networking.secondary_vpc_id
  kms_primary_key_arn   = module.security.kms_primary_key_arn
  kms_secondary_key_arn = module.security.kms_secondary_key_arn
}

# Module 8: DNS Failover (Route 53 and Health Checks)
module "dns" {
  source = "./modules/dns"

  providers = {
    aws.primary = aws.primary
  }

  environment           = var.environment
  dr_tier               = var.dr_tier
  domain_name           = var.domain_name
  primary_alb_dns_name  = module.networking.primary_alb_dns_name
  primary_alb_zone_id   = module.networking.primary_alb_zone_id
  secondary_alb_dns_name= module.networking.secondary_alb_dns_name
  secondary_alb_zone_id = module.networking.secondary_alb_zone_id
}

# Module 9: Monitoring & Synthetics
module "monitoring" {
  source = "./modules/monitoring"

  providers = {
    aws.primary   = aws.primary
    aws.secondary = aws.secondary
  }

  environment               = var.environment
  dr_tier                   = var.dr_tier
  primary_alb_arn_suffix    = module.networking.primary_alb_arn_suffix
  secondary_alb_arn_suffix  = module.networking.secondary_alb_arn_suffix
  aurora_primary_cluster_id = module.database.primary_cluster_id
  aurora_secondary_cluster_id = module.database.secondary_cluster_id
}
