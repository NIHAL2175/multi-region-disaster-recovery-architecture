# AWS Transit Gateway Multi-Region Peering
resource "aws_ec2_transit_gateway" "primary" {
  provider    = aws.primary
  description = "PaySecure Mumbai Transit Gateway"
  tags        = { Name = "paysecure-tgw-mumbai" }
}

resource "aws_ec2_transit_gateway" "secondary" {
  provider    = aws.secondary
  description = "PaySecure Hyderabad Transit Gateway"
  tags        = { Name = "paysecure-tgw-hyd" }
}

resource "aws_ec2_transit_gateway_peering_attachment" "peering" {
  provider                = aws.primary
  transit_gateway_id      = aws_ec2_transit_gateway.primary.id
  peer_transit_gateway_id = aws_ec2_transit_gateway.secondary.id
  peer_region             = "ap-south-2"
  tags                    = { Name = "tgw-peering-mum-hyd" }
}
