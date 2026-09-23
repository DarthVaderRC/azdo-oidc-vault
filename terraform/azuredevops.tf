data "azuredevops_project" "poc" {
  name = var.azdo_project_name
}

resource "azuredevops_git_repository" "zsp" {
  project_id     = data.azuredevops_project.poc.id
  name           = var.azdo_repo_name
  default_branch = "refs/heads/main"

  initialization {
    init_type = "Clean"
  }
}

# The script every pipeline runs. Static, so it is committed once rather than
# rendered per pipeline. All per-pipeline values reach it as environment
# variables set in the YAML.
resource "azuredevops_git_repository_file" "script" {
  repository_id       = azuredevops_git_repository.zsp.id
  file                = "pipelines/vault-zsp.sh"
  content             = file("${path.module}/../pipelines/vault-zsp.sh")
  branch              = "refs/heads/main"
  commit_message      = "Vault zero standing privileges pipeline script, managed by Terraform"
  overwrite_on_create = true

  # The provider refreshes commit_message from the branch head, not from the
  # commit that last touched this file. Several files share one branch, so
  # whichever committed last wins and every other file resource reports drift
  # on every plan, forever. The content is what matters and is compared
  # normally; the message is cosmetic.
  lifecycle {
    ignore_changes = [commit_message]
  }
}

# Service connections are created in manual mode against the existing managed
# identity. Automatic mode would create an app registration and attempt a role
# assignment, neither of which this design uses or has permission for.
#
# The features.validate block is deliberately omitted. Validation would try to
# exchange a token before the federated credential exists, and the credential
# cannot exist until this resource has produced its subject.
resource "azuredevops_serviceendpoint_azurerm" "pipeline" {
  for_each = var.pipelines

  project_id                             = data.azuredevops_project.poc.id
  service_endpoint_name                  = "${var.name_prefix}-sc-${each.key}"
  description                            = "Zero standing privileges POC, ${each.key}. Managed by Terraform."
  service_endpoint_authentication_scheme = "WorkloadIdentityFederation"

  credentials {
    serviceprincipalid = azurerm_user_assigned_identity.zsp.client_id
  }

  azurerm_spn_tenantid      = data.azurerm_subscription.current.tenant_id
  azurerm_subscription_id   = data.azurerm_subscription.current.subscription_id
  azurerm_subscription_name = data.azurerm_subscription.current.display_name

  lifecycle {
    # Phase 1 hard stop. If Azure DevOps hands back the retiring Azure DevOps
    # issuer rather than the Entra one, this configuration would be building
    # Path A, on an issuer that reaches end of life on 1 July 2027.
    postcondition {
      condition     = startswith(self.workload_identity_federation_issuer, "https://login.microsoftonline.com/")
      error_message = "Service connection ${self.service_endpoint_name} was issued by ${self.workload_identity_federation_issuer}, not the Microsoft Entra issuer. Stop: this would build the retiring Azure DevOps issuer path."
    }

    postcondition {
      condition     = startswith(self.workload_identity_federation_subject, "/eid1/")
      error_message = "Service connection ${self.service_endpoint_name} has subject ${self.workload_identity_federation_subject}, which is not the expected Entra form beginning /eid1/."
    }
  }
}

# Non-blocking. The decoded subject structure came from a different Azure
# DevOps organisation, so confirm the last segment is still the connection ID
# rather than assume it.
check "subject_ends_with_connection_id" {
  assert {
    condition = alltrue([
      for k, sc in azuredevops_serviceendpoint_azurerm.pipeline :
      endswith(sc.workload_identity_federation_subject, "/${sc.id}")
    ])
    error_message = "A service connection subject does not end with its own connection ID. The decoded subject structure in POC_VALIDATION.md needs updating."
  }
}

resource "azuredevops_git_repository_file" "pipeline" {
  for_each = var.pipelines

  repository_id = azuredevops_git_repository.zsp.id
  file          = "pipelines/${var.name_prefix}-${each.key}.yml"
  content = templatefile("${path.module}/../pipelines/pipeline.yml.tftpl", {
    display_name    = "${var.name_prefix}-${each.key}"
    mode            = var.pipeline_mode
    token_method    = var.token_method
    sc_name         = azuredevops_serviceendpoint_azurerm.pipeline[each.key].service_endpoint_name
    sc_id           = azuredevops_serviceendpoint_azurerm.pipeline[each.key].id
    vault_addr      = local.vault_addr
    vault_namespace = local.vault_namespace_fq
    vault_jwt_path  = var.vault_jwt_path
    vault_role      = "${var.name_prefix}-${each.key}"
    vault_aws_path  = var.vault_aws_path
    # negative_role names another entry in the pipelines map; the Vault role
    # name is composed here so name_prefix appears in no variable default.
    # Indexed, not lookup() with a fallback: a key that does not exist is a
    # plan-time error rather than an empty string that renders a pipeline
    # pointed at a role which does not exist. A variable validation catches it
    # first, so this is the second guard, not the only one.
    #
    # Not coalesce: it rejects "" as well as null, so a pipeline with no
    # negative test would fail evaluation rather than render an empty value.
    negative_role = each.value.negative_role != null ? "${var.name_prefix}-${each.value.negative_role}" : ""
    negative_subject = (
      each.value.negative_role != null
      ? local.role_subjects["${var.name_prefix}-${each.value.negative_role}"]
      : ""
    )
    demo       = var.demo_narration ? "1" : "0"
    aws_region = var.aws_region
  })
  branch              = "refs/heads/main"
  commit_message      = "Pipeline ${var.name_prefix}-${each.key} in ${var.pipeline_mode} mode, managed by Terraform"
  overwrite_on_create = true

  # The provider refreshes commit_message from the branch head, not from the
  # commit that last touched this file. Several files share one branch, so
  # whichever committed last wins and every other file resource reports drift
  # on every plan, forever. The content is what matters and is compared
  # normally; the message is cosmetic.
  lifecycle {
    ignore_changes = [commit_message]
  }
}

resource "azuredevops_build_definition" "pipeline" {
  for_each = var.pipelines

  project_id = data.azuredevops_project.poc.id
  name       = "${var.name_prefix}-${each.key}"

  repository {
    repo_type   = "TfsGit"
    repo_id     = azuredevops_git_repository.zsp.id
    branch_name = "refs/heads/main"
    yml_path    = azuredevops_git_repository_file.pipeline[each.key].file
  }

  # Runs are triggered deliberately, one phase at a time.
  features {
    skip_first_run = true
  }

  depends_on = [azuredevops_git_repository_file.script]
}

# Each connection is authorised for its own pipeline only. Omitting pipeline_id
# would authorise every pipeline in the project, which is what the earlier POC
# did and precisely what this design avoids.
resource "azuredevops_pipeline_authorization" "pipeline" {
  for_each = var.pipelines

  project_id  = data.azuredevops_project.poc.id
  resource_id = azuredevops_serviceendpoint_azurerm.pipeline[each.key].id
  type        = "endpoint"
  pipeline_id = azuredevops_build_definition.pipeline[each.key].id
}
