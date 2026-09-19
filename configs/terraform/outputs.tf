# Root Outputs Definition for PaySecure DR Architecture

output "primary_vpc_id" {
  value       = module.networking.primary_vpc_id
  description = "VPC ID of Mumbai production environment"
}

output "secondary_vpc_id" {
  value       = module.networking.secondary_vpc_id
  description = "VPC ID of Hyderabad standby environment"
}

output "aurora_global_cluster_id" {
  value       = module.database.global_cluster_id
  description = "Aurora PostgreSQL Global Cluster Identifier"
}

output "aurora_primary_writer_endpoint" {
  value       = module.database.primary_writer_endpoint
  description = "Current read-write writer endpoint for transaction commits"
}

output "aurora_secondary_reader_endpoint" {
  value       = module.database.secondary_reader_endpoint
  description = "Promotable reader endpoint in Hyderabad"
}

output "dns_failover_api_endpoint" {
  value       = "https://api.${var.domain_name}"
  description = "Public health-checked Anycast ingress URL for payment transactions"
}
