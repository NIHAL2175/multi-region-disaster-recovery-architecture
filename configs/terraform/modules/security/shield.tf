resource "aws_shield_protection" "primary_alb" {
  provider     = aws.primary
  name         = "paysecure-mumbai-alb-shield"
  resource_arn = "arn:aws:elasticloadbalancing:ap-south-1:123456789012:loadbalancer/app/paysecure-mumbai-alb/123456"
}
