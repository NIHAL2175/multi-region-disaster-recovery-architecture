resource "aws_route53_health_check" "primary" {
  fqdn              = "api-mum.${var.domain_name}"
  port              = 443
  type              = "HTTPS"
  resource_path     = "/health/deep"
  failure_threshold = 3
  request_interval  = 10
  measure_latency   = true

  tags = { Name = "paysecure-primary-deep-health", Environment = var.environment, DR-Tier = var.dr_tier }
}

resource "aws_route53_health_check" "secondary" {
  fqdn              = "api-hyd.${var.domain_name}"
  port              = 443
  type              = "HTTPS"
  resource_path     = "/health/deep"
  failure_threshold = 3
  request_interval  = 10
  measure_latency   = true

  tags = { Name = "paysecure-secondary-deep-health", Environment = var.environment, DR-Tier = var.dr_tier }
}
