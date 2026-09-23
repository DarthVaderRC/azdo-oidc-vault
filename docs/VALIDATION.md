# Zero standing privileges POC

Azure DevOps pipelines authenticate to Vault with an Entra-issued ID token, receive an AWS credential that did not exist before the run, and destroy it before the run ends.

This is the build described in the [design review](../docs/DESIGN_REVIEW.md). That report explains why the earlier guidance in this repository did not demonstrate zero standing privileges; this one is built to prove it or fail visibly.

## What it demonstrates

| | Earlier POC | This build |
|---|---|---|
| Token | Entra access token, an Azure Resource Manager credential | Entra-issued ID token, not usable against Azure |
| Identity grain | The managed identity. Connections sharing one are indistinguishable | The service connection, so per pipeline |
| Secret | Static KV value, identical every run | AWS credential created on demand |
| After the run | Token valid for up to an hour, secret unchanged | Credential revoked and the IAM user deleted |

## Prerequisites

**Tooling:** Terraform, Azure CLI with the `azure-devops` extension, AWS CLI, Vault CLI, `jq`.

**Organisation prerequisites, both confirmed for this build.** Either can stall a fresh organisation for days, so re-check them if this is rebuilt elsewhere.

- The Azure DevOps organisation is connected to your Entra tenant, under Organization settings, Microsoft Entra. Without this the service connections cannot federate to the tenant at all.
- The organisation has at least one Microsoft-hosted parallel job, under Organization settings, Parallel jobs. New organisations often have none and the free grant is a request.

