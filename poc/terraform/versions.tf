terraform {
  required_version = ">= 1.9.0"

  # Where state lives is deliberately not in this file. Without one, Terraform
  # keeps state locally and a fresh clone runs with no account anywhere. To
  # store it in HCP Terraform as we did, copy backend.tf.example to backend.tf
  # and set TF_CLOUD_ORGANIZATION. backend.tf is gitignored.

  required_providers {
    azuredevops = {
      source  = "microsoft/azuredevops"
      version = "~> 1.16"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.6"
    }
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.12"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.65"
    }
  }
}
