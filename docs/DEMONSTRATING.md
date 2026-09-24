# Demonstrating this

How to show this build to people who have to decide whether to adopt it. The evidence behind every claim is in [VALIDATION.md](VALIDATION.md); this is how to put it in front of a room.

Demonstrate it live rather than describing it. The moment that lands is an IAM user appearing on one screen while the pipeline runs and vanishing before the run ends. A slide claiming the same thing does not land at all. Keep the recorded evidence as the fallback, not the plan.

The names below are the ones this build creates: Vault namespace `admin/zsp-poc`, JWT mount `azdo-jwt`, AWS mount `aws`, roles `zsp-pipeline-a` and `zsp-pipeline-b`, pipelines of the same names. They come from the defaults in `variables.tf`, so they are already correct unless you changed `name_prefix`, `vault_jwt_path` or `vault_namespace_path` in your tfvars. Your Azure DevOps project is the one value that is always yours: `eval "$(./demo/env-from-terraform.sh)"` exports it as `AZDO_PROJECT`, and the commands below use it.

---

## Before you start

**Converge and warm up, half an hour before.** Run `terraform apply` so state matches the configuration, then run one pipeline. The first run of the day is the slowest: the hosted agent pulls its image, and IAM is least consistent on a cold account. Get that out of the way on your own time.

**Know what the warm-up does not prove.** The Entra assertion is cached for about 24 hours, so a run can succeed on a stale assertion even if something upstream has broken since. A green warm-up means the demo will probably work. It is not proof the chain is healthy.

**Check a parallel job is free**, or the run sits in a queue while the room watches nothing happen.

**Refresh every credential the same morning.** Four are in play, on different timers, and none of them belongs to the pipeline:

| Credential | Typical lifetime | Needed for |
|---|---|---|
| Vault token | Hours; HCP admin tokens last 6 | Reading the role in Act 1 |
| AWS credentials | Hours to a day for federated access | The watchers and the `NoSuchEntity` check |
| Azure CLI sign-in | Tenant policy; as little as 12 hours of inactivity | `terraform apply`, and `az pipelines run` unless a PAT is set |
| Azure DevOps PAT | Set when created, often 7 days | The log scan, and triggering runs |

Two things worth knowing. Triggering a run can be made independent of the Azure sign-in: `az pipelines run` uses `AZURE_DEVOPS_EXT_PAT` if it is set. And whenever you refresh temporary AWS credentials, verify the profile rather than your shell, because a failed refresh can leave a stale profile whose timestamp says otherwise:

```bash
aws --profile "$AWS_PROFILE" sts get-caller-identity --query Arn --output text
```

**Arrange the screen before anyone joins.** Tab-hunting on a shared screen loses a room. One screen is private, holding your notes; one is shared, holding the deck, then the browser and terminal side by side. Share the whole screen once at the start rather than switching what is shared mid-session. Put the watchers where the audience can see them next to the pipeline log, and make the terminal font larger than feels comfortable at your desk.

```bash
eval "$(./demo/env-from-terraform.sh)"   # names of what Terraform created
./demo/watch-iam.sh                      # before Act 1, so it is already running
./demo/watch-audit.sh 30                 # at the start of Act 2: delivery lags
```

---

## Act 1: what is configured, and what is not a secret

About a quarter of the time. The point of this act is that nothing on screen is a credential.

**1. The service connection.** Show it in Azure DevOps and point at the Issuer and Subject identifier. No client secret, no certificate, nothing that can be stolen and replayed. Azure DevOps holds a trust relationship, not a credential.

**2. The subject is the whole argument.** Put the two connections' subjects side by side:

```bash
terraform -chdir=terraform output -json service_connections | jq -r '.[] | "\(.name)  \(.subject)"'
```

Same tenant, same Azure DevOps application, same organisation. **Only the final segment differs**, and it is the service connection ID. Say plainly that this is what makes per-pipeline authorisation possible, and that it is exactly what an Azure access token cannot do: there the claims describe the service principal, so two pipelines sharing one identity present identical values.

Make the second point too: the managed identity does not appear in the subject at all. That absence is the mechanism.

**3. What standing privilege exists.** Say it before you are asked:

```bash
terraform -chdir=terraform output -json managed_identity | jq -r .standing_azure_privilege
```

