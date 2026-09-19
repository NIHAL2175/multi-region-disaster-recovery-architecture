variable "environment" { type = string }
variable "dr_tier" { type = string }
variable "primary_cache_subnet_ids" { type = list(string) }
variable "secondary_cache_subnet_ids" { type = list(string) }
variable "primary_security_group_id" { type = string }
variable "secondary_security_group_id" { type = string }
