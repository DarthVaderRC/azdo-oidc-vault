# Advanced configuration and hardening

Steps 1 to 5 build the integration for one or two pipelines. This document is the set of decisions you revisit once it is real: what the token can and cannot be made to enforce, how to separate environments, what changes at twenty pipelines, and how to harden the AWS secrets engine in an account that fights you.

For symptoms and their causes, go to [COMMON_PITFALLS.md](../COMMON_PITFALLS.md) instead. This file does not repeat it.

> **Provenance.** An earlier version of this document stated that binding a Vault role to a specific service connection was not possible, and recommended one managed identity per environment as the finest grain available. That was wrong, and the evidence was already on the page: the `sub` claim it quoted *is* the service connection. Corrected on 23 September 2026 against a tested build. The measurements are in [DESIGN_REVIEW.md](../DESIGN_REVIEW.md).

## What the token can and cannot express

This is the section to read before you promise anything to a security reviewer.

**In the token, and therefore enforceable by Vault:**

| Claim | What it identifies |
|---|---|
| `sub` | The **service connection**. One connection is one pipeline, provided you authorise pipelines to connections individually |
| `tid` | The Entra tenant |
| `iss` | `https://login.microsoftonline.com/<tenant>/v2.0` |
| `aud` | `fb60f99c-7a34-4190-8149-302f77469936`, the Azure Token Exchange Endpoint's application ID |

**Not in the token, at all:**

- Repository, branch, pipeline definition ID, run ID, or the identity of whoever triggered the run.
- The managed identity behind the connection. The `/a/` segment is the Azure DevOps first-party application `499b84ac-1321-427f-aa17-267ca6975798`, which is the same value in every organisation.

Measured against a live tenant: two pipelines sharing one managed identity produce different subjects, and a role bound to one of them refuses the other with HTTP 400 and `claim "sub" does not match`. That refusal is an acceptance test, not a claim. See [STEP_4_TESTING.md](STEP_4_TESTING.md).

### Where each control actually lives

A reviewer who believes Vault is checking the branch will be unpleasantly surprised. Be explicit about which system enforces what, and when.

| Control | Enforced by | When |
|---|---|---|
| Which pipeline may use this connection | Azure DevOps, connection Security page | Before the token is minted |
| Which branches may use this connection | Azure DevOps, **branch control check** | Before the token is minted |
| That your steps run first | Azure DevOps, **required template check** | Before the token is minted |
| Which Vault role this token satisfies | Vault, `bound_claims.sub` | At login |
| What the Vault token may read | Vault policy | On every request |
| What the AWS credential may do | Vault AWS role `policy_document`, intersected with the permissions boundary | On every AWS call |
| How long the credential lives | The job's `EXIT` trap, with the lease TTL as backstop | At job end, or at TTL |

The three Azure DevOps checks are evaluated before Entra is ever asked for a token, so a run from the wrong branch never reaches Vault at all. That is a different and earlier enforcement point than a bound claim, and it is worth saying so plainly rather than implying Vault is doing it.

## Separating environments

Separate managed identities per environment still make sense, but for **blast radius in Azure**, not for identity in Vault. A production identity that nothing else shares cannot be handed a federated credential by someone whose access stops at the development resource group.

The Vault role should still bind the subject, never the identity. Bind the identity and every pipeline behind it gets the same access, which is the problem this design exists to solve.

```bash
# The subject of the production pipeline's own service connection, not the
# managed identity's principal ID.
SUB_PROD_DEPLOY="/eid1/c/pub/t/<tenant>/a/<azdo-app>/sc/<organisation>/<connection-id>"

vault write auth/azdo-jwt/role/prod-deploy \
    role_type="jwt" \
    policies="prod-deploy" \
    bound_audiences="fb60f99c-7a34-4190-8149-302f77469936" \
    bound_claims="sub=${SUB_PROD_DEPLOY}" \
    user_claim="tid" \
    claim_mappings="sub=pipeline_subject" \
    token_ttl="5m" \
    token_num_uses=2
```

