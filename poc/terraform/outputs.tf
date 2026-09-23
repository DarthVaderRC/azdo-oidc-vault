output "phase" {
  description = "Which phase this state represents."
  value       = "${var.pipeline_mode} (token_method ${var.token_method})"
}

# Phase 1 checkpoint. Every issuer must be the Entra one and every subject
# must begin /eid1/, or the apply has already failed on a postcondition.
output "service_connections" {
  description = "Service connection IDs with the issuer and subject Azure DevOps generated for each."
  value = {
    for k, sc in azuredevops_serviceendpoint_azurerm.pipeline : k => {
      id      = sc.id
      name    = sc.service_endpoint_name
      issuer  = sc.workload_identity_federation_issuer
      subject = sc.workload_identity_federation_subject
    }
  }
}

# Acceptance test 8 runs against this:
#   az role assignment list --assignee <principal_id> --all
# and must return an empty list.
output "managed_identity" {
  description = "The shared managed identity. It should hold no Azure role assignment unless the azurecli token method forced one."
  value = {
    name         = azurerm_user_assigned_identity.zsp.name
    client_id    = azurerm_user_assigned_identity.zsp.client_id
    principal_id = azurerm_user_assigned_identity.zsp.principal_id

    # Acceptance test 8 reads this. "none" is the result the POC argues for;
    # anything else is a standing privilege and has to be justified on stage.
    standing_azure_privilege = var.grant_identity_reader ? "Reader on ${azurerm_resource_group.zsp.name}, required by token_method=azurecli" : "none"
  }
}

output "vault" {
  description = "Where the Vault objects live, for the manual verification commands."
  value = {
    address      = local.vault_addr
    namespace    = local.vault_namespace_fq
    jwt_mount    = var.vault_jwt_path
    aws_mount    = var.vault_aws_path
    user_claim   = var.vault_user_claim
    roles        = [for k, v in var.pipelines : "${var.name_prefix}-${k}"]
    entity_check = "vault list -namespace=${local.vault_namespace_fq} identity/entity/id"
  }
}

# What the demo scripts need in order to find the objects this build created.
# They read these as environment variables, so demo/env-from-terraform.sh turns
# this output into exports and the two cannot drift apart.
output "demo_env" {
  description = "Values the scripts in demo/ need. See demo/env-from-terraform.sh."
  value = {
    AZDO_PROJECT    = var.azdo_project_name
    NAME_PREFIX     = var.name_prefix
    AWS_USER_PREFIX = var.aws_user_prefix
    VAULT_JWT_PATH  = var.vault_jwt_path
    VAULT_AWS_PATH  = var.vault_aws_path
    VAULT_NAMESPACE = local.vault_namespace_fq
  }
}

output "pipelines" {
  description = "Build definition IDs, for triggering runs."
  value = {
    for k, bd in azuredevops_build_definition.pipeline : k => {
      id  = bd.id
      run = "az pipelines run --id ${bd.id} --project ${var.azdo_project_name}"
    }
  }
}

output "hcp_audit_credentials" {
  description = "Paste these into the HCP portal to enable audit log streaming to CloudWatch."
  sensitive   = true
  value = local.enable_vault ? {
    access_key_id     = aws_iam_access_key.hcp_audit[0].id
    secret_access_key = aws_iam_access_key.hcp_audit[0].secret
    region            = var.aws_region
  } : null
}