With the Azure CLI token method the identity holds Reader on the resource group containing only itself, because the task selects a subscription and fails without it. One variable switches to the REST method and the grant goes away entirely. If a security reviewer finds this themselves, it looks like something you hoped they would miss.

**4. What Vault will accept.** The Vault UI does not show JWT roles, so read the role in the terminal:

```bash
vault read -namespace=admin/zsp-poc auth/azdo-jwt/role/zsp-pipeline-a
```

Point at these, in this order:

- `bound_claims`: `sub` pinned to one connection's full subject. Compare its last segment with the service connection from step 1.
- `bound_audiences`: the Azure token exchange audience.
- `claim_mappings`: `sub` becomes `pipeline_subject`, which is how the audit log names the pipeline in Act 3.
- `token_policies`: this pipeline's policy, and nothing else.
- `token_num_uses` and `token_ttl`: two uses and five minutes. One use buys the AWS credential, the other revokes the token.

If asked where the issuer is checked, it is on the mount rather than the role: `vault read -namespace=admin/zsp-poc auth/azdo-jwt/config` shows `bound_issuer`.

**5. What Vault can do in AWS.** The root IAM user Vault authenticates with, its permissions boundary if the account requires one, and the `iam_user` role whose policy grants exactly one action.

---

## Act 2: the run

About half the time. Trigger `zsp-pipeline-b`, the one carrying the negative test, so a single run shows both the refusal and the whole flow:

```bash
az pipelines run --name zsp-pipeline-b --project "$AZDO_PROJECT" --org "$AZDO_ORG_SERVICE_URL"
```

`zsp-pipeline-a` is the same flow without the negative test. Run it afterwards if time allows: it shows a second, differently named credential under a different Vault role.

With `DEMO=1` the task log prints every request as it is made (`->`) and every response whole, as returned (`<-`), rather than summarising. The Vault token and the AWS secret key are redacted and the access key ID is cut to its last four characters.

| On screen | Say |
|---|---|
| `ID token for this pipeline, decoded` | The whole assertion, header and payload. Walk `aud`, `tid`, `iat` and `exp`. No secret was read to produce it, and the signature is deliberately not printed |
| `"iss": "***"`, `"sub": "***"` | Azure DevOps masks the connection's own issuer and subject in every log. Point back to the service connection page from Act 1, where both are shown |
| `role zsp-pipeline-a is bound to sub ...` | The other pipeline's subject, printed in full because it is not this connection's. Its last segment is why the next call fails |
| `<- http 400` and the `errors` body | Vault refuses, in its own words. Not a policy failure, an identity failure |
| `<- http 200` and the login response | Walk `policies` (only its own), `metadata.pipeline_subject`, `num_uses`, `lease_duration`. `client_token` is redacted |
| `-> GET /v1/aws/creds/zsp-pipeline-b` | **Point at the IAM watcher.** Wait for the green line |
| the creds response | `lease_id` is the handle. Revoking it is what deletes the IAM user |
| `aws sts get-caller-identity` output | That user did not exist ninety seconds ago |
| the `describe-regions` lines | The credential works |
| `UnauthorizedOperation ... DescribeInstances` | And only for what its Vault role grants. Same service, one action to the left |
| `<- http 204 (no body)` after `revoke-self` | **Point at the watcher again.** Wait for the red line |
| `InvalidClientTokenId` | The credential is not expired. It is gone |
| `the credential existed for N seconds` | Let this sit for a moment |

The two moments to pause on are the credential being created and the credential being revoked. Both are visible in the watcher, and both are the point of the exercise.

---

## Act 3: the proof

About a quarter of the time. Three checks, live, in a shell.

```bash
# 1. The credential is gone, not merely expired.
aws iam get-user --user-name <the name from the log>                  # NoSuchEntity
aws iam list-users --query "Users[?contains(UserName,'vault-root-')].UserName" --output text

# 2. The server's own record, not the pipeline's account of itself.
./demo/watch-audit.sh 30

# 3. No credential material in any log part of the run.
./demo/scan-logs.sh
```

The audit output is the one to dwell on. Each run reads as four events, each with the full subject beneath it: the negative test refused, the pipeline logged in, it took one credential, it revoked. The `sub` line is the full `pipeline_subject`, exactly the string the Vault role is bound to. Point at its last segment: that pipeline's service connection, the only thing that differs between the two, although both run as the same managed identity.

