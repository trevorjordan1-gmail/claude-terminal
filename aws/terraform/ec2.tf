data "aws_ami" "ubuntu_amd64" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

data "aws_ami" "ubuntu_arm64" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }
}

# ---------- control plane ----------

resource "aws_instance" "controlplane" {
  ami                    = data.aws_ami.ubuntu_arm64.id
  instance_type          = var.control_plane_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.controlplane.id]
  iam_instance_profile   = aws_iam_instance_profile.controlplane.name

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = templatefile("${path.module}/templates/bootstrap.sh.tftpl", {
    bucket = var.artifacts_bucket
    script = "cp-setup.sh"
    arch   = "aarch64"
    # ASP_PORTAL_PUBLIC_HOST is written only when set (#57), so an unchanged tenant's
    # user_data — and therefore its control plane — is byte-identical to before.
    env = merge({
      ASP_DNS_ZONE    = var.dns_zone
      ASP_PORTAL_HOST = "portal.${var.dns_zone}"
      ASP_GW_HOST     = "gw.${var.dns_zone}"
      ASP_CUSTOMER    = var.customer
      ASP_REGION      = var.region
      ASP_BUCKET      = var.artifacts_bucket
      ASP_CERT_EMAIL  = var.cert_email
      ASP_PROFILE     = var.profile
      ASP_BRAND       = var.brand
    }, var.portal_public_host != "" ? { ASP_PORTAL_PUBLIC_HOST = var.portal_public_host } : {})
  })

  tags = { Name = "asp-controlplane", Role = "controlplane" }
}

resource "aws_eip" "controlplane" {
  domain = "vpc"
  tags   = { Name = "asp-controlplane" }
}

resource "aws_eip_association" "controlplane" {
  instance_id   = aws_instance.controlplane.id
  allocation_id = aws_eip.controlplane.id
}

# ---------- desktops: portal-managed via launch template ----------
# Terminals are day-2 resources: the PORTAL provisions/terminates them from
# this launch template (admin page add/remove user). Terraform owns only the
# template. Existing instances were released from state on 2026-08-15.

resource "aws_launch_template" "desktop" {
  name          = "asp-desktop"
  image_id      = data.aws_ami.ubuntu_amd64.id
  instance_type = var.desktop_instance_type
  # the portal's RunInstances uses the DEFAULT version — without this, every
  # template change strands new terminals on v1 (bit us: throughput bump)
  update_default_version = true

  iam_instance_profile {
    name = aws_iam_instance_profile.desktop.name
  }

  vpc_security_group_ids = [aws_security_group.desktop.id]

  hibernation_options {
    configured = true
  }

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size           = 50
      volume_type           = "gp3"
      encrypted             = true # required for hibernation
      delete_on_termination = true
      # Baseline 125 MB/s. 250 MB/s roughly halves heavy resume-from-Pause
      # times but costs $5/volume/month even while hibernated — on a mostly
      # idle fleet that is more than the terminal's own compute (see
      # runbooks/budgets.md). Raise per tenant if resumes feel too slow.
      throughput = 125
    }
  }
  # user_data + tags are supplied per-launch by the portal
}
