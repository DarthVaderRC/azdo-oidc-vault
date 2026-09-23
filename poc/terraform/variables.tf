variable "pipeline_mode" {
  description = <<-EOT
    Which build phase to apply. Also selects what the pipelines do.
      inspect  Azure and Azure DevOps only. Pipelines print their token claims.
      auth     Adds Vault authentication. Pipelines log in and revoke.
      full     Adds AWS dynamic credentials. Pipelines run the whole flow.

    Defaults to full. The earlier default of inspect meant a bare apply
    silently destroyed the Vault and AWS resources and rewrote both pipelines
    down to claim printing, which is not what anyone wants by accident.
  EOT
  type        = string
  default     = "full"

  validation {
    condition     = contains(["inspect", "auth", "full"], var.pipeline_mode)
    error_message = "pipeline_mode must be inspect, auth or full."
  }
}

variable "token_method" {
  description = <<-EOT
    How the pipeline obtains its Entra-issued ID token.
      azurecli  AzureCLI@2 with addSpnToEnvironment. The default. Requires
                grant_identity_reader, because the task selects a subscription.
      rest      The OidcToken REST API. Needs no Azure permission at all, at
                the cost of a condition:false task to declare the connection.
      both      Renders both, the Azure CLI one with continueOnError, to
                compare them in one run. Diagnostic only.

    Phase 1 measured both against the live tenant and they return the *same
    token*: byte-identical payloads with the same uti. AzureCLI@2 fetches it
    from the same OidcToken endpoint, using the same System.AccessToken, and
    then additionally signs in to Azure. So this choice is about which
    failure mode and which privilege you prefer, not about the token.
  EOT
  type        = string
  default     = "azurecli"

  validation {
    condition     = contains(["both", "azurecli", "rest"], var.token_method)
    error_message = "token_method must be both, azurecli or rest."
  }
}

variable "grant_identity_reader" {
  description = <<-EOT
    Grant the managed identity Reader on the POC resource group. Required by
    token_method = "azurecli" and by nothing else: that task selects a
    subscription, which fails for an identity with no assignment anywhere in
    it. Set false alongside token_method = "rest", where the identity needs
    no Azure permission at all and acceptance test 8 reports "none".

    True by default because azurecli is the default. This is the one standing
    privilege in the build, and it is deliberate rather than accidental:
    Reader, on a resource group containing only the identity itself, with no
    data-plane permission anywhere. Be ready to say that out loud, because it
    is the obvious question to ask of a zero standing privileges demo.
  EOT
  type        = bool
  default     = true
}

variable "demo_narration" {
  description = <<-EOT
    Sets DEMO=1 in the pipeline, which turns on the commentary that makes the
    mechanism visible during a live walkthrough: the token's claims, the API
    path before each call, the two subjects side by side on the negative test,
    the token's remaining uses, and how many seconds the AWS credential
    existed for.

    It prints no token and no key. Acceptance test 7 is re-run over the
    verbose logs precisely because more output means more chance of leaking
    something.
  EOT
  type        = bool
  default     = true
}

variable "pipelines" {
  description = <<-EOT
    The pipelines to create. One Azure DevOps service connection, one federated
    credential, one Vault role, one Vault policy and one AWS role per entry.
    negative_role names another pipeline's Vault role that this pipeline must
    be refused by; null disables that check.
  EOT
  type = map(object({
    negative_role = optional(string)
  }))
  default = {
    pipeline-a = {}
    pipeline-b = { negative_role = "pipeline-a" }
  }

  # negative_role names a key of this map, not a Vault role name. The role
  # name is composed from name_prefix where it is used, so the prefix appears
  # in no default anywhere. A key that does not exist used to fall through
  # lookup() to an empty string, which rendered a pipeline pointed at a role
  # that does not exist, and the pipeline script treated the resulting 404 as
  # a pass: the negative test would report success having proved nothing.
  validation {
    condition = alltrue([
      for k, v in var.pipelines :
      v.negative_role == null || contains(keys(var.pipelines), v.negative_role)
    ])
    error_message = "Each negative_role must name another entry in the pipelines map, for example \"pipeline-a\"."
  }
}

