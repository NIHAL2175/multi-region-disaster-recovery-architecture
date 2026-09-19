output "kms_primary_key_arn" { value = aws_kms_key.primary.arn }
output "kms_secondary_key_arn" { value = aws_kms_replica_key.secondary.arn }
