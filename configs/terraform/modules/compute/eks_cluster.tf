terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.primary, aws.secondary]
    }
  }
}

resource "aws_iam_role" "eks_primary" {
  provider = aws.primary
  name     = "paysecure-mumbai-eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "eks.amazonaws.com" } }]
  })
}

resource "aws_eks_cluster" "primary" {
  provider = aws.primary
  name     = "paysecure-mumbai-prod"
  version  = "1.28"
  role_arn = aws_iam_role.eks_primary.arn

  vpc_config {
    subnet_ids              = var.primary_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = false
  }

  encryption_config {
    provider { key_arn = var.kms_primary_key_arn }
    resources = ["secrets"]
  }
}

resource "aws_iam_role" "eks_secondary" {
  provider = aws.secondary
  name     = "paysecure-hyd-eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "eks.amazonaws.com" } }]
  })
}

resource "aws_eks_cluster" "secondary" {
  provider = aws.secondary
  name     = "paysecure-hyd-standby"
  version  = "1.28"
  role_arn = aws_iam_role.eks_secondary.arn

  vpc_config {
    subnet_ids              = var.secondary_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = false
  }

  encryption_config {
    provider { key_arn = var.kms_secondary_key_arn }
    resources = ["secrets"]
  }
}
