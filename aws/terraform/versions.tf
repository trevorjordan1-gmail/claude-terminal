terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  # Per-tenant backend — supply at init time (never commit tenant values):
  #   terraform init \
  #     -backend-config="bucket=<org>-asp-tfstate-<account-id>" \
  #     -backend-config="key=<tenant>/terraform.tfstate" \
  #     -backend-config="region=<region>" \
  #     -backend-config="use_lockfile=true"
  # or keep a git-ignored backend.hcl and run: terraform init -backend-config=backend.hcl
  backend "s3" {}
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Customer  = var.customer
      Project   = "asp-terminals"
      ManagedBy = "terraform"
    }
  }
}
