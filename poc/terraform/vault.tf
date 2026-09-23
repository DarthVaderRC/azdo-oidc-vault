resource "vault_namespace" "zsp" {
  count = local.enable_vault ? 1 : 0
  path  = var.vault_namespace_path
}

resource "vault_jwt_auth_backend" "azdo" {
  count = local.enable_vault ? 1 : 0

  namespace   = vault_namespace.zsp[0].path
  path        = var.vault_jwt_path
  type        = "jwt"
  description = "Azure DevOps pipelines, via Entra-issued ID tokens"

  # Both are the Entra issuer the service connections were given. Nothing is
  # hardcoded, so the mount cannot drift from the tokens it must validate.
  oidc_discovery_url = local.entra_issuer
  bound_issuer       = local.entra_issuer

  lifecycle {
    precondition {
      condition = length(distinct([
        for k, sc in azuredevops_serviceendpoint_azurerm.pipeline :
        sc.workload_identity_federation_issuer
      ])) == 1
      error_message = "The service connections do not share one issuer, so a single JWT mount cannot validate all of them."
    }
  }
}

resource "vault_policy" "pipeline" {
  for_each = local.vault_pipelines

  namespace = vault_namespace.zsp[0].path
  name      = "${var.name_prefix}-${each.key}"

  # Read one AWS role and nothing else. revoke-self is not granted here: it
  # comes from Vault's default policy, which is why token_no_default_policy
  # must stay false on the role below.
  policy = <<-EOT
    path "${var.vault_aws_path}/creds/${var.name_prefix}-${each.key}" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_jwt_auth_backend_role" "pipeline" {
  for_each = local.vault_pipelines

  namespace = vault_namespace.zsp[0].path
  backend   = vault_jwt_auth_backend.azdo[0].path
  role_name = "${var.name_prefix}-${each.key}"
  role_type = "jwt"

  # Measured from a real token in phase 1, not taken from documentation. See
  # the variable's own comment: the issued token's audience is a fixed
  # Microsoft GUID, not api://AzureADTokenExchange. Binding the documented
  # value here would reject every login.
  bound_audiences = [var.vault_bound_audience]

  # Exact match on one service connection's subject. Not bound_subject, which
  # is exact-only and silently ignores glob patterns, and not a glob, which
  # would have to pin the organisation segment to be safe.
  bound_claims = {
    sub = azuredevops_serviceendpoint_azurerm.pipeline[each.key].workload_identity_federation_subject
  }

  # Resolves every pipeline to one Vault entity, while bound_claims above
  # authorises each pipeline separately. claim_mappings keeps full attribution
  # in the audit record, so the two are not in tension.
  user_claim = var.vault_user_claim
  claim_mappings = {
    sub = "pipeline_subject"
  }

  token_policies = [vault_policy.pipeline[each.key].name]
  token_ttl      = var.vault_token_ttl
  token_max_ttl  = var.vault_token_ttl

  # Exactly two: one credential read and one revoke-self. A token that runs
  # out of uses is revoked, and revoking a token revokes its leases, which
  # would delete the AWS credential mid-task. The credential read must
  # therefore never be retried.
  token_num_uses = 2

  # revoke-self lives in the default policy. Removing it would break the
  # revocation this POC exists to demonstrate.
  token_no_default_policy = false
}

resource "vault_aws_secret_backend" "aws" {
  count = local.enable_aws ? 1 : 0

  namespace   = vault_namespace.zsp[0].path
  path        = var.vault_aws_path
  description = "Short-lived AWS credentials for Azure DevOps pipelines"
  region      = var.aws_region

  # Static root credential. The stretch goal replaces this with plugin
  # workload identity federation and deletes the key. Note that the secret is
  # held in Terraform state either way, because aws_iam_access_key stores it.
  access_key = aws_iam_access_key.vault_root[0].id
  secret_key = aws_iam_access_key.vault_root[0].secret

  # Mount-wide, because Vault puts username generation on the mount rather
  # than the role. Mandatory here: Vault's default template produces vault-*
  # names, and the sandbox boundary lets the root user create children only
  # under user/${aws:username}*, so every default-named credential is denied.
  # The suffix length is computed so the result cannot exceed IAM's 64-char
  # limit, and truncate is a second guard rather than the primary one.
  username_template = "{{ printf \"${local.aws_root_user_name}-%s\" (random ${local.aws_username_suffix_len}) | truncate 64 }}"

  default_lease_ttl_seconds = var.aws_lease_ttl
  max_lease_ttl_seconds     = var.aws_lease_ttl
}

resource "vault_aws_secret_backend_role" "pipeline" {
  for_each = local.aws_pipelines

  namespace = vault_namespace.zsp[0].path
  backend   = vault_aws_secret_backend.aws[0].path
  name      = "${var.name_prefix}-${each.key}"

  # iam_user, not assumed_role. Only iam_user credentials can be revoked
  # before they expire, and "the credential is dead once the pipeline
  # finishes" is the claim this POC has to demonstrate.
  credential_type = "iam_user"

  # Root, not a dedicated path. The sandbox permits iam:CreateUser only on an
  # ARN with no path segment, so a path here would deny every credential.
  user_path = var.iam_user_path

  # Mandatory in this account: without it the CreateUser call is denied
  # outright, because the sandbox conditions its allow on this exact boundary.
  # The matching username_template lives on the mount, not here.
  permissions_boundary_arn = var.aws_permissions_boundary

  policy_document = data.aws_iam_policy_document.pipeline_credential.json
}
