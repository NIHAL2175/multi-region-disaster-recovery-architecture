terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.primary, aws.secondary]
    }
  }
}

# Mumbai Primary VPC
resource "aws_vpc" "primary" {
  provider             = aws.primary
  cidr_block           = var.primary_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "paysecure-mumbai-prod-vpc" }
}

resource "aws_subnet" "primary_public" {
  provider          = aws.primary
  count             = 3
  vpc_id            = aws_vpc.primary.id
  cidr_block        = cidrsubnet(var.primary_vpc_cidr, 8, count.index + 1)
  availability_zone = var.primary_azs[count.index]
  tags              = { Name = "paysecure-mumbai-public-${count.index + 1}" }
}

resource "aws_subnet" "primary_app" {
  provider          = aws.primary
  count             = 3
  vpc_id            = aws_vpc.primary.id
  cidr_block        = cidrsubnet(var.primary_vpc_cidr, 6, count.index + 4)
  availability_zone = var.primary_azs[count.index]
  tags              = { Name = "paysecure-mumbai-app-${count.index + 1}" }
}

resource "aws_subnet" "primary_data" {
  provider          = aws.primary
  count             = 3
  vpc_id            = aws_vpc.primary.id
  cidr_block        = cidrsubnet(var.primary_vpc_cidr, 8, count.index + 30)
  availability_zone = var.primary_azs[count.index]
  tags              = { Name = "paysecure-mumbai-data-${count.index + 1}" }
}

# Hyderabad Secondary VPC
resource "aws_vpc" "secondary" {
  provider             = aws.secondary
  cidr_block           = var.secondary_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "paysecure-hyd-dr-vpc" }
}

resource "aws_subnet" "secondary_public" {
  provider          = aws.secondary
  count             = 3
  vpc_id            = aws_vpc.secondary.id
  cidr_block        = cidrsubnet(var.secondary_vpc_cidr, 8, count.index + 1)
  availability_zone = var.secondary_azs[count.index]
  tags              = { Name = "paysecure-hyd-public-${count.index + 1}" }
}

resource "aws_subnet" "secondary_app" {
  provider          = aws.secondary
  count             = 3
  vpc_id            = aws_vpc.secondary.id
  cidr_block        = cidrsubnet(var.secondary_vpc_cidr, 6, count.index + 4)
  availability_zone = var.secondary_azs[count.index]
  tags              = { Name = "paysecure-hyd-app-${count.index + 1}" }
}

resource "aws_subnet" "secondary_data" {
  provider          = aws.secondary
  count             = 3
  vpc_id            = aws_vpc.secondary.id
  cidr_block        = cidrsubnet(var.secondary_vpc_cidr, 8, count.index + 30)
  availability_zone = var.secondary_azs[count.index]
  tags              = { Name = "paysecure-hyd-data-${count.index + 1}" }
}

# Security Groups
resource "aws_security_group" "primary_db" {
  provider    = aws.primary
  name        = "paysecure-mumbai-db-sg"
  vpc_id      = aws_vpc.primary.id
  description = "Access to Aurora PostgreSQL in Mumbai"

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.primary_vpc_cidr, var.secondary_vpc_cidr]
  }
}

resource "aws_security_group" "secondary_db" {
  provider    = aws.secondary
  name        = "paysecure-hyd-db-sg"
  vpc_id      = aws_vpc.secondary.id
  description = "Access to Aurora PostgreSQL in Hyderabad"

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.primary_vpc_cidr, var.secondary_vpc_cidr]
  }
}

resource "aws_security_group" "primary_cache" {
  provider = aws.primary
  name     = "paysecure-mumbai-cache-sg"
  vpc_id   = aws_vpc.primary.id
  ingress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [var.primary_vpc_cidr]
  }
}

resource "aws_security_group" "secondary_cache" {
  provider = aws.secondary
  name     = "paysecure-hyd-cache-sg"
  vpc_id   = aws_vpc.secondary.id
  ingress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = [var.secondary_vpc_cidr]
  }
}

resource "aws_security_group" "primary_msk" {
  provider = aws.primary
  name     = "paysecure-mumbai-msk-sg"
  vpc_id   = aws_vpc.primary.id
  ingress {
    from_port   = 9092
    to_port     = 9094
    protocol    = "tcp"
    cidr_blocks = [var.primary_vpc_cidr, var.secondary_vpc_cidr]
  }
}

resource "aws_security_group" "secondary_msk" {
  provider = aws.secondary
  name     = "paysecure-hyd-msk-sg"
  vpc_id   = aws_vpc.secondary.id
  ingress {
    from_port   = 9092
    to_port     = 9094
    protocol    = "tcp"
    cidr_blocks = [var.primary_vpc_cidr, var.secondary_vpc_cidr]
  }
}

# ALBs
resource "aws_lb" "primary_alb" {
  provider           = aws.primary
  name               = "paysecure-mumbai-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = aws_subnet.primary_public[*].id
}

resource "aws_lb" "secondary_alb" {
  provider           = aws.secondary
  name               = "paysecure-hyd-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = aws_subnet.secondary_public[*].id
}
