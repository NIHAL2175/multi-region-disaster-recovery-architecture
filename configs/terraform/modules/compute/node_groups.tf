resource "aws_iam_role" "node_group" {
  provider = aws.primary
  name     = "paysecure-eks-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{ Action = "sts:AssumeRole", Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_eks_node_group" "primary_nodes" {
  provider        = aws.primary
  cluster_name    = aws_eks_cluster.primary.name
  node_group_name = "ng-mumbai-app-tier"
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = var.primary_subnet_ids
  instance_types  = ["m6i.2xlarge"]

  scaling_config {
    desired_size = 24
    max_size     = 48
    min_size     = 18
  }
}

resource "aws_eks_node_group" "secondary_nodes" {
  provider        = aws.secondary
  cluster_name    = aws_eks_cluster.secondary.name
  node_group_name = "ng-hyd-standby-tier"
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = var.secondary_subnet_ids
  instance_types  = ["m6i.2xlarge"]

  scaling_config {
    desired_size = 12
    max_size     = 48
    min_size     = 8
  }
}
