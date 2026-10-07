data "http" "my_ip" {
  count = var.admin_cidr == null ? 1 : 0
  url   = "https://checkip.amazonaws.com"
}

locals {
  admin_cidr = var.admin_cidr != null ? var.admin_cidr : "${chomp(data.http.my_ip[0].response_body)}/32"
}

resource "aws_security_group" "nodes" {
  name        = "${var.cluster_name}-nodes"
  description = "k3s nodes: all traffic from admin IP and between nodes"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.cluster_name}-nodes" }
}

resource "aws_vpc_security_group_ingress_rule" "admin" {
  security_group_id = aws_security_group.nodes.id
  description       = "All traffic from admin IP"
  cidr_ipv4         = local.admin_cidr
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_ingress_rule" "self" {
  security_group_id            = aws_security_group.nodes.id
  description                  = "All traffic between nodes"
  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
