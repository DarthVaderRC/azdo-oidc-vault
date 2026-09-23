# Provider blocks carry no authentication arguments. Every provider reads its
# credentials from the environment, which is what allows this workspace to be
# switched from local to remote execution without touching the code.
#
#   azurerm      az login, plus ARM_SUBSCRIPTION_ID
#   azuredevops  AZDO_ORG_SERVICE_URL, AZDO_PERSONAL_ACCESS_TOKEN
#   vault        VAULT_ADDR, VAULT_TOKEN, VAULT_NAMESPACE=admin
#   aws          AWS_PROFILE, AWS_REGION
#
# All four are needed from the first apply, because Terraform configures every
# provider referenced in the configuration even when a phase creates none of
# its resources.

provider "azurerm" {
  features {}
}

provider "azuredevops" {}

provider "vault" {}

provider "aws" {}
