# Step 1: Azure DevOps and Entra ID

> This is the manual equivalent of what [`terraform/`](../../terraform/) builds in one apply. Follow it
> if you want to understand each object, or if you cannot run Terraform against your organisation.
> The end state is the same.

By the end of this step, a pipeline can ask Azure DevOps for a token that Entra ID signed, and that
token will name **the pipeline's own service connection**. That name is what Vault binds to in Step 2.

## 1.0 Two prerequisites that will stall you for days

Check these before anything else. Both are organisation-level, both are somebody else's approval in
most companies, and neither is obvious from an error message.

**Your Azure DevOps organisation must be connected to your Entra tenant.** Organisation settings,
Microsoft Entra ID. If it says "not connected", service connections cannot federate with your tenant
and nothing below works. Connecting it changes how every user in the organisation signs in, so it is
rarely a decision you make alone.

**You need at least one parallel job.** A brand new organisation often has none, and pipelines queue
forever with no error, only the word "queued". Microsoft grants free Microsoft-hosted parallelism on
request, and the request takes days to process. Organisation settings, Parallel jobs.

## 1.1 Organisation, project and repository

1. Go to https://dev.azure.com and create or choose an organisation.
2. Create a project. Any name.
3. Create a repository in it, or use the default one. The pipeline YAML lives here.

## 1.2 Create the managed identity

One identity is enough for many pipelines. This is the part people get wrong: you do **not** need one
identity per pipeline, because the token names the service connection, not the identity.

```bash
az group create --name rg-vault-poc --location eastus

az identity create \
  --name mi-vault-poc \
  --resource-group rg-vault-poc

# Keep these. The client ID goes into the service connection.
az identity show --name mi-vault-poc --resource-group rg-vault-poc \
  --query '{clientId:clientId, principalId:principalId}' -o json
```

Give it no role assignment. It is an authentication anchor, not a privilege. The one exception is in
section 1.5.

## 1.3 Create the service connection

One per pipeline. This is the object Vault will trust, so it is the whole authorisation boundary.

1. Project settings, Service connections, New service connection, **Azure Resource Manager**.
2. Identity type: **Managed Identity**. Credential: **Workload Identity Federation**.
3. Choose **Manual** so you can see the issuer and subject it generates.
4. Enter your subscription ID and name, your tenant ID, and the **client ID** of the managed identity
   from 1.2.
5. Name it after the pipeline that will use it, for example `vault-pipeline-a`.
6. **Leave "Grant access permission to all pipelines" unchecked.** Checking it hands this connection
   to every pipeline in the project, including ones created later by anyone who can create a pipeline.
   Authorise pipelines one at a time from the connection's Security page.

Azure DevOps now shows an **Issuer** and a **Subject identifier**. Both matter:

```
Issuer   https://login.microsoftonline.com/<your-tenant-id>/v2.0
Subject  /eid1/c/pub/t/<tenant>/a/<app>/sc/<organisation>/<connection-id>
```

Read that subject carefully, because the entire design rests on it:

- `/t/` is your tenant, base64url encoded rather than the familiar GUID form.
- `/a/` is `499b84ac-1321-427f-aa17-267ca6975798`, the Azure DevOps first-party application. It is the
  same value in every organisation in the world.
- `/sc/` is your organisation instance, then **the ID of this one service connection**.

The managed identity appears nowhere in it. That absence is the point: two connections backed by the
same identity produce different subjects, so Vault can tell two pipelines apart.

If your subject begins with `https://vstoken.dev.azure.com/` instead of `/eid1/`, you have the older
Azure DevOps issuer. Do not continue on it: Microsoft retires it on 1 July 2027. Recreate the
connection, and check that your organisation is connected to Entra as in section 1.0.

## 1.4 Trust the connection from Azure

The service connection now claims an identity. Azure has to agree.

1. Azure portal, your managed identity, **Federated credentials**, Add credential.
2. Scenario: **Other issuer**.
3. Issuer and Subject identifier: paste exactly what the service connection showed.
4. Audience: `api://AzureADTokenExchange`.
5. Name it after the connection.

Or from the CLI:

```bash
az identity federated-credential create \
  --name fic-vault-pipeline-a \
  --identity-name mi-vault-poc \
  --resource-group rg-vault-poc \
  --issuer "https://login.microsoftonline.com/${AZURE_TENANT_ID}/v2.0" \
  --subject "/eid1/c/pub/t/..." \
  --audiences "api://AzureADTokenExchange"
```

**Two limits to plan around now rather than later.**

An identity accepts **20 federated credentials**, and the cap cannot be raised. Twenty pipelines per
identity; create another identity for the next twenty. Flexible federated identity credentials, which
allow a wildcard in the subject, support GitHub, GitLab and Terraform Cloud only, on app registrations
only, and are in preview. Azure DevOps is not a supported issuer, so there is no wildcard available
to you.

Azure rejects **concurrent writes** of federated credentials on one identity. Create them one at a
time.

## 1.5 Choose how the pipeline fetches its token

Two ways, and they return the same token. Measured: byte-identical payloads, same `uti`.

| | `AzureCLI@2` | OidcToken REST API |
|---|---|---|
| Azure permission needed | **Reader somewhere in the subscription** | None at all |
| Why | The task runs `az account set`, and a subscription the identity holds no assignment in is invisible | It only asks Azure DevOps for a token |
| Cost | One standing privilege, however small | A `condition: false` task, explained below |

If you use `AzureCLI@2`, grant the identity Reader on the resource group holding it, and nothing more:

```bash
az role assignment create \
  --assignee <principal-id-from-1.2> \
  --role Reader \
  --scope $(az group show --name rg-vault-poc --query id -o tsv)
```

Without it the task fails at `az account set` with *"The subscription of '...' doesn't exist in cloud
'AzureCloud'"*, which names the subscription and not the cause.

If you use the REST API, the identity needs no Azure permission whatsoever, but the job must still
**declare** the service connection, because the OidcToken endpoint refuses a connection the job has
not referenced: *"There is no explicit reference to service connection ... from current stage."* The
authorised set is computed from task inputs when the job is queued, so a task that never runs still
declares it:

```yaml
- task: AzureCLI@2
  displayName: 'Declare the service connection (never runs)'
  condition: false
  inputs:
    azureSubscription: 'vault-pipeline-a'
    scriptType: bash
    scriptLocation: inlineScript
    inlineScript: 'true'
```

Step 3 has the working version of both.

## 1.6 Collect what Step 2 needs

```bash
# Your tenant.
AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)

# What Vault will use to find Entra's signing keys.
echo "https://login.microsoftonline.com/${AZURE_TENANT_ID}/v2.0"

# Confirm the issuer Entra advertises matches what the service connection showed.
curl -s "https://login.microsoftonline.com/${AZURE_TENANT_ID}/v2.0/.well-known/openid-configuration" \
  | jq -r .issuer
```

You also need each connection's **subject**, exactly as shown in 1.3. Copy them now; Step 2 binds one
role to each.

**The audience is the one value you cannot guess.** The federated credential is configured with
`api://AzureADTokenExchange`, but the token that arrives carries:

```
aud = fb60f99c-7a34-4190-8149-302f77469936
```

That is the application ID of the Azure Token Exchange Endpoint. Same resource, two spellings, and an
Entra v2.0 token carries the app ID. It is a fixed Microsoft value, identical in every tenant. Vault
compares the literal string, so a role bound to the URI rejects every login while reporting only an
audience mismatch, sending you to inspect the federated credential rather than the token.

## Next steps

[Step 2: Vault configuration](STEP_2_VAULT_SETUP.md).