The six decisions inside that role are explained once, in [STEP_2_VAULT_SETUP.md](STEP_2_VAULT_SETUP.md) §2.3. Vault Enterprise namespaces give you a stronger version of the same separation: a `prod` namespace whose operators are not the `dev` namespace's operators.

## What changes at twenty pipelines

**The federated credential cap is 20 per identity, and it cannot be raised**, not even by a support request. Twenty pipelines per managed identity; create another identity for the next twenty. Flexible federated identity credentials, which would let one credential cover a wildcard subject, support GitHub, GitLab and Terraform Cloud only, on app registrations only, and are in preview. Azure DevOps is not a supported issuer, and `claimsMatchingExpression` is mutually exclusive with `subject`.

This is a packaging constraint, not a security one. Each connection still gets its own subject and its own Vault role whichever identity it sits behind.

**Generate the roles rather than writing them.** Twenty pipelines is twenty subjects, twenty policies, twenty federated credentials and twenty roles. [STEP_5_PRODUCTION.md](STEP_5_PRODUCTION.md) §5.2 has the `for_each` form, and [`terraform/vault.tf`](../../terraform/vault.tf) is the version that runs.

**Apply with `-parallelism=1`.** Azure rejects concurrent writes of federated identity credentials on a single managed identity, and this configuration puts several on one.

## Choosing the token method

Both methods return the same token. Measured: byte-identical payloads, same `uti`. The difference is what each one costs you, and it is a production decision worth making once for the whole organisation.

| | `AzureCLI@2` | OidcToken REST API |
|---|---|---|
| Azure permission needed | **Reader somewhere in the subscription** | None at all |
| Why | The task runs `az account set`, and a subscription the identity holds no assignment in is invisible to it | It only asks Azure DevOps for a token |
| Cost | One standing privilege, however small | A `condition: false` task to declare the connection |

If zero standing privileges is the claim you are making, the REST method is the one that is literally true: the managed identity holds no role assignment anywhere. Both were proven end to end, builds 94 to 96, and [VALIDATION.md](../VALIDATION.md) records which build proved which. The mechanics of both are in [STEP_1_AZURE_SETUP.md](STEP_1_AZURE_SETUP.md) §1.5 and [STEP_3_PIPELINE_INTEGRATION.md](STEP_3_PIPELINE_INTEGRATION.md) §3.2.

## Hardening the AWS secrets engine

[STEP_2_VAULT_SETUP.md](STEP_2_VAULT_SETUP.md) §2.5 sets it up. Three settings decide whether it holds up in a real account.

**`credential_type` must be `iam_user`.** It is the only type Vault can revoke before it expires. `assumed_role` and `federation_token` return STS credentials that stay valid until their own expiry regardless of what you do in Vault, so "the credential is dead the moment the job ends" quietly becomes "the credential is dead within the hour". If that sentence is in your design document, this setting is where it is won or lost.

**`username_template`, on the mount.** Vault puts username generation on the mount, not the role. The default produces `vault-token-...` names, and any account that conditions `iam:CreateUser` on a name prefix denies every one of them. Compute the random suffix length so the result cannot exceed IAM's 64-character limit:

```hcl
username_template = "{{ printf \"${local.aws_root_user_name}-%s\" (random ${local.aws_username_suffix_len}) | truncate 64 }}"
```

**`permissions_boundary_arn`, on the role.** Some accounts deny `iam:CreateUser` unless the new user carries an exact boundary. Remember what a boundary does: the dynamic user's effective permission is its Vault-granted policy **intersected** with the boundary, so an action outside the boundary is silently useless however you write the role's `policy_document`. That is a good property and a confusing one the first time a grant appears to do nothing.

Both missing settings produce the identical symptom: `AccessDenied` on `CreateUser`, reported by Vault, at the moment a pipeline asks for a credential.

**Set a lease ceiling.** `default_lease_ttl` and `max_lease_ttl` on the mount are the backstop for the case the whole design depends on and cannot control: a job that dies before its `EXIT` trap runs. The trap is the fast path, not the only one.

```bash
vault write sys/mounts/aws/tune default_lease_ttl=5m max_lease_ttl=5m
```