**Make the masking point here.** In the pipeline log a few minutes ago, `sub` and `pipeline_subject` showed as `***`. Here the subject is in full. Azure DevOps masks the pipeline's own log; this is Vault's record, written by the server and streamed straight to CloudWatch, which the pipeline can neither edit nor hide from. Attribution does not depend on what a pipeline chooses to print.

If asked why the refused login has no subject: a refused login creates no token, so there is nothing to attach one to. Vault records the error, but the audit log hashes it along with the requested role name. The reason is in the pipeline log (`claim "sub" does not match`).

**Expect a delivery lag.** HCP batches audit delivery, so events land a minute or two late. Start the watcher during Act 2 so it has caught up by the time you reach it.

---

## Questions you will be asked

**"Isn't `System.AccessToken` meant only for Azure DevOps APIs?"** It is, and that is exactly how it is used: to authenticate one call to an Azure DevOps API, which returns the federation assertion. It never leaves Azure DevOps. `AzureCLI@2` makes the identical call internally; you can see it in the log as `az login --federated-token` on a token it already had.

**"How long does that assertion live?"** About 24 hours, and it is cached rather than minted per run. Do not hide this. It is a bearer credential protected by job isolation and per-pipeline connection authorisation, which is why `pipeline_id` is set on every authorisation rather than letting a connection serve the whole project. What is ephemeral is everything downstream: a five-minute Vault token with two uses, and an AWS credential deleted before the run ends.

**"The log says `az login --service-principal`. Where is its secret?"** There isn't one, and the flag name is misleading. A user-assigned managed identity has a service principal in your tenant, and `--service-principal` is the Azure CLI's way of saying "sign in as an application rather than a user". Where that flag normally takes `-p <secret>` or a certificate, here it takes `--federated-token`: the Entra assertion minted for this pipeline, which Entra checks against the federated credential registered on the identity. The service principal is the identity; the assertion proves possession of it, and nothing is stored anywhere.

**"Why does the task run `az cloud set`, `az login` and `az account set` at all?"** Those three lines belong to the `AzureCLI@2` task, not to this script. The task signs the agent in to Azure before running any inline script: it selects the cloud, does the federated sign-in, then makes the connection's subscription active. The third line is the one that needs the Reader grant. The flow does not use the result: it takes `$idToken`, the assertion itself, and sends it to Vault. The REST token method skips all three lines, needs no Azure permission, and returns the same token.

**"Why does the identity have Reader?"** The `AzureCLI@2` task selects a subscription and fails without it. One variable switches to the REST method and the grant goes away. Both were measured and return the same token, byte for byte.

**"Vault holds a static AWS key. Isn't that the same problem again?"** Yes, and it is the one piece of standing credential left. Plugin workload identity federation removes it. It was blocked in the sandbox this was built in, where `iam:CreateOpenIDConnectProvider` is explicitly denied. In production it is the first thing to fix.

**"We want task-level scoping."** Task-level *secret segregation* is the wrong unit: a task is not a security boundary, and everything in a job shares a filesystem and a process tree. What task level actually buys is audit and visibility, and you get that from `pipeline_subject` plus the lease record without fragmenting authorisation. Pipeline-level authorisation with task-level audit delivers the intent.

**"Can we add claims to the token, like repo and branch, as we do in GitLab or GitHub?"** Not officially, and not at all today. With the Entra issuer the assertion is issued by Entra about the service connection, not by Azure DevOps about the run. Its subject is the fixed `/eid1/.../sc/<org>/<connection id>` structure, the measured claim set carries no repository, branch, pipeline or environment, and Entra matches a federated credential on issuer, subject and audience only. Vault can bind only to what the token carries.

Azure DevOps puts that control somewhere else: **checks on the service connection**. The **Branch control** check takes a list of allowed branches, fully qualified as `refs/heads/main`, and can require that those branches have protection policies; a run from any other branch fails before a token is minted. The **Required template** check forces the pipeline to extend a named YAML template, so the job using the connection cannot be rewritten. Combine them with per-pipeline authorisation and `bound_claims.sub` in Vault.

Say it plainly: GitLab and GitHub put run context in the token and let the relying party enforce it; Azure DevOps puts identity in the token and enforces context on the resource. The control exists, one step earlier, enforced by Azure DevOps rather than Vault. If that split is unacceptable, make it structural: a separate service connection for the protected branch's pipeline, so the subject Vault binds to implies the branch, with branch control making that true.

