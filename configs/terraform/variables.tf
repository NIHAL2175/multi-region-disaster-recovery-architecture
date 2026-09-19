# Root Variables Definition for PaySecure DR Architecture

variable "primary_region" {
  type        = string
  default     = "ap-south-1"
  description = "AWS Primary production region (Mumbai)"
}

variable "secondary_region" {
  type        = string
  default     = "ap-south-2"
  description = "AWS Secondary disaster recovery region (Hyderabad)"
}

variable "environment" {
  type        = string
  default     = "production"
  description = "Deployment environment name"
}

variable "dr_tier" {
  type        = string
  default     = "Hot-Standby"
  description = "Disaster recovery posture (Cold-Standby, Warm-Standby, Hot-Standby, Active-Active)"
}

variable "domain_name" {
  type        = string
  default     = "paysecure.in"
  description = "Base apex domain name for payment gateway"
}

variable "primary_vpc_cidr" {
  type        = string
  default     = "10.100.0.0/16"
  description = "CIDR block for Mumbai production VPC"
}

variable "secondary_vpc_cidr" {
  type        = string
  default     = "10.200.0.0/16"
  description = "CIDR block for Hyderabad DR VPC"
}

variable "primary_azs" {
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
  description = "Availability Zones in primary region"
}

variable "secondary_azs" {
  type        = list(string)
  default     = ["ap-south-2a", "ap-south-2b", "ap-south-2c"]
  description = "Availability Zones in secondary region"
}

variable "db_master_username" {
  type        = string
  default     = "paysecure_admin"
  description = "Master username for Aurora PostgreSQL"
}

variable "db_master_password" {
  type        = string
  sensitive   = true
  description = "Master password for Aurora PostgreSQL (retrieved from Secrets Manager)"
}
