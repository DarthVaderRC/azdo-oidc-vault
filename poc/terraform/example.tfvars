# Copy to terraform.tfvars and fill in:
#
#   cp example.tfvars terraform.tfvars
#
# terraform.tfvars is gitignored and auto-loaded, so every command in the
# README works without -var-file. This file is not auto-loaded, so it can
# never be picked up by accident.

# ---------------------------------------------------------------------------
# Required. Terraform refuses to plan without these three.
# ---------------------------------------------------------------------------

# Your Vault cluster. Host and port only: no path, no trailing slash. Keep it
# identical to VAULT_ADDR in your shell, which is what the provider reads.
vault_addr = "https://your-cluster.hashicorp.cloud:8200"

# An Azure DevOps project that already exists. This configuration reads it and
# never creates it. The organisation comes from AZDO_ORG_SERVICE_URL.
azdo_project_name = "Your-Project"

# Prefix for every IAM user, including the dynamic ones Vault creates, which
# become <prefix>-vault-root-<random>. At most 44 characters, or the random
# suffix has no room inside IAM's 64-character limit.
#
# In a HashiCorp individual sandbox this MUST be "demo-" followed by your
# aws:SourceIdentity, or iam:CreateUser is denied outright. Elsewhere it is
# only a naming convention.
aws_user_prefix = "demo-you@example.com"

# ---------------------------------------------------------------------------
# Optional. Leave unset unless the note says otherwise.
# ---------------------------------------------------------------------------

# Worth setting once you know your tenant: it catches the wrong az login
# before anything is created. Unset disables the check.
# expected_tenant_id = "00000000-0000-0000-0000-000000000000"

# Only where every IAM user must carry a permissions boundary, as in a
# HashiCorp individual sandbox. Leave unset in an unconstrained account: an
# empty string is not the same as unset, and AWS rejects it.
# aws_permissions_boundary = "arn:aws:iam::000000000000:policy/YourBoundary"

# Only for HCP Vault audit log streaming to CloudWatch, and only where the
# account's boundary scopes log group ARNs by principal tag. Both UUIDs are
# visible in the log group path on the HCP audit page:
#   hashicorp/<hcp-org-id>/<hcp-project-id>
# Without them every write is denied while HCP still reports streaming as
# healthy, so the symptom is a log group that never appears.
# hcp_org_id     = "00000000-0000-0000-0000-000000000000"
# hcp_project_id = "00000000-0000-0000-0000-000000000000"

# ---------------------------------------------------------------------------
# Defaults you may want to change, shown with their current values.
# ---------------------------------------------------------------------------

# name_prefix           = "zsp"
# location              = "eastus"
# aws_region            = "us-east-1"
# resource_group_name   = "rg-zsp-poc"
# managed_identity_name = "mi-zsp-poc"
# azdo_repo_name        = "zsp-poc"
# vault_namespace_path  = "zsp-poc"

# "/vault-zsp/" groups Vault's dynamic users in an unconstrained account. It
# must stay "/" in a HashiCorp individual sandbox, where CreateUser is
# permitted only on an ARN with no path segment.
# iam_user_path = "/"

# "rest" needs no Azure role assignment at all, at the cost of a condition:false
# task to declare the service connection. Set grant_identity_reader = false
# alongside it.
# token_method          = "azurecli"
# grant_identity_reader = true
