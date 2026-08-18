data "aws_caller_identity" "current" {}

locals {
  dcv_license_arn = "arn:aws:s3:::dcv-license.${var.region}/*"
  artifacts_arn   = "arn:aws:s3:::${var.artifacts_bucket}"
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# ---------- control plane role ----------

resource "aws_iam_role" "controlplane" {
  name               = "asp-controlplane"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

data "aws_iam_policy_document" "controlplane" {
  # (DNS + certs live at the DNS provider — Cloudflare for the PoC; the
  #  certbot token arrives via SSM param /asp/cloudflare/token, no AWS DNS IAM)
  # portal power controls — desktops of this tenant only
  statement {
    actions   = ["ec2:DescribeInstances", "ec2:DescribeInstanceStatus"]
    resources = ["*"]
  }
  statement {
    actions = [
      "ec2:StartInstances",
      "ec2:StopInstances",
      "ec2:RebootInstances",
      "ec2:TerminateInstances",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/Role"
      values   = ["desktop"]
    }
    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/Customer"
      values   = [var.customer]
    }
  }
  # admin page: provision terminals from the launch template
  statement {
    actions   = ["ec2:RunInstances"]
    resources = ["*"]
  }
  statement {
    actions   = ["ec2:CreateTags"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["RunInstances"]
    }
  }
  statement {
    actions   = ["ec2:DescribeLaunchTemplates", "ec2:DescribeLaunchTemplateVersions"]
    resources = ["*"]
  }
  # RunInstances launches with the desktop instance profile
  statement {
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.desktop.arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }
  # share flow: create the guest's OS user on the target desktop
  statement {
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:${var.region}::document/AWS-RunShellScript"]
  }
  statement {
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Role"
      values   = ["desktop"]
    }
  }
  # idle watchdog reads its probe results
  statement {
    actions   = ["ssm:GetCommandInvocation"]
    resources = ["*"]
  }
  # setup scripts + portal builds; publishes the broker CA for desktops to pull
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${local.artifacts_arn}/*"]
  }
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${local.artifacts_arn}/certs/*"]
  }
  statement {
    actions   = ["s3:ListBucket"]
    resources = [local.artifacts_arn]
  }
  # portal config + secrets; idle settings are admin-writable
  statement {
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/asp/*",
    ]
  }
  statement {
    actions = ["ssm:PutParameter"]
    resources = [
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/asp/idle/*",
      "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/asp/portal/viewers",
    ]
  }
  # per-terminal idle-policy overrides live as instance tags
  statement {
    actions   = ["ec2:CreateTags", "ec2:DeleteTags"]
    resources = ["arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/Role"
      values   = ["desktop"]
    }
    condition {
      test     = "StringEquals"
      variable = "ec2:ResourceTag/Customer"
      values   = [var.customer]
    }
  }
}

resource "aws_iam_role_policy" "controlplane" {
  name   = "asp-controlplane"
  role   = aws_iam_role.controlplane.id
  policy = data.aws_iam_policy_document.controlplane.json
}

resource "aws_iam_role_policy_attachment" "controlplane_ssm" {
  role       = aws_iam_role.controlplane.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "controlplane" {
  name = "asp-controlplane"
  role = aws_iam_role.controlplane.name
}

# ---------- desktop role ----------

resource "aws_iam_role" "desktop" {
  name               = "asp-desktop"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

data "aws_iam_policy_document" "desktop" {
  # DCV is license-free on EC2 via this bucket read
  statement {
    actions   = ["s3:GetObject"]
    resources = [local.dcv_license_arn]
  }
  # provisioning progress markers, read by the portal
  statement {
    actions   = ["s3:PutObject"]
    resources = ["${local.artifacts_arn}/status/*"]
  }
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${local.artifacts_arn}/*"]
  }
  statement {
    actions   = ["s3:ListBucket"]
    resources = [local.artifacts_arn]
  }
}

resource "aws_iam_role_policy" "desktop" {
  name   = "asp-desktop"
  role   = aws_iam_role.desktop.id
  policy = data.aws_iam_policy_document.desktop.json
}

resource "aws_iam_role_policy_attachment" "desktop_ssm" {
  role       = aws_iam_role.desktop.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "desktop" {
  name = "asp-desktop"
  role = aws_iam_role.desktop.name
}

# ---------- medical profile (count-gated; standard tenants get none of this) ----------
# Terminals call Claude on Bedrock with the instance role. Allow-list is
# "any Anthropic Claude model": which models are USABLE is decided by the
# account's Bedrock data-retention mode (none → Fable/Mythos unavailable),
# not by IAM — see aws/scripts/bedrock-zdr.sh.
data "aws_iam_policy_document" "desktop_bedrock" {
  statement {
    sid     = "InvokeClaudeOnBedrock"
    actions = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"]
    resources = [
      "arn:aws:bedrock:*::foundation-model/anthropic.claude-*",
      "arn:aws:bedrock:${var.region}:${data.aws_caller_identity.current.account_id}:inference-profile/*.anthropic.claude-*",
    ]
  }
  statement {
    sid       = "ResolveInferenceProfiles"
    actions   = ["bedrock:ListInferenceProfiles", "bedrock:GetInferenceProfile"]
    resources = ["*"]
  }
  statement {
    sid       = "SeeModelSubscriptions"
    actions   = ["aws-marketplace:ViewSubscriptions"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "desktop_bedrock" {
  count  = var.profile == "medical" ? 1 : 0
  name   = "asp-desktop-bedrock"
  role   = aws_iam_role.desktop.id
  policy = data.aws_iam_policy_document.desktop_bedrock.json
}

# Guard: nothing running under these roles may weaken zero-data-retention or
# switch on model-invocation logging (which would persist prompts — PHI — to
# S3/CloudWatch). Account admins are outside these roles; the SCP output
# below is for the client's Organization, if they have one.
data "aws_iam_policy_document" "bedrock_zdr_guard" {
  statement {
    sid       = "LockBedrockZeroDataRetention"
    effect    = "Deny"
    actions   = ["bedrock:PutAccountDataRetention"]
    resources = ["*"]
    condition {
      test     = "StringNotEquals"
      variable = "bedrock:DataRetentionMode"
      values   = ["none"]
    }
  }
  statement {
    sid       = "NoBedrockInvocationLogging"
    effect    = "Deny"
    actions   = ["bedrock:PutModelInvocationLoggingConfiguration"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "desktop_zdr_guard" {
  count  = var.profile == "medical" ? 1 : 0
  name   = "asp-desktop-bedrock-zdr-guard"
  role   = aws_iam_role.desktop.id
  policy = data.aws_iam_policy_document.bedrock_zdr_guard.json
}

resource "aws_iam_role_policy" "controlplane_zdr_guard" {
  count  = var.profile == "medical" ? 1 : 0
  name   = "asp-controlplane-bedrock-zdr-guard"
  role   = aws_iam_role.controlplane.id
  policy = data.aws_iam_policy_document.bedrock_zdr_guard.json
}
