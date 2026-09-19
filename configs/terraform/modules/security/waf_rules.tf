resource "aws_wafv2_web_acl" "primary_waf" {
  provider    = aws.primary
  name        = "paysecure-mumbai-waf"
  description = "WAF protection for Mumbai Ingress"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "paysecureWafMumbai"
    sampled_requests_enabled   = true
  }
}
