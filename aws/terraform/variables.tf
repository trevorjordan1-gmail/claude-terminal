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
  # m5a.large: dedicated vCPUs (no burst-credit steal under sustained desktop
  # load) at effectively the same price as t3-unlimited; hibernation-capable.
  default = "m5a.large"
}

variable "artifacts_bucket" {
  description = "Pre-existing S3 bucket holding setup scripts + portal builds (e.g. <org>-asp-artifacts-<account-id>)"
}

variable "brand" {
  description = "Portal title/header text (issue #1). Neutral default; set per tenant to brand the portal without touching templates."
  default     = "Claude Code Terminals"
}

variable "profile" {
  description = "Terminal profile for this tenant: standard, or medical (Ai Build Medical — Claude Code pinned to Bedrock, DCV file-download denied, ZDR guard). Reaches every terminal as ASP_PROFILE."
  default     = "standard"
  validation {
    condition     = contains(["standard", "medical"], var.profile)
    error_message = "profile must be \"standard\" or \"medical\"."
  }
}

# ---- portal exposure (#57) ----
# Cloudflare's free Universal SSL covers ONE label under the zone (*.<zone> + apex), so the
# runbook's portal.terminals.<zone> (two labels) has no edge certificate and cannot be
# proxied through a Tunnel + Access — TLS fails at the edge. A tenant that wants the portal
# behind Access therefore publishes it under a FIRST-LEVEL name (e.g. terminals.<zone>) and
# closes 443 on the EIP. The DCV gateway is unaffected either way: it stays a grey-cloud A
# record (DCV cannot traverse the proxy), so cp-tls.sh's wildcard cert is still required
# for the gateway and the per-terminal vanity names — this is NOT "no more certbot".
variable "portal_public" {
  description = "Expose the portal's 443 on the control plane EIP (the default: nginx + Let's Encrypt). A tenant that publishes the portal through a Cloudflare Tunnel + Access instead sets false: no inbound 443 at all — only the DCV gateway's 8443 stays open, which cannot be proxied (#57)."
  type        = bool
  default     = true
}

variable "portal_public_host" {
  description = "Optional public name users type for the portal when it is published through a proxy/tunnel under a different hostname than the cert + nginx are built for (one label under the Cloudflare zone, e.g. terminals.example.com). Reaches the control plane as ASP_PORTAL_PUBLIC_HOST: portal-deploy.sh uses it for the OIDC redirect URI, links and nginx server_name, while cp-tls.sh keeps deriving the wildcard cert from ASP_PORTAL_HOST. Empty = portal.<dns_zone>. NOTE: on a LIVE control plane a change here rewrites user_data, which stops/starts the instance — on a running tenant prefer appending the line to /etc/asp-terminal.env via tenant-custom-cp.sh and re-running portal-deploy.sh (#57)."
  type        = string
  default     = ""
}
