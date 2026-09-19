variable "environment" { type = string }
variable "dr_tier" { type = string }
variable "primary_subnet_ids" { type = list(string) }
variable "secondary_subnet_ids" { type = list(string) }
variable "primary_security_group_id" { type = string }
variable "secondary_security_group_id" { type = string }
variable "kms_primary_key_arn" { type = string }
variable "kms_secondary_key_arn" { type = string }