**Do not grant the root credential more than the `iam_user` type needs.** Scope its resource ARN to the usernames the template will generate, rather than `*`. See [`terraform/aws.tf`](../../terraform/aws.tf).

## Revoke, never renew

Renewal keeps a credential alive. That is the opposite of the goal here, and any guidance suggesting you renew for long-running jobs is guidance for a different design.

The job revokes its own Vault token from an `EXIT` trap, so it runs on success and on failure alike. Revoking the token revokes every lease it created, and for an `iam_user` credential that deletes the IAM user. One call:

```bash
trap 'curl -sS -X POST -H "X-Vault-Token: ${VAULT_TOKEN}" \
  "${VAULT_ADDR}/v1/auth/token/revoke-self" >/dev/null' EXIT
```

Three settings make that work, and each fails at the end of the job where nobody is watching:

- **`token_no_default_policy` must stay `false`.** `auth/token/revoke-self` is granted by the default policy. Turn it on and every credential lives its full TTL.
- **`token_num_uses` must be counted, not guessed.** Login does not consume a use. One credential read and one `revoke-self` is two. A token that runs out mid-job fails at the revoke.
- **Never retry the credential read.** A token that exhausts its uses is revoked, and revoking it revokes its leases, which deletes the AWS credential the task is about to use.

The working version is [`pipelines/vault-zsp.sh`](../../pipelines/vault-zsp.sh).

## Attribution and monitoring

`user_claim="tid"` resolves every pipeline in the tenant to one Vault entity, which keeps the client count flat. Attribution does not suffer, because `claim_mappings` writes the full subject into the token metadata on every login. Those are two separate knobs and conflating them is what produces roles that are deliberately too broad.

**Read attribution from Vault's audit log, not the build log.** Azure DevOps masks a connection's own issuer and subject as `***` in its own output. That is a display filter rather than redaction, and it means the build log cannot tell you which connection authenticated. The audit record carries the `pipeline_subject` you mapped, which is the account that matters after an incident.

**Monitor leases, not entities.** The signal worth alerting on is a credential that reached its TTL instead of being revoked: it means a trap is missing somewhere, or a job is dying in a way you have not seen. [STEP_5_PRODUCTION.md](STEP_5_PRODUCTION.md) §5.4 has the queries.

```bash
# Failed logins, by pipeline, from an audit log file device
jq 'select(.error != null and (.request.path | endswith("/login")))
    | [.time, .request.remote_address, .error] | @csv' -r /vault/logs/audit.log
```

## Keeping credentials out of the logs

`issecret=true` masks one exact string. Anything derived from the secret, split, re-encoded or concatenated, prints unmasked. The safest version of this rule is that the credential never leaves the one task that holds it, which is why [`pipelines/vault-zsp.sh`](../../pipelines/vault-zsp.sh) does everything in a single task and never writes a pipeline variable.

```yaml
# Masked
echo "##vso[task.setvariable variable=SECRET;issecret=true]${SECRET_VALUE}"

# Not masked, and permanently in that run's log
echo "##vso[task.setvariable variable=SECRET]${SECRET_VALUE}"
```

Never set `isOutput=true` on a secret: it crosses job boundaries, and a value that crosses a boundary is a value you have stopped tracking.

## Network

1. **HTTPS only.** Never an unencrypted Vault address.
2. **Restrict inbound access** to the cluster with the controls your platform offers.
3. **Consider private endpoints** for production, so the cluster is not reachable from the internet at all. Note that Microsoft-hosted agents cannot reach a private endpoint, so this decision and the decision to use self-hosted agents are the same decision.
4. **`token_bound_cidrs` is worth less than it looks** for Microsoft-hosted agents: their ranges are large, shared across tenants and published as a changing list. It is worth real money for self-hosted agents on known egress addresses.

## Next steps

- [STEP_4_TESTING.md](STEP_4_TESTING.md) for the acceptance tests, including the four that fail without failing anything.
- [COMMON_PITFALLS.md](../COMMON_PITFALLS.md) for symptoms and causes.
- [DESIGN_REVIEW.md](../DESIGN_REVIEW.md) for the reasoning, and the options rejected along the way.
