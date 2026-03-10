```bash
# Terraform configuration for Vault JWT authentication with Azure DevOps pipelines
# Variables
variable "azure_tenant_id" {
  description = "Azure tenant ID"
  type        = string
}

variable "managed_identity_client_id" {
  description = "Managed identity client ID"
  type        = string
}

variable "managed_identity_principal_id" {
  description = "Managed identity principal (object) ID"
  type        = string
}

# Step 1: Enable and configure JWT auth method
resource "vault_jwt_auth_backend" "azdo" {
  description         = "Azure DevOps JWT Authentication"
  path                = "jwt"
  type                = "jwt"
  oidc_discovery_url  = "https://login.microsoftonline.com/${var.azure_tenant_id}/v2.0"
  bound_issuer        = "https://sts.windows.net/${var.azure_tenant_id}/"
}

# Step 2: Create policy for reading secrets
resource "vault_policy" "dev_secrets_reader" {
  name = "dev-secrets-reader"

  policy = <<EOT
    path "secret/data/dev/*" {
      capabilities = ["read", "list"]
    }

    path "secret/metadata/dev/*" {
      capabilities = ["list"]
    }
  EOT
}

# Step 2: Create JWT role for Azure DevOps pipelines
resource "vault_jwt_auth_backend_role" "azdo_pipelines" {
  backend         = vault_jwt_auth_backend.azdo.path
  role_name       = "azdo-pipelines"
  token_policies  = [vault_policy.dev_secrets_reader.name]
  
  role_type            = "jwt"
  bound_audiences      = ["https://management.core.windows.net/"]
  user_claim           = "sub"
  bound_claims         = {
    sub   = var.managed_identity_principal_id
    appid = var.managed_identity_client_id
    tid   = var.azure_tenant_id
  }
  claim_mappings       = {
    oid   = "managed_identity_oid"
    appid = "managed_identity_client_id"
    tid   = "tenant_id"
  }
  token_ttl            = 3600
}

# Step 3: Enable KV v2 secrets engine
resource "vault_mount" "secret" {
  path        = "secret"
  type        = "kv-v2"
  description = "KV v2 secrets engine"
}

# Step 3: Create dev secrets
resource "vault_kv_secret_v2" "dev_app_config" {
  mount               = vault_mount.secret.path
  name                = "dev/app-config"
  cas                 = 1
  delete_all_versions = true
  
  data_json = jsonencode({
    database_url = "postgresql://dev-db:5432/myapp"
    api_key      = "dev-api-key-12345"
    environment  = "development"
  })
}

# Outputs
output "jwt_auth_path" {
  description = "Path where JWT auth is mounted"
  value       = vault_jwt_auth_backend.azdo.path
}

output "jwt_role_name" {
  description = "Name of the JWT role for pipelines"
  value       = vault_jwt_auth_backend_role.azdo_pipelines.role_name
}
```

***To apply this Terraform configuration:**

```bash
# Initialize Terraform
terraform init

# Set variables
export TF_VAR_azure_tenant_id="your-tenant-id"
export TF_VAR_managed_identity_client_id="your-mi-client-id"
export TF_VAR_managed_identity_principal_id="your-mi-principal-id"

# Review changes
terraform plan

# Apply configuration
terraform apply