variable "expected_tenant_id" {
  description = <<-EOT
    Entra tenant the subscription must belong to. Optional, and worth setting
    once you know yours: it catches the wrong az login before anything is
    created. Unset disables the check.
  EOT
  type        = string
  default     = null
}

variable "location" {
  description = "Azure region for the resource group and managed identity."
  type        = string
  default     = "eastus"
}

variable "aws_region" {
  description = "AWS region for the secrets engine and the pipeline's AWS calls."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for every object this configuration creates."
  type        = string
  default     = "zsp"
}

variable "resource_group_name" {
  description = "Resource group to create for the POC."
  type        = string
  default     = "rg-zsp-poc"
}

variable "managed_identity_name" {
  description = "User-assigned managed identity shared by all service connections."
  type        = string
  default     = "mi-zsp-poc"
}

variable "azdo_project_name" {
  description = <<-EOT
    Existing Azure DevOps project. Read, never created. The organisation it
    belongs to comes from AZDO_ORG_SERVICE_URL, not from here.

    Required: set it in terraform.tfvars.
  EOT
  type        = string
}

variable "azdo_repo_name" {
  description = "Azure Repos repository to create for the pipeline files."
  type        = string
  default     = "zsp-poc"
}

variable "vault_addr" {
  description = <<-EOT
    Vault cluster address. The provider reads this from VAULT_ADDR, but the
    pipeline YAML needs it as a literal, and Terraform cannot read environment
    variables. Keep it identical to VAULT_ADDR.

    Required: set it in terraform.tfvars.
  EOT
  type        = string

  validation {
    condition     = can(regex("^https://[^/]+$", var.vault_addr))
    error_message = "vault_addr must be an https URL with host and port only: no path and no trailing slash. The pipeline concatenates /v1/... onto it."
  }
}

variable "vault_parent_namespace" {
  description = "Namespace the provider is configured with, from VAULT_NAMESPACE. The POC namespace is created beneath it."
  type        = string
  default     = "admin"
}

variable "vault_namespace_path" {
  description = "Child namespace under the provider's namespace, which is admin."
  type        = string
  default     = "zsp-poc"
}

variable "vault_jwt_path" {
  description = "Mount path for the JWT auth method."
  type        = string
  default     = "azdo-jwt"
}

variable "vault_aws_path" {
  description = "Mount path for the AWS secrets engine."
  type        = string
  default     = "aws"
}

variable "vault_user_claim" {
  description = <<-EOT
    Claim that becomes the Vault entity alias. Both tid and iss resolve every
    pipeline to one entity while bound_claims still authorises each pipeline
    separately, and claim_mappings keeps full per-pipeline attribution in the
    audit record. Fall back to iss if the token carries no tid claim.
  EOT
  type        = string
  default     = "tid"

  validation {
    condition     = contains(["tid", "iss", "sub"], var.vault_user_claim)
    error_message = "vault_user_claim must be tid, iss or sub."
  }
}

variable "vault_bound_audience" {
  description = <<-EOT
    Audience Vault requires on the incoming token. Measured, not assumed.

    This is the application ID of the Azure Token Exchange Endpoint, the same
    resource that api://AzureADTokenExchange names. The identifier URI is what
    the federated identity credential is configured with and what the
    documentation shows; the application ID is what an Entra v2.0 token
    actually carries in aud. Same resource, two spellings.

    The distinction matters because Vault compares the literal string. A role
    bound to api://AzureADTokenExchange rejects every one of these tokens, and
    the error says only that the audience does not match, which sends you
    looking at the federated credential rather than at the token.

    It is a fixed Microsoft value either way, so it provides no tenant
    isolation. That comes from bound_issuer, which is tenant-specific, and
    from bound_claims.sub.
  EOT
  type        = string
  default     = "fb60f99c-7a34-4190-8149-302f77469936"
}

variable "vault_token_ttl" {
  description = "Vault token lifetime in seconds. The backstop if a run is cancelled before it can revoke."
  type        = number
  default     = 300
}

variable "aws_lease_ttl" {
  description = "Lifetime of the dynamic AWS credential in seconds."
  type        = number
  default     = 900
}

