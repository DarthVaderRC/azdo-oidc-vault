data "aws_caller_identity" "current" {}

# The permission the dynamic credential carries. Deliberately trivial: the
# point is that the credential works, then stops working, not what it can do.
#
# ec2:DescribeRegions rather than s3:ListAllMyBuckets because the sandbox
# boundary permits the former and not the latter. A dynamic user's effective
# permissions are this policy intersected with the boundary, so anything
# outside the boundary is silently useless however it is written here.
data "aws_iam_policy_document" "pipeline_credential" {
  statement {
    effect    = "Allow"
    actions   = ["ec2:DescribeRegions"]
    resources = ["*"]
  }
}

# Vault's root credential. The action list is the one HashiCorp documents for
# the iam_user credential type. The resource is narrowed to this user's own
# name plus a wildcard, which is both what the POC needs and the only shape
# the sandbox boundary's CreateChildUser statement will permit.
#
# Actions the boundary does not allow, such as AttachUserPolicy and the group
# operations, are left in place deliberately. Effective permission is the
# intersection of this policy and the boundary, so they cost nothing, and
# keeping HashiCorp's documented list intact means a run in an unconstrained
# account needs no edit here.
data "aws_iam_policy_document" "vault_root" {
  statement {
    sid    = "ManageVaultDynamicUsers"
    effect = "Allow"
    actions = [
      "iam:AddUserToGroup",
      "iam:AttachUserPolicy",
      "iam:CreateAccessKey",
      "iam:CreateUser",
      "iam:DeleteAccessKey",
      "iam:DeleteUser",
      "iam:DeleteUserPolicy",
      "iam:DetachUserPolicy",
      "iam:GetUser",
      "iam:ListAccessKeys",
      "iam:ListAttachedUserPolicies",
      "iam:ListGroupsForUser",
      "iam:ListUserPolicies",
      "iam:PutUserPolicy",
      "iam:RemoveUserFromGroup",
      "iam:TagUser",
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user${var.iam_user_path}${local.aws_root_user_name}*"
    ]
  }
}

resource "aws_iam_user" "vault_root" {
  count                = local.enable_aws ? 1 : 0
  name                 = local.aws_root_user_name
  path                 = var.iam_user_path
  permissions_boundary = var.aws_permissions_boundary
}

resource "aws_iam_user_policy" "vault_root" {
  count  = local.enable_aws ? 1 : 0
  name   = "${var.name_prefix}-vault-root"
  user   = aws_iam_user.vault_root[0].name
  policy = data.aws_iam_policy_document.vault_root.json
}

# This key is stored in Terraform state. rotate-root is deliberately not used:
# rotating outside Terraform invalidates the stored value and creates a drift
# loop on the next apply. The stretch goal removes the key entirely.
resource "aws_iam_access_key" "vault_root" {
  count = local.enable_aws ? 1 : 0
  user  = aws_iam_user.vault_root[0].name
}

# Audit plumbing, not part of the zero standing privileges claim. HCP Vault
# Dedicated streams audit logs using a static key, which is pasted into the
# HCP portal by hand because the cluster is not managed by this configuration.
data "aws_iam_policy_document" "hcp_audit" {
  statement {
    sid    = "HcpVaultAuditLogStreaming"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
      "logs:TagLogGroup",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_user" "hcp_audit" {
  count                = local.enable_vault ? 1 : 0
  name                 = local.aws_audit_user_name
  path                 = var.iam_user_path
  permissions_boundary = var.aws_permissions_boundary

  # Load-bearing, not metadata, wherever the boundary builds the permitted log
  # group ARN out of these two tags: without them every HCP write is denied
  # and the log group is never created, while HCP still reports streaming as
  # healthy. Omitted entirely when the IDs are unset, because the provider
  # rejects a null tag value. See the variable definitions.
  tags = (var.hcp_org_id != null && var.hcp_project_id != null) ? {
    "hcp-org-id"     = var.hcp_org_id
    "hcp-project-id" = var.hcp_project_id
  } : {}
}

resource "aws_iam_user_policy" "hcp_audit" {
  count  = local.enable_vault ? 1 : 0
  name   = "${var.name_prefix}-hcp-audit"
  user   = aws_iam_user.hcp_audit[0].name
  policy = data.aws_iam_policy_document.hcp_audit.json
}

resource "aws_iam_access_key" "hcp_audit" {
  count = local.enable_vault ? 1 : 0
  user  = aws_iam_user.hcp_audit[0].name
}
