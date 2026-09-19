# Synthetics Canary for Deep Health Probing
resource "aws_synthetics_canary" "api_deep_probe" {
  provider             = aws.primary
  name                 = "paysecure-deep-probe"
  artifact_s3_location = "s3://paysecure-compliance-mumbai/canaries/"
  execution_role_arn   = "arn:aws:iam::123456789012:role/paysecure-canary-role"
  handler              = "apiCanary.handler"
  zip_file             = "configs/monitoring/canary-dummy.zip"
  runtime_version      = "syn-nodejs-puppeteer-6.2"

  schedule {
    expression = "rate(1 minute)"
  }
}
