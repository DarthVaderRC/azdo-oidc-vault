data "azurerm_subscription" "current" {}

# Catches being logged in to the wrong tenant before anything is created.
# Skipped when expected_tenant_id is unset, so a fresh clone is not warned at
# on every plan about a tenant whose owner has not told us yet.
check "tenant_is_expected" {
  assert {
    condition = (
      var.expected_tenant_id == null ||
      data.azurerm_subscription.current.tenant_id == var.expected_tenant_id
    )
    error_message = "az login is pointed at tenant ${data.azurerm_subscription.current.tenant_id}, but expected_tenant_id is ${coalesce(var.expected_tenant_id, "unset")}. Correct the login, or unset expected_tenant_id to disable this check."
  }
}

# Non-blocking. token_method = "azurecli" without the grant fails at run time
# rather than at apply time, with an error that names the subscription and not
# the cause, so warn here instead of leaving it to be rediscovered.
# "both" is exempt: there the Azure CLI task carries continueOnError and is
# expected to fail, which is the comparison phase 1 exists to produce.
check "azurecli_needs_reader" {
  assert {
    condition     = var.token_method != "azurecli" || var.grant_identity_reader
    error_message = "token_method is azurecli but grant_identity_reader is false. The AzureCLI@2 task will fail at 'az account set' because the identity has no role assignment in the subscription. Set grant_identity_reader = true, or use token_method = rest."
  }
}

resource "azurerm_resource_group" "zsp" {
  name     = var.resource_group_name
  location = var.location
}

# One identity shared by every service connection. This is deliberate: it
# mirrors how teams actually work, and proves that the Entra-issued token still
# distinguishes connections that share an identity. The access-token approach
# the earlier POC used cannot.
#
# By default it holds no Azure role assignment. It exists only to anchor
# federated credentials, so it is an authentication anchor rather than a
# standing privilege. Acceptance test 8 checks this.
resource "azurerm_user_assigned_identity" "zsp" {
  name                = var.managed_identity_name
  location            = azurerm_resource_group.zsp.location
  resource_group_name = azurerm_resource_group.zsp.name
}

# The one concession the AzureCLI@2 token method requires, and the reason the
# REST method exists as an alternative.
#
# AzureCLI@2 runs "az login" and then "az account set --subscription". The
# second call fails unless the identity holds a role assignment somewhere
# within that subscription, because a subscription the principal has no
# assignment in does not appear in the account list at all. Phase 1 measured
# this: "The subscription of '...' doesn't exist in cloud 'AzureCloud'".
#
# Scoped to the resource group rather than the subscription, which is the
# narrowest grant that satisfies the check. The group holds nothing but the
# identity itself, and Reader carries no data-plane permission, so this is
# close to the smallest standing privilege Azure can express. It is still a
# standing privilege, and it is still the thing this POC argues against, which
# is why it is opt-in and off by default.
resource "azurerm_role_assignment" "identity_reader" {
  count = var.grant_identity_reader ? 1 : 0

  scope                = azurerm_resource_group.zsp.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.zsp.principal_id
  principal_type       = "ServicePrincipal"
}

# Each federated credential trusts one service connection, identified by the
# subject Azure DevOps generates for it.
#
# Azure does not support concurrent writes of federated credentials on one
# managed identity, so apply with -parallelism=1. See poc/README.md.
resource "azurerm_federated_identity_credential" "pipeline" {
  for_each = var.pipelines

  name                      = "fic-${var.name_prefix}-${each.key}"
  user_assigned_identity_id = azurerm_user_assigned_identity.zsp.id
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = azuredevops_serviceendpoint_azurerm.pipeline[each.key].workload_identity_federation_issuer
  subject                   = azuredevops_serviceendpoint_azurerm.pipeline[each.key].workload_identity_federation_subject
}
