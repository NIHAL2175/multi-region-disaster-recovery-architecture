output "global_cluster_id" { value = aws_rds_global_cluster.paysecure.id }
output "primary_cluster_id" { value = aws_rds_cluster.primary.id }
output "secondary_cluster_id" { value = aws_rds_cluster.secondary.id }
output "primary_writer_endpoint" { value = aws_rds_cluster.primary.endpoint }
output "secondary_reader_endpoint" { value = aws_rds_cluster.secondary.reader_endpoint }
