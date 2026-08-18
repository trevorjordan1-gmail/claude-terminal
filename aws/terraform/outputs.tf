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

output "bedrock_zdr_scp_json" {
  description = "Service control policy for the CLIENT's AWS Organization admin (if the tenant account sits in one): denies weakening Bedrock zero-data-retention and enabling model-invocation logging account-wide. Standalone accounts have no SCP; the role-level guard in iam.tf plus bedrock-zdr.sh --check is what applies there."
  value = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "LockBedrockZeroDataRetention"
        Effect    = "Deny"
        Action    = ["bedrock:PutAccountDataRetention"]
        Resource  = "*"
        Condition = { StringNotEquals = { "bedrock:DataRetentionMode" = "none" } }
      },
      {
        Sid      = "NoBedrockInvocationLogging"
        Effect   = "Deny"
        Action   = ["bedrock:PutModelInvocationLoggingConfiguration"]
        Resource = "*"
      },
    ]
  })
}
