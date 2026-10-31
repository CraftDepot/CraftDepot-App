# Signing the Windows builds

This guide sets up code signing for the Windows builds with Microsoft's **Artifact Signing**
(formerly Trusted Signing), from an empty Azure subscription to a release whose `craftdepot.exe`
and `.msi` installers carry a valid, timestamped signature. The macOS side is covered under
"Signing" in [README.md](README.md#signing).

Signed builds matter on Windows: SmartScreen warns about unsigned downloads, and the release
workflow only builds the `.msi` installers when it can sign them, since an unsigned installer is
all warnings. Without signing set up, releases ship unsigned `.zip` files and no `.msi`.

## What you'll end up with

```
tag v* or Run workflow
        │
        ▼
release.yml ── build ──▶ unsigned zips (x86_64, Arm)
        │
        ▼
sign-windows job, in the `release` environment
        │  GitHub OIDC token ──▶ Microsoft Entra ID (federated credential)
        │                         └─▶ access token for the app registration
        ▼
Artifact Signing account ── certificate profile (Public Trust)
        │  signs craftdepot.exe, then the .msi installers, timestamped
        ▼
release: signed zips + signed .msi + SHA256SUMS
```

No password, certificate or key is stored in GitHub. The workflow proves who it is with a
short-lived token that GitHub issues to each run, and Azure accepts that token only from this
repository's `release` environment.

## Before you start

- **An Azure subscription** with a payment method. Artifact Signing charges a monthly fee per
  account; the Basic tier is enough for this project. See Azure's pricing page for the current price.
- **Identity validation takes time.** Microsoft checks the identity that will appear on the
  certificate, which can take from hours to several days. Start it first.
- **The Azure CLI** (`az`), signed in with `az login`. The portal works for every step too; the
  CLI is just quicker to repeat.
- **The GitHub CLI** (`gh`), signed in as an admin of `CraftDepot/CraftDepot-App`.

## 1. Create the signing account

In the Azure portal, search for **Artifact Signing accounts** and create one:

- **Resource group:** a new one just for signing.
- **Region:** any region that offers it. Its endpoint depends on the region, for example
  `https://wus.codesigning.azure.net/` for West US and `https://eus.codesigning.azure.net/` for
  East US. Note yours: the workflow needs it.
- **Pricing tier:** Basic.

The account's name and resource group can't be changed later.

## 2. Validate your identity

In the signing account, open **Identity validation** and start a new one of type **Public**. Public
validation is what lets the certificate chain up to a root that Windows trusts. Fill in the legal
name and address exactly as they appear in the documents you'll be asked for. The name you validate
is the name Windows shows as the publisher.

Wait until its status is **Completed** before going on.

## 3. Create a certificate profile

In the signing account, open **Certificate profiles** and create one:

- **Type:** Public Trust.
- **Identity validation:** the one from step 2.

Its status should be **Active**. Note the profile's name: the workflow needs it.

## 4. Register an app for GitHub

This is the identity the workflow signs in as.

```sh
az ad app create --display-name craftdepot-release-signing --query appId -o tsv   # prints the client ID
az ad sp create --id <client ID>
```

Note the client ID, and your tenant ID from `az account show --query tenantId -o tsv`.

## 5. Trust the repository's `release` environment

The federated credential tells Entra ID which GitHub token to accept. Its **subject** must match
the token's `sub` claim exactly. GitHub's claim names the owner and repository **together with their
numeric IDs**, so that a repository deleted and recreated under the same name doesn't inherit the
trust:

```
repo:CraftDepot@350790424/CraftDepot-App@1441080187:environment:release
```

Don't type it by hand. Ask GitHub for the repository's prefix and add `:environment:release`:

```sh
gh api repos/CraftDepot/CraftDepot-App/actions/oidc/customization/sub --jq .sub_claim_prefix
```

> **Don't use the portal's "GitHub Actions deploying Azure resources" scenario.** It builds the
> subject from the plain names (`repo:CraftDepot/CraftDepot-App:environment:release`), which this
> repository's tokens don't match. In the portal, pick **Other issuer** and paste the subject; or
> use the CLI.

Save this as `credential.json`, with your subject:

```json
{
  "name": "github-release-environment",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:CraftDepot@350790424/CraftDepot-App@1441080187:environment:release",
  "audiences": ["api://AzureADTokenExchange"]
}
```

```sh
az ad app federated-credential create --id <client ID> --parameters @credential.json
az ad app federated-credential list --id <client ID> --query "[].subject" -o tsv
```

## 6. Let the app sign

Give the app the **Artifact Signing Certificate Profile Signer** role on the signing account, and
nothing more:

```sh
account=$(az resource show -g <resource group> -n <account name> \
  --resource-type Microsoft.CodeSigning/codeSigningAccounts --query id -o tsv)
az role assignment create --assignee <client ID> \
  --role "Artifact Signing Certificate Profile Signer" --scope "$account"
```

A new role can take a few minutes to take effect.

## 7. Set up GitHub

Create the `release` environment and limit it to `main` and `v*` tags, so only reviewed code is
signed. The federated credential only trusts this environment, so this limit is what keeps a branch
or a pull request from getting a signature:

```sh
repo=CraftDepot/CraftDepot-App
echo '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' |
  gh api -X PUT repos/$repo/environments/release --input -
gh api -X POST repos/$repo/environments/release/deployment-branch-policies -f name=main -f type=branch
gh api -X POST repos/$repo/environments/release/deployment-branch-policies -f name='v*' -f type=tag
```

Then add six repository variables (Settings → Secrets and variables → Actions → Variables). They
are variables rather than secrets because none of them grants access on its own:

| Variable | Value |
|---|---|
| `AZURE_CLIENT_ID` | The app's client ID, from step 4 |
| `AZURE_TENANT_ID` | Your tenant ID |
| `AZURE_SUBSCRIPTION_ID` | The subscription the signing account is in |
| `ARTIFACT_SIGNING_ENDPOINT` | The endpoint from step 1, e.g. `https://wus.codesigning.azure.net/` |
| `ARTIFACT_SIGNING_ACCOUNT` | The signing account's name |
| `ARTIFACT_SIGNING_PROFILE` | The certificate profile's name |

```sh
gh variable set AZURE_CLIENT_ID --repo $repo --body "<client ID>"
# ...and the same for the other five
```

Setting `ARTIFACT_SIGNING_ACCOUNT` is what switches signing on: the workflow's `sign-windows` job
runs only when it's set.

## 8. Try it

Run the release workflow by hand: **Actions → Release → Run workflow** on `main`, or
`gh workflow run release.yml --repo CraftDepot/CraftDepot-App`. It signs but doesn't publish.

The `sign-windows` job checks the work itself. It fails unless every `craftdepot.exe` and `.msi`
has a valid, timestamped signature. It then installs, updates and uninstalls the signed `.msi`, for
this user and for everyone, alongside the install script. Its log names the certificate's subject
for each build.

To look for yourself, download the `windows-signed` artifact from the run, unzip it, and in
PowerShell:

```powershell
Get-AuthenticodeSignature .\craftdepot.exe | Format-List Status, SignerCertificate, TimeStamperCertificate
```

`Status` should be `Valid`. In Explorer, the file's Properties → Digital Signatures tab shows the
same.

## This project's setup

| | |
|---|---|
| Signing account | `craftcraft` (Basic), in resource group `craftcraft-signing`, West US |
| Endpoint | `https://wus.codesigning.azure.net/` |
| Certificate profile | `craftcraft`, Public Trust |
| App registration | `craftcraft-release-signing` |
| Federated credential subject | `repo:CraftDepot@350790424/CraftDepot-App@1441080187:environment:release` |

The `craftcraft` names date from before the project was renamed. Azure can't rename a signing
account or a profile, and the names never appear in the signed files. The IDs are in the repository
variables.

## Moving to another repository

The federated credential's subject holds the repository's owner, name and IDs, so a new repository,
and also a renamed or transferred one, needs a credential with its new subject:

1. Add a credential with the new repository's subject (step 5). The old one can stay until the old
   repository is retired, then delete it with
   `az ad app federated-credential delete --id <client ID> --federated-credential-id <name>`.
2. For a new repository, create the `release` environment and the six variables there (step 7). A
   renamed or transferred repository keeps its environments and variables.

## When it goes wrong

- **`No matching federated identity record found for presented assertion subject`.** The token's
  subject doesn't match any credential. Compare the subject in the error message with
  `az ad app federated-credential list`; usually the credential was made with plain names (see
  step 5), or the job isn't running in the `release` environment.
- **The job says the branch or tag isn't allowed to deploy to `release`.** The run started from a
  branch or tag outside the environment's limits (step 7). Run it from `main`, or push a `v*` tag.
- **`403` from the signing endpoint.** The app lacks the signer role on this account (step 6), the
  role hasn't taken effect yet, or `ARTIFACT_SIGNING_ENDPOINT` is for another region than the
  account's.
- **The `sign-windows` job is skipped.** `ARTIFACT_SIGNING_ACCOUNT` isn't set.
- **Signing fails after it worked before.** Check the certificate profile is still **Active** and
  the identity validation hasn't expired.

## Turning it off

Delete the `ARTIFACT_SIGNING_ACCOUNT` variable. Releases then ship unsigned Windows zips and no
`.msi`. To stop paying, delete the signing account in Azure.