variable "iam_user_path" {
  description = <<-EOT
    IAM path for users Vault creates. Root works everywhere, which is why it
    is the default.

    It must stay "/" in a HashiCorp individual sandbox: the DemoUserCreate
    policy permits iam:CreateUser only on
    arn:aws:iam::<account>:user/demo-<SourceIdentity>*, an ARN with no path
    segment, so any path other than root fails to match and the call is denied.
    Isolation comes from the name prefix and the permissions boundary instead.
    In an unconstrained account, "/vault-zsp/" groups the dynamic users.
  EOT
  type        = string
  default     = "/"
}

# ---------------------------------------------------------------------------
# HashiCorp individual sandbox constraints.
#
# The account denies iam:CreateUser except through one carve-out, which
# requires both of the following. Neither is optional and neither can be
# worked around by granting more permissions, because the boundary condition
# is evaluated on the CreateUser call itself.
# ---------------------------------------------------------------------------

variable "aws_user_prefix" {
  description = <<-EOT
    Prefix for every IAM user this configuration creates, directly or through
    Vault. Vault's dynamic users are created by the root user rather than by
    Terraform, so they inherit this prefix plus "-vault-root-<random>".

    In a HashiCorp individual sandbox this must be "demo-" followed by the
    caller's aws:SourceIdentity, because the boundary's CreateChildUser
    statement restricts the root user to arn:aws:iam::<account>:user/$${aws:username}*
    and CreateUser itself is permitted only on user/demo-<SourceIdentity>*.
    In an unconstrained account it is just a naming convention.

    Required: set it in terraform.tfvars.
  EOT
  type        = string

  # IAM caps user names at 64 characters. Vault's username_template appends
  # "-vault-root-" and a random suffix whose length locals.tf computes from
  # this value, and that arithmetic can go negative without a guard here. The
  # failure would surface when a pipeline asks for a credential, with an error
  # that names neither the template nor this variable.
  validation {
    condition     = 64 - length("${var.aws_user_prefix}-vault-root") - 1 >= 8
    error_message = "aws_user_prefix is too long. It must leave room for \"-vault-root-\" and at least 8 random characters inside IAM's 64-character limit, so at most 44 characters."
  }
}

variable "aws_permissions_boundary" {
  description = <<-EOT
    Permissions boundary every IAM user must carry, or null for an account
    that does not require one.

    Where it is required, as in a HashiCorp individual sandbox, the CreateUser
    allow is conditioned on iam:PermissionsBoundary equalling this exact ARN,
    so it applies to the root user Terraform creates and to every dynamic user
    Vault creates. The boundary caps effective permissions, which is why the
    pipeline's work step must stay inside the actions it permits.
  EOT
  type        = string
  default     = null

  # null omits the argument on all three resources that take it. An empty
  # string does not: AWS rejects it, and the error names the IAM user rather
  # than this variable, which sends you looking in the wrong place.
  validation {
    condition = (
      var.aws_permissions_boundary == null ||
      can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:policy/", var.aws_permissions_boundary))
    )
    error_message = "aws_permissions_boundary must be an IAM policy ARN, or left unset where no boundary is required. An empty string is not the same as unset and AWS rejects it."
  }
}

# ---------------------------------------------------------------------------
# HCP identifiers, needed only for audit log streaming.
#
# The sandbox permissions boundary scopes the CloudWatch actions to
#   arn:aws:logs:*:<account>:log-group:hashicorp/${aws:PrincipalTag/hcp-org-id}/${aws:PrincipalTag/hcp-project-id}
# so the audit user must carry tags matching the log group HCP writes to.
# Untagged, the tag variables resolve to nothing, the ARN never matches, and
# every write is denied. HCP reports streaming as enabled either way and the
# log group is simply never created, so this fails silently and looks like a
# delay rather than an error.
#
# Both values are visible in the log group path on the HCP audit log page:
#   hashicorp/<hcp-org-id>/<hcp-project-id>
# ---------------------------------------------------------------------------

variable "hcp_org_id" {
  description = "HCP organisation ID, the first UUID in the audit log group path. Null where the audit user needs no tags."
  type        = string
  default     = null
}

variable "hcp_project_id" {
  description = "HCP project ID, the second UUID in the audit log group path. Null where the audit user needs no tags."
  type        = string
  default     = null
}
