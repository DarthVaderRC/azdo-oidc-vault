# Step 5: Running this in production

> The configuration this page used to embed now lives in [`terraform/`](../../terraform/), where it is applied and tested rather than transcribed. What remains here is the part Terraform cannot decide for you: how to structure roles at scale, what to watch, and how to get there from where you are.

## 5.1 How to structure roles

One role per pipeline, each bound to that pipeline's service connection subject. There is no tier above it worth having, and the alternatives all collapse under inspection:

| Grouping | What it actually authorises |
|---|---|
| By business unit | Every pipeline in the unit, to everything the unit can reach |
| By environment | Every pipeline in that environment, including the ones added tomorrow |
| By managed identity | Every service connection behind that identity |
| By tenant (`tid` alone) | Every workload in your tenant: virtual machines, function apps, other teams |
| **By service connection (`sub`)** | **One pipeline** |

The grouped versions exist in older guidance because they were the only option once you had chosen an access token, which names the identity and nothing else. With the ID token, per-pipeline costs no more than per-environment: it is the same role definition with a different `bound_claims.sub`, generated in a loop.

What does not scale is doing it by hand. Twenty pipelines is twenty roles, twenty policies, twenty federated credentials, and the 20-per-identity cap means a twenty-first needs another managed identity. Generate them. That is what `terraform/` is for.

**Client count is not a design input.** Earlier guidance in this repository shaped roles to minimise Vault entities, and then recommended broad roles as the way to achieve it. That is backwards: entity count follows from `user_claim`, which is an independent setting. Set `user_claim = "tid"` and every pipeline in the tenant resolves to one entity no matter how many roles you have. Authorisation stays per-pipeline and attribution stays exact, because `claim_mappings` puts the full subject in every audit record. You are not choosing between granularity and licensing.

## 5.2 Roles, at scale

```hcl
# One role per pipeline, generated rather than written.
resource "vault_jwt_auth_backend_role" "pipeline" {
  for_each = var.pipelines

  backend   = vault_jwt_auth_backend.azdo.path
  role_name = each.key
  role_type = "jwt"

  bound_audiences = ["fb60f99c-7a34-4190-8149-302f77469936"]
  bound_claims    = { sub = each.value.service_connection_subject }

  user_claim     = "tid"
  claim_mappings = { sub = "pipeline_subject" }

  token_policies          = [vault_policy.pipeline[each.key].name]
  token_ttl               = "5m"
  token_max_ttl           = "5m"
  token_num_uses          = 2
  token_no_default_policy = false
}
```

See [`terraform/vault.tf`](../../terraform/vault.tf) for the version that runs, including the AWS secrets engine and the preconditions that stop a bad apply early.

## 5.3 What is worth restricting, and what is theatre

**Token TTL.** Minutes. The token exists to fetch a credential and hand it back. An hour is not a short-lived credential, it is a credential you have stopped thinking about.

**Token uses.** `token_num_uses = 2`: one read, one `revoke-self`. Count before you set it; login does not consume a use, and a token that runs out mid-job fails at the revoke, where nobody is looking.

**The default policy.** Leave it attached. `token_no_default_policy = true` removes `revoke-self`, which silently converts every credential into one that lives its full TTL.

**`token_bound_cidrs`** is worth less than it looks for Microsoft-hosted agents. Their address ranges are large, shared with other tenants, and published as a changing list, so pinning `20.0.0.0/8` tells you "some Azure host" and costs you an outage the day the list changes. It is worth real money for self-hosted agents on known egress addresses, where it is a genuine second factor.

**Branch and template restrictions** cannot come from Vault: the token contains no branch and no repository. They come from Azure DevOps, as checks on the service connection, evaluated before a token is minted:

- **Branch control**: the connection is usable only from named branches, optionally only when branch protection is on.
- **Required template**: the pipeline must extend a template you control, so your steps run first.
- **Per-pipeline authorisation**: never "grant access to all pipelines".

Say clearly which enforcement point does what. A reviewer who believes Vault is checking the branch will be unpleasantly surprised.

## 5.4 What to monitor

Not client count. Three things that indicate whether the design is holding:

**Credentials that outlive their job.** The one number that matters. If revocation is working, the gap between a lease being created and destroyed is tens of seconds. Alert on leases that reach their TTL instead of being revoked, since that means an `EXIT` trap is missing or a token ran out of uses.

```bash
# Dynamic IAM users that exist right now. In steady state this is empty
# between runs, and holds one entry per running job during them.
aws iam list-users --query "Users[?starts_with(UserName, 'vault-')].UserName"
```

**Refused logins.** A pipeline that offers a token to the wrong role, a subject that changed because a connection was recreated, or a token whose audience does not match. Each is a `permission denied` in the audit log with the role name attached.

**Requests by pipeline.** From `claim_mappings`, every audit record carries `pipeline_subject`. That answers "which pipeline read that secret", which is the question asked after an incident, and the one that matters most.

```bash
# HCP streams audit logs to your log destination. Filter on the mount, and
# read the subject from the token metadata.
jq 'select(.request.path | startswith("auth/azdo-jwt/login"))
    | {time, path: .request.path, sub: .auth.metadata.pipeline_subject, policies: .auth.policies}'
```

[`demo/watch-audit.sh`](../../demo/watch-audit.sh) and [`demo/watch-iam.sh`](../../demo/watch-iam.sh) are working versions of the first and third.

## 5.5 Getting there from a pipeline that has a stored secret

The order matters, because the last step is the only one that removes risk.

1. **One pipeline, non-critical.** Add the service connection, the federated credential, one role, one policy. Leave the existing secret in place and unused.
2. **Prove the negative.** Point that pipeline at another pipeline's role and confirm it is refused. If it succeeds, your `bound_claims` is not doing what you think, and everything after this is built on sand.
3. **Prove revocation.** After the job, confirm the credential no longer works. `InvalidClientTokenId` from AWS, or a `permission denied` from Vault.
4. **Widen to a team**, generating roles rather than writing them.
5. **Delete the stored secrets.** Until this happens you have added a mechanism, not removed a credential, and the old one is still the shortest path in for anyone who finds it.
6. **Remove the standing identities** the old design needed, including service principals created per pipeline, and any role assignment the new one does not require.

Step 5 is the one that gets skipped. Put a date on it.

## 5.6 When it does not work

| Symptom | Cause |
|---|---|
| `audience mismatch` on every login | Role bound to `api://AzureADTokenExchange` rather than the GUID the token carries |
| `claim "sub" does not match` | Subject copied with a prefix trimmed, or the service connection was recreated and its ID changed |
| Login succeeds, read denied | Policy path does not match the mount path, or KV v2 needs `secret/data/...` rather than `secret/...` |
| Revoke fails, everything else works | `token_no_default_policy` is true, or `token_num_uses` was exhausted before the revoke |
| `AccessDenied` on `CreateUser` from Vault | Missing `username_template` or `permissions_boundary_arn`, in an account that constrains IAM user creation |
| `There is no explicit reference to service connection` | Using the REST token method without the `condition: false` task that declares the connection |
| Pipeline queues forever, no error | No parallel job available in the organisation |

More in [COMMON_PITFALLS.md](../COMMON_PITFALLS.md).

## Next steps

[Step 4: Testing](STEP_4_TESTING.md) has the acceptance tests, including the two in 5.5 above that are worth running before you trust any of this.

[ADVANCED_CONFIG.md](ADVANCED_CONFIG.md) covers what changes past twenty pipelines: separating environments, choosing a token method for the whole organisation, hardening the AWS secrets engine, and exactly which system enforces which control.
