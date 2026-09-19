variable "environment" { type = string }
variable "dr_tier" { type = string }
variable "primary_vpc_cidr" { type = string }
variable "secondary_vpc_cidr" { type = string }
variable "primary_azs" { type = list(string) }
variable "secondary_azs" { type = list(string) }
