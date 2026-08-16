# Control plane: the only thing the internet can reach.
# NOTE: this SG uses ONLY standalone rule resources (no inline blocks) — the
# desktop SG references it and it references the desktop SG (8445), and mixing
# inline rules with aws_security_group_rule makes Terraform strip the
# standalone ones on every refresh.
resource "aws_security_group" "controlplane" {
  name        = "asp-controlplane"
  description = "Portal 443 + DCV gateway 8443; broker agent port from desktops only"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "asp-controlplane" }
}

resource "aws_security_group_rule" "cp_portal_https" {
  type              = "ingress"
  description       = "portal HTTPS"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.controlplane.id
}

resource "aws_security_group_rule" "cp_gateway_tcp" {
  type              = "ingress"
  description       = "DCV gateway TCP"
  from_port         = 8443
  to_port           = 8443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.controlplane.id
}

resource "aws_security_group_rule" "cp_gateway_quic" {
  type              = "ingress"
  description       = "DCV gateway QUIC"
  from_port         = 8443
  to_port           = 8443
  protocol          = "udp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.controlplane.id
}

resource "aws_security_group_rule" "cp_broker_agents" {
  type                     = "ingress"
  description              = "SM agents on desktops to broker"
  from_port                = 8445
  to_port                  = 8445
  protocol                 = "tcp"
  security_group_id        = aws_security_group.controlplane.id
  source_security_group_id = aws_security_group.desktop.id
}

resource "aws_security_group_rule" "cp_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.controlplane.id
}

# Desktops: gateway-to-DCV-server only. No other inbound, no SSH, no public IP.
resource "aws_security_group" "desktop" {
  name        = "asp-desktop"
  description = "DCV server reachable from control plane only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "DCV from gateway"
    from_port       = 8443
    to_port         = 8443
    protocol        = "tcp"
    security_groups = [aws_security_group.controlplane.id]
  }
  ingress {
    description     = "DCV QUIC from gateway"
    from_port       = 8443
    to_port         = 8443
    protocol        = "udp"
    security_groups = [aws_security_group.controlplane.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "asp-desktop" }
}