**"What if a run is cancelled halfway?"** The exit trap does not fire on a hard kill. The five-minute token lifetime is the backstop, and the AWS lease expires at fifteen minutes regardless. Worst case the credential outlives the run by minutes, not days.

---

## Scaling to many pipelines

The question comes as "we have 50 pipelines and a cap of 20". Three options, and the one to recommend is not the obvious one.

**First, correct the premise.** The cap is 20 federated identity credentials per managed identity or app registration. Azure DevOps does not limit service connections. Each connection that federates to a given identity needs its own credential on it, so per-pipeline connections for 50 pipelines means 50 credentials and at least three identities.

**Option 1: share one connection across several pipelines.** Supported and simple. The cost is that those pipelines become one identity as far as Vault is concerned: one subject, one role, one set of permissions. Any pipeline authorised on that connection can take the credential, so every pipeline in the group effectively holds the strongest permission in it. Vault's audit record names the connection, not which pipeline used it. Azure DevOps still records which run used the connection, so run-level traceability survives; what you lose is the attribution demonstrated in Act 3.

**Option 2: add managed identities, 20 credentials each.** Three identities cover 50 pipelines. Nothing changes on the Vault side, because the identity never appears in the subject: roles stay bound to one connection each and attribution is untouched. The cost is more identities to manage, and one Reader grant each if you stay on the Azure CLI task. The REST token method needs no Azure permission at all, which makes extra identities nearly free.

**Option 3, and the recommendation: group by access profile.** Granularity should follow the permission boundary, not the pipeline count. Fifty pipelines rarely need fifty distinct sets of AWS permissions; they usually need five to ten, by environment, team or target account. Give each profile its own connection, Vault role and policy, and let the pipelines that genuinely share that access share the connection. That usually lands well under 20 without any of the sharing being accidental, and you can still keep a dedicated connection for the sensitive pipelines, typically production deploys.

**Whenever a connection is shared, say this out loud.** Sharing means sharing a blast radius, so two guards are not optional:

- Authorise each pipeline on the connection explicitly. Never "grant access to all pipelines", which is what makes a shared connection dangerous.
- Add the branch control and required template checks to shared connections, so a feature branch cannot use a production profile.

**What will not save you.** Entra's flexible federated identity credentials allow wildcards in the subject and would lift the cap, but as of September 2026 they support GitHub, GitLab and Terraform Cloud only, on app registrations only, and are in preview. Azure DevOps is not supported. Do not promise this.

---

## When it goes wrong

| Symptom | Cause | Do this |
|---|---|---|
| `permission denied` or `invalid token` from Vault | Your Vault token expired | Log in again. Have a spare generated beforehand |
| `ExpiredToken` from AWS | Your AWS session expired | Refresh, then verify the profile rather than your shell |
| Run sits queued | No parallel job free | Wait, or cancel the other run. Fill with Act 1 material |
| `credentials never became usable` | IAM eventual consistency | The script already polls for 60 seconds. Re-run. More likely on a cold account, which the warm-up avoids |
| `there is no explicit reference to service connection` | `token_method=rest` without the declaring task | You are on a stale apply. Re-apply |
| Audit watcher finds no log group | The audit user lost the tags the account's boundary scopes log groups by | Check its tags. Without them every write is denied while HCP still reports streaming as healthy |

**If the live run fails outright**, do not debug on stage. Switch to the recorded evidence in [VALIDATION.md](VALIDATION.md), which has the full log excerpts and the audit output, and offer to re-run at the end. A calm fallback reads better than a fix attempted in front of decision-makers.

---

## Adapting this to your environment

- The commands above read `terraform output`, so they follow whatever is in `terraform.tfvars`. Run `eval "$(./demo/env-from-terraform.sh)"` once and the watchers and log scan follow too.
- **No permissions boundary in your account?** Leave `aws_permissions_boundary` unset and Act 1 step 5 drops that sentence. An empty string is not the same as unset.
- **Using the REST token method?** Act 1 step 3 reports `none` rather than a Reader grant, which makes the standing-privilege answer stronger, and the `az login` lines disappear from the log in Act 2.
- **No audit streaming configured?** Act 3 loses check 2. Say so rather than skipping it quietly: the audit record is the strongest attribution evidence in the build, and it is worth setting up before a session that turns on attribution.

Nothing needs resetting between runs; each one creates and destroys its own credential.
