# EBS encryption by default — ALL tenants, not just medical. The launch
# template already encrypts roots (hibernation needs it); this makes the
# account/Region default catch anything created outside it (hand-restored
# snapshots, extra data disks). Account/Region-wide, so a tenant teardown must
# not switch it off: prevent_destroy — `terraform state rm
# aws_ebs_encryption_by_default.this` before `destroy` (runbook §12).
resource "aws_ebs_encryption_by_default" "this" {
  enabled = true
  lifecycle {
    prevent_destroy = true
  }
}
