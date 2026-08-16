variable "region" {
  default = "us-east-2"
}

variable "customer" {
  description = "Tenant identifier; on client deployments this is the client slug (e.g. acme-poc)"
}

variable "client_code" {
  description = "Short client code used in terminal names: <client_code>-cctNN"
}

variable "dns_zone" {
  description = "DNS zone for this tenant's portal + gateway (e.g. terminals.example.com)"
}

variable "cert_email" {
  description = "Contact email for Let's Encrypt registration (expiry notices)"
}

variable "vpc_cidr" {
  default = "10.60.0.0/16"
}

variable "control_plane_type" {
  default = "t4g.small"
}

variable "desktop_instance_type" {
  default = "t3.large"
}

variable "artifacts_bucket" {
  description = "Pre-existing S3 bucket holding setup scripts + portal builds (e.g. <org>-asp-artifacts-<account-id>)"
}
