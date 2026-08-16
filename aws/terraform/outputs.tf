output "dns_records_needed" {
  description = "Create these A records at the DNS provider (DNS-only / grey cloud)"
  value = {
    "portal.${var.dns_zone}" = aws_eip.controlplane.public_ip
    "gw.${var.dns_zone}"     = aws_eip.controlplane.public_ip
  }
}

output "portal_url" {
  value = "https://portal.${var.dns_zone}"
}

output "gateway_endpoint" {
  value = "gw.${var.dns_zone}:8443"
}

output "controlplane_public_ip" {
  value = aws_eip.controlplane.public_ip
}

output "controlplane_instance_id" {
  value = aws_instance.controlplane.id
}

output "desktop_launch_template_id" {
  value = aws_launch_template.desktop.id
}

output "desktop_subnet_ids" {
  value = [aws_subnet.private_a.id, aws_subnet.private_b.id]
}