The project is set by `azdo_project_name` in `terraform.tfvars`, and the organisation comes from `AZDO_ORG_SERVICE_URL`. See [Configure](#configure) below.

## Authenticating

Four systems need credentials, and **all four from the very first apply**, because Terraform configures every provider in the configuration even during a phase that creates none of that provider's resources.

The approach below keeps every secret out of shell history, out of the repository and out of any file in cleartext. Two of the four have a CLI credential cache on disk and need nothing else. The other two have no cache, so they go in the macOS Keychain and in the Vault CLI's own token file.

**1. Azure.** An ordinary login. Writes `~/.azure`, which both the CLI and the azurerm provider read.

```bash
az login --tenant <your tenant id>
az account set --subscription <the POC subscription id>
```

**2. AWS.** A named profile, not exported variables. Exported credentials are visible only to the shell that set them, which silently breaks any other terminal or tool.


```bash
aws configure --profile zsp-poc
```

*If your organisation issues federated AWS access* rather than static keys, take the credentials from whatever tool it provides and write them into the profile. Prefer a tool that writes the profile directly: a two-step "print the exports, then `aws configure set`" has a silent failure mode where the print fails, the shell keeps its stale values, and `configure set` writes those back over the profile. The file's timestamp updates and every call still fails with `ExpiredToken`.

If your credentials are temporary (an `AWS_SESSION_TOKEN` is present) include it, and expect to refresh the profile when it expires:

```bash
aws configure set --profile zsp-poc aws_session_token "$AWS_SESSION_TOKEN"
```

```bash
aws configure set --profile zsp-poc aws_access_key_id "$AWS_ACCESS_KEY_ID" && aws configure set --profile zsp-poc aws_secret_access_key "$AWS_SECRET_ACCESS_KEY" && aws configure set --profile zsp-poc aws_session_token "$AWS_SESSION_TOKEN" && aws configure set --profile zsp-poc region us-east-1
```

**3. Vault.** Generate an admin token in the HCP portal, then log in. This writes `~/.vault-token`, which the Vault provider falls back to when `VAULT_TOKEN` is unset. HCP admin tokens expire after six hours.

```bash
vault login -namespace=admin
```

**4. Azure DevOps.** A personal access token with exactly these scopes: Project and Team (Read), Code (Read, write, and manage), Service Connections (Read, query, and manage), Build (Read and execute), Pipeline Resources (Use and manage). Set a short expiry and revoke it at teardown.

There is no CLI cache for a PAT, so put it in the Keychain. The `-w` flag prompts with the input hidden:

```bash
security add-generic-password -a "$USER" -s azdo-poc-pat -w
```

**5. State.** Terraform keeps state locally unless you tell it otherwise, and nothing here requires a backend. To store it in HCP Terraform as this build did, copy `terraform/backend.tf.example` to `terraform/backend.tf` (gitignored), run `terraform login`, set `TF_CLOUD_ORGANIZATION`, and set the workspace's execution mode to **Local**. The default is Remote, and a remote run receives neither `terraform.tfvars` nor the credentials above.

**Then one environment file**, `~/.zsp-poc.env`, sourced before every command. It holds no secret: the two secret values resolve at source time from the Keychain and the Vault token file.

```bash
export TF_CLOUD_ORGANIZATION=<your HCP Terraform organisation>
export ARM_SUBSCRIPTION_ID=<the POC subscription id>
export AZDO_ORG_SERVICE_URL=https://dev.azure.com/<your organisation>
export VAULT_ADDR=https://<your cluster>.hashicorp.cloud:8200
export VAULT_NAMESPACE=admin
export AWS_PROFILE=zsp-poc
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1

export AZDO_PERSONAL_ACCESS_TOKEN="$(security find-generic-password -a "$USER" -s azdo-poc-pat -w)"
export VAULT_TOKEN="$(cat "$HOME/.vault-token")"
```

`chmod 600` it, and note that `AWS_ACCESS_KEY_ID` and friends take precedence over `AWS_PROFILE`, so a shell that has them exported will ignore the profile above.

The scripts in [demo/](../demo/README.md) source this file too, and take the names of the objects Terraform created from `terraform output` rather than from here.

## Configure

```bash
cd terraform
cp example.tfvars terraform.tfvars
```

Fill in the three required values: `vault_addr`, `azdo_project_name` and `aws_user_prefix`. `terraform.tfvars` is gitignored and auto-loaded, so no command below needs `-var-file`, and a missing value fails at plan time naming exactly what it is.

Everything environment-specific lives there. The variable defaults in `variables.tf` are either generic or fixed Microsoft values, so the only file to edit is your own.

## Running it

One variable, `pipeline_mode`, drives both which resources exist and what the pipelines do.

**Always apply with `-parallelism=1`.** Azure does not support concurrent writes of federated identity credentials on a single managed identity, and this configuration puts several on one.

### Phase 1: identity chain and token inspection

```bash
cd terraform
terraform init
terraform apply -parallelism=1 -var pipeline_mode=inspect -var token_method=both
```

The apply fails on a postcondition if Azure DevOps returns the retiring Azure DevOps issuer instead of the Entra one. That is a deliberate hard stop: continuing would build the path that reaches end of life on 1 July 2027.

Then check:

```bash
terraform output service_connections     # issuers must be login.microsoftonline.com, subjects /eid1/
# with token_method=rest this prints []; with azurecli it prints the one
# Reader assignment on rg-zsp-poc and nothing else
terraform output -json managed_identity | jq -r .standing_azure_privilege
terraform output -json managed_identity | jq -r .principal_id | xargs -I{} az role assignment list --assignee {} --all

# the /sc/ segment of each subject should equal this organisation instance id
curl -s -u :$AZDO_PERSONAL_ACCESS_TOKEN \
  "$AZDO_ORG_SERVICE_URL/_apis/connectionData?api-version=6.0-preview" | jq -r .instanceId
```

Run one pipeline. It prints its token's claims and nothing else:

```bash
az pipelines run --name zsp-pipeline-a --project "$AZDO_PROJECT" --org "$AZDO_ORG_SERVICE_URL"
```

### What Phase 1 measured, 21 September 2026

Measured against a live organisation, subscription, AWS account and HCP Vault cluster. Recorded here so it does not have to be rediscovered.

**Path B confirmed.** Issuer `https://login.microsoftonline.com/<tenant>/v2.0`, subject beginning `/eid1/`, `tid` present, so `vault_user_claim = "tid"` stands.

**The audience is not what the documentation implies.** The token carries `aud = fb60f99c-7a34-4190-8149-302f77469936`, the application ID of the Azure Token Exchange Endpoint, **not** the `api://AzureADTokenExchange` identifier URI that the federated credential is configured with. Same resource, two spellings, and an Entra v2.0 token carries the app ID. Vault compares the literal string, so a role bound to the URI rejects every login, reporting only an audience mismatch and sending you to look at the federated credential rather than at the token.

**The subject does not contain the backing identity.** Its `/a/` segment decodes to `499b84ac-1321-427f-aa17-267ca6975798`, the Azure DevOps first-party application, constant everywhere and repeated as the token's `azp`. The managed identity's own client ID appears nowhere. That absence is exactly why connections sharing one identity remain distinguishable, and it is the foundation of the whole design.

**Both token methods return the same token.** Byte-identical payloads, same `uti`. `AzureCLI@2` calls the same OidcToken endpoint with the same `System.AccessToken` and then additionally signs in to Azure.

**The assertion is cached for 24 hours, not minted per run.** Issued 03:55:41Z, expiring 04:00:41Z the next day, and served unchanged to runs starting at 04:18 and later. It is a long-lived bearer credential protected by job isolation and per-pipeline connection authorisation. Nothing downstream of it is long-lived: a 5-minute Vault token with two uses, and an AWS credential deleted before the run ends. Say this before a security reviewer asks.

**`AzureCLI@2` fails without a role assignment.** Sign-in succeeds, subscription selection does not:

```
az login --service-principal --allow-no-subscriptions --federated-token ***   → succeeded
az account set --subscription <subscription id>
ERROR: The subscription of '<subscription id>' doesn't exist in cloud 'AzureCloud'.
```

A subscription the principal holds no assignment in is invisible to `az`. Hence `grant_identity_reader`.

### Choosing a token method

Both are proven, each by a full run of all nine acceptance tests. The token is the same; only the cost differs.

| | `azurecli` (default) | `rest` |
|---|---|---|
| Standing Azure privilege | Reader on `rg-zsp-poc` | **none** |
| YAML | Familiar, matches the blog | One `condition: false` task to declare the connection |
| Acceptance test 8 | `Reader on rg-zsp-poc` | `none` |

To fall back:

```bash
terraform apply -parallelism=1 -var token_method=rest -var grant_identity_reader=false
```

That fallback was run end to end on 23 September 2026, build 95: with the role assignment destroyed and
`az role assignment list --assignee <identity> --all` returning nothing at all, the pipeline still
authenticated, still had its sibling's role refuse it, and still obtained and revoked an AWS credential.
The claims were the same as the `azurecli` run minutes earlier, so the choice really is only about cost.

The `rest` path needs that skipped task because the OidcToken API refuses a connection the job has not referenced: *"There is no explicit reference to service connection ... from current stage."* The authorised set is computed from task inputs when the job is queued, so a task that never executes still declares it.

### Phase 2: Vault authentication

```bash
terraform apply -parallelism=1 -var pipeline_mode=auth -var token_method=<the one that worked>
```

Enable audit log streaming in the HCP portal, under the cluster's Audit Logs page, using:

```bash
terraform output -json hcp_audit_credentials | jq
```

Run both pipelines. Acceptance tests 1, 4 and 6 should pass.

### Phase 3: dynamic AWS credentials

```bash
terraform apply -parallelism=1 -var pipeline_mode=full -var token_method=<the one that worked>
az pipelines run --name zsp-pipeline-a --project "$AZDO_PROJECT" --org "$AZDO_ORG_SERVICE_URL"
az pipelines run --name zsp-pipeline-b --project "$AZDO_PROJECT" --org "$AZDO_ORG_SERVICE_URL"
```

All nine acceptance tests should pass. Record the evidence below.

## Acceptance tests

All nine pass. Run live against a real Azure DevOps organisation, Azure subscription, AWS account and HCP Vault cluster on 21 September 2026, builds 78 to 81, and re-run on 23 September 2026, builds 94 to 96, covering both pipelines and both token methods. Identifiers below are redacted; the structure is not.

| # | Test | Evidence | Result |
|---|---|---|---|
| 1 | Pipeline gets only its own policy | Audit log, `response.auth.policies` | `["default","zsp-pipeline-a"]` and `["default","zsp-pipeline-b"]` |
| 2 | It obtains working AWS credentials | Pipeline log | `arn:aws:iam::<account>:user/demo-…-vault-root-<random>`, then 17 EC2 regions listed |
| 3 | **The credential dies with the run** | Pipeline log, then `aws iam get-user` | `InvalidClientTokenId`, then `NoSuchEntity` |
| 4 | One pipeline cannot use another's role | Pipeline B log | `http 400`, `claim "sub" does not match any associated bound claim values` |
| 5 | Access is attributed to a pipeline | CloudWatch audit log | `pipeline_subject` distinct per pipeline, matching each connection ID |
| 6 | Both pipelines resolve to one Vault entity | `identity/entity/id` | 1 entity after ten logins across two pipelines |
| 7 | No credential reaches the logs | 30 log parts across three verbose builds | 0 matches for `hvs.` / `AKIA` / `ASIA` / `eyJ` |
| 8 | No unneeded Azure privilege | `terraform output managed_identity` | `Reader on rg-zsp-poc`, required by `azurecli`, nothing else |
| 9 | The credential cannot exceed its policy | Pipeline log | `ec2:DescribeInstances` denied while `DescribeRegions` succeeds |

### Test 3, the proof the POC exists for

```
lease aws/creds/zsp-pipeline-a/<lease id> issued, ttl 900s
credentials active for arn:aws:iam::<account>:user/demo-…-vault-root-<random>
work step succeeded: the credential can see 17 EC2 regions
revoke-self returned http 204
PASS: after revocation AWS rejects the credential with InvalidClientTokenId
```

Independently, afterwards:

```
$ aws iam get-user --user-name demo-…-vault-root-<random>
An error occurred (NoSuchEntity) ... cannot be found.
$ aws iam list-users --query "Users[?contains(UserName,'vault-root-')].UserName"
(empty)
```

The credential did not exist before the run and does not exist after it.

### Tests 5 and 6 together, which is the whole argument


Two login events from the server's own audit log, trimmed:

```json
{"policies":["default","zsp-pipeline-a"],
 "metadata":{"pipeline_subject":"/eid1/…/sc/<organisation>/<connection a>",
             "role":"zsp-pipeline-a"},
 "entity_id":"<one entity, identical in both>"}

{"policies":["default","zsp-pipeline-b"],
 "metadata":{"pipeline_subject":"/eid1/…/sc/<organisation>/<connection b>",
             "role":"zsp-pipeline-b"},
 "entity_id":"<one entity, identical in both>"}
```

Those subject tails are exactly the two service connection IDs. Different authorisation, different policy, different attribution, **same entity**. Per-pipeline authorisation and a single entity are not in tension, which is the point the design review makes.

Credential issue carries the same attribution:

```json
{"path":"aws/creds/zsp-pipeline-a","caller_subject_tail":"<connection a>","policies":["default","zsp-pipeline-a"]}
{"path":"aws/creds/zsp-pipeline-b","caller_subject_tail":"<connection b>","policies":["default","zsp-pipeline-b"]}
```

### Audit streaming has a silent failure mode

The sandbox boundary scopes the CloudWatch actions by principal tag:

```
arn:aws:logs:*:<account>:log-group:hashicorp/${aws:PrincipalTag/hcp-org-id}/${aws:PrincipalTag/hcp-project-id}
```

An untagged audit user resolves those variables to nothing, so every write is denied. HCP still reports streaming as enabled, the denial is returned to HCP where you never see it, and the only symptom is a log group that never appears, which looks exactly like slow provisioning. `hcp_org_id` and `hcp_project_id` set those tags; both UUIDs are visible in the log group path on the HCP audit page.

## How it is put together

**The dependency chain.** Terraform resolves the whole thing without anyone reading a GUID:

1. The service connection is created and exposes its federation issuer and subject.
2. A federated credential is added to the managed identity using those exact values.
3. A Vault role binds `bound_claims.sub` to the same subject.

Adding a pipeline is one entry in the `pipelines` map.

**One managed identity, several connections.** Deliberate. It mirrors how teams actually work and proves the Entra-issued token still tells connections apart, which the earlier POC's access token could not. The identity holds no Azure role assignment: it is an authentication anchor, not a standing privilege.

**Why `iam_user` and not `assumed_role`.** Only `iam_user` credentials can be revoked before they expire. STS credentials stay valid whatever Vault does, so "dead once the run finishes" could not be shown.

**Why the AWS naming looks odd.** This runs in a HashiCorp individual sandbox, which denies `iam:CreateUser` except through one carve-out: the user must be named `demo-<your aws:SourceIdentity>*` and must carry the `DemoUser` permissions boundary. Three consequences, all of them load-bearing:

- Users sit at path `/`, not `/vault-zsp/`. The allowed ARN has no path segment, so any path fails to match.
- Vault's dynamic users must be prefixed with the **root user's own name**, because the boundary lets a user create children only under `user/${aws:username}*`. That is what `username_template` is for. Without it Vault generates `vault-*` names and every credential request is denied.
- The work step is `ec2:DescribeRegions`, not `s3:ListAllMyBuckets`. A dynamic user's effective permission is its policy intersected with the boundary, so anything outside the boundary is silently useless.

Running this in an unconstrained AWS account means setting `iam_user_path = "/vault-zsp/"` and leaving `aws_permissions_boundary` unset in your tfvars. Unset, not empty: an empty string is not the same thing, and AWS rejects it with an error that names the IAM user rather than the variable.

**Why revocation happens inside the task.** The Vault token never becomes a pipeline variable, so a separate final step could not revoke it. The script revokes explicitly and registers an `EXIT` trap, so revocation still happens when a step fails. A cancelled run kills the process before the trap runs, which is what the 5-minute token lifetime covers.

**Why `token_num_uses = 2`.** One credential read and one `revoke-self`. A token that runs out of uses is revoked, and revoking a token revokes its leases, which would delete the AWS credential mid-run. The credential read must never be retried.

## Verified before first use

Checked against a local Vault Enterprise instance with a synthetic token matching the real subject structure:

- Claim inspection decodes and prints correctly.
- A role bound to one subject rejects another's token with `claim "sub" does not match any associated bound claim values`.
- Login returns only the role's own policy, with `pipeline_subject` in the metadata.
- Two different pipelines land on one entity, aliased by tenant id.
- `revoke-self` returns 204, and the `EXIT` trap revokes even when the script exits non-zero.

The pipeline template renders to valid YAML in every mode and the embedded shell parses.

Not yet exercised: everything needing real Azure, Azure DevOps and AWS credentials.

## Stretch: remove Vault's static AWS key

Vault holds a static IAM access key, which sits in Terraform state. Plugin workload identity federation would remove it. Probing the cluster showed this does not work out of the box: the plugin identity discovery document advertises a private, node-specific issuer on port 8202 that AWS cannot reach, and the node changed between two probes. Overriding the issuer fixes reachability and stability, but the public URL still carries port 8200 and AWS documentation says a provider URL should not contain one.

**Not possible in this account.** `iam:CreateOpenIDConnectProvider` is an explicit deny in the sandbox, so Vault cannot be registered as an OIDC provider at all. This is now blocked on access, not on the two technical problems above, and both of those remain unresolved regardless. Record it as untested and move on. It would need an unconstrained AWS account, at which point the two issuer problems above are what decide it.

## Teardown

```bash
# 1. Remove the CloudWatch audit streaming configuration in the HCP portal first:
#    it uses the key that step 2 deletes.
terraform destroy -parallelism=1
# must return nothing: no root user, no audit user, no orphaned dynamic users
aws iam list-users --query "Users[?starts_with(UserName,'demo-')].UserName" --output text
# Then revoke the personal access token.
```
