locals {
  # Phase gating. One variable drives which resources exist and what the
  # pipelines do, so a phase is advanced by changing pipeline_mode alone.
  enable_vault = var.pipeline_mode != "inspect"
  enable_aws   = var.pipeline_mode == "full"

  vault_pipelines = local.enable_vault ? var.pipelines : {}
  aws_pipelines   = local.enable_aws ? var.pipelines : {}

  vault_addr = var.vault_addr

  # Resource-level namespace arguments are relative to the provider's
  # namespace, so Vault resources use the bare path. The pipelines talk to the
  # API directly and need the fully qualified one for X-Vault-Namespace.
  vault_namespace_fq = "${var.vault_parent_namespace}/${var.vault_namespace_path}"

  # Taken from one service connection and asserted identical across all of
  # them, so the JWT mount trusts exactly the issuer the tokens carry.
  entra_issuer = values(azuredevops_serviceendpoint_azurerm.pipeline)[0].workload_identity_federation_issuer

  # Role name to the subject its Vault role is bound to. The negative test
  # names another pipeline's role, and the demo narration shows that role's
  # subject beside this token's so the one-segment difference is visible.
  role_subjects = {
    for k, sc in azuredevops_serviceendpoint_azurerm.pipeline :
    "${var.name_prefix}-${k}" => sc.workload_identity_federation_subject
  }

  # Vault's root IAM user. Every dynamic user Vault creates must be prefixed
  # with this name, because the sandbox boundary restricts a user to creating
  # children under arn:aws:iam::<account>:user/${aws:username}*.
  aws_root_user_name  = "${var.aws_user_prefix}-vault-root"
  aws_audit_user_name = "${var.aws_user_prefix}-hcp-audit"

  # IAM usernames cap at 64 characters. The prefix is long, so the random
  # suffix is sized to fit rather than assumed to.
  aws_username_suffix_len = 64 - length(local.aws_root_user_name) - 1
}
