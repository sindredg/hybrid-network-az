# Troubleshooting log

Errors hit while building this lab, with the error messages, why it happened, and what fixed it.

**Overview**

| # | Phase | Symptom | Root cause | Status |
|---|---|---|---|---|
| [1](#1-terraform-init-hangs-forever) | 1 | `terraform init` hangs at "Initializing the backend" | Two concurrent runs racing for the state lock | Fixed |
| [2](#2-oidc-subject-mismatch-aadsts700213) | 1 | `AADSTS700213` on login | GitHub's immutable subject format does not match the federated credential | Fixed |
| [3](#3-basic-sku-public-ip-blocked) | 1 | `IPv4BasicSkuPublicIpCountLimitReached` | Azure no longer allows Basic SKU public IPs | Fixed |
| [4](#4-terraform-fmt--check-exits-3) | 1 | `terraform fmt -check` exits 3 | Formatting drift, partly invisible characters from pasted code | Fixed |
| [5](#5-non-az-gateway-sku-rejected) | 1 | `NonAzSkusNotAllowedForVPNGateway` | Non-AZ gateway SKUs retired | Fixed |
| [6](#6-az-gateway-requires-zoned-public-ip) | 1 | `VmssVpnGatewayPublicIpsMustHaveZonesConfigured` | AZ gateways require zoned public IPs | Fixed |
| [7](#7-apply-step-silently-skipped) | 0 | Deploy job green, nothing deployed | Leftover `if` condition after changing triggers | Fixed |
| [8](#8-provider-rejects-ed25519-ssh-keys) | 2 | `the provided ssh-ed25519 SSH key is not supported` | Provider-side validation, not an Azure limit | Fixed |
| [9](#9-vm-size-not-available-in-the-region) | 2 | `SkuNotAvailable` for `Standard_B1s` | Subscription capacity restriction on the whole v1 B-series | Fixed |
| [10](#10-bastion-cannot-reach-the-on-premises-vnet) | 2 | "The target machine is unreachable" | Bastion has no resource-ID data path over a gateway connection | Resolved by Phase 3 redesign |
| [11](#11-terraform-plan-reports-unsupported-block-type) | 3 | `Error: Unsupported block type` | Legacy diagnostic metric block rejected after upgrading to AzureRM 5.x | Fixed |
| [12](#12-deployment-failed-with-publicipcountlimitreached) | 3 | `PublicIPCountLimitReached` | Sweden Central regional public-IP quota reached | Fixed |
| [13](#13-nmap-and-nc-report-ports-80-and-443-open-despite-deny-rules) | 3 | `nmap` and `nc` report web ports open | TCP establishment is not proof of a permitted Layer 7 request | Explained and validated |
| [14](#14-private-dns-zone-link-rejected-by-azurerm-5x) | 4 | Missing `private_dns_zone_id`; name and resource group unsupported | AzureRM 5.x resource schema was used with legacy arguments | Fixed |
| [15](#15-linux-vm-reports-custom_data-as-unsupported) | 4 | `custom_data` is reported as an unsupported argument | The valid VM argument was nested inside the identity block | Fixed |
| [16](#16-ci-cannot-manage-a-secret-in-the-private-key-vault) | 4 | Terraform gets `ForbiddenByRbac` on `demo-secret` | CI had no secret data role and runs outside the private network | Fixed by design change |
| [17](#17-spoke-vm-reaches-key-vault-but-gets-forbiddenbyrbac) | 4 | VM token works, Key Vault request returns 403 | Managed identity had no vault data-plane role | Fixed |

---

## Phase 1: Building the tunnel

Six failures between writing the config and getting it deployed. Four of the six were Azure retiring something, and none of those were visible before an apply.

### 1. `terraform init` hangs forever

**Symptom**

The workflow sat at the init step and never moved:

```text
Run terraform init
Initializing the backend...
```

No error, no timeout, just a run counting upwards until it was cancelled by hand.

![Workflow run stalled on the Terraform Init step, with every later step still queued](images/terraform-init-hanging.png)

Everything before it passed in a second or two. Init sat there on its own.

**Root cause**

Two commits pushed back to back triggered two workflow runs. Both tried to acquire the lease on the same state blob in the storage account. The first took the lock, the second waited for it, and Terraform's default behaviour there is to block rather than fail fast.

This was harder to diagnose than it should have been because the OIDC token exchange was also happening silently at that point in the run, so the hang could plausibly have been an authentication problem rather than a locking one.

**Fix**

Two parts.

Cancelling the stuck runs in the Actions UI released the lease. Worth noting that cancelling a run that is mid-apply is not always this clean: it can leave a stale lock behind, which then needs `terraform force-unlock` and a careful look at what actually got created.

Then `azure/login@v2` was added as an explicit step before `terraform init`. That separates authentication from initialisation, so a credential problem now fails in its own step with its own error rather than looking like a backend hang.

**Guarded against in Phase 0.** Both workflows now share a concurrency group, so a second run queues instead of colliding:

```yaml
concurrency:
  group: terraform-state
  cancel-in-progress: false
```

`cancel-in-progress: false` is the important half. Cancelling an in-flight apply is how the stale-lock version of this problem happens. The group name is shared deliberately, so an apply and a destroy cannot overlap either.

**Lesson**

A hang is a symptom, not an error. When a step blocks with no output, the question is what resource it is waiting on, and shared state is the usual answer.

---

### 2. OIDC subject mismatch (`AADSTS700213`)

**Symptom**

```text
clientCredentialsToken: received HTTP status 401 with response:
{"error":"invalid_client","error_description":"AADSTS700213: No matching federated identity
record found for presented assertion subject
'repo:sindredg@186042440/hybrid-network-az@1335552645:ref:refs/heads/main'..."}
```

![Init step failing with AADSTS700213, showing the presented assertion subject](images/oidc-aadsts700213-error.png)

Two things in the full log are worth noticing beyond the error code. The first line is `Failed to get existing workspaces: Error retrieving keys for Storage Account`, which is the backend trying to look up the storage account access key through the management plane, and failing at the authentication step before it gets there. That is the access-key lookup behaviour described in [decisions.md](decisions.md#5-why-is-the-backend-only-partially-configured). The second is that Azure prints the exact subject it was presented with, which turns out to be the fix.

**Root cause**

The federated credential in Azure was configured with the classic, name-based subject:

```text
repo:sindredg/hybrid-network-az:ref:refs/heads/main
```

GitHub sent a subject containing numeric IDs instead:

```text
repo:sindredg@186042440/hybrid-network-az@1335552645:ref:refs/heads/main
```

This is GitHub's immutable subject claim format. The numbers are the owner ID and the repository ID. The reason for it is subject recycling: under the old format, renaming a repository or reusing a name meant a new repository could inherit the trust granted to a previous one. Embedding immutable numeric IDs closes that.

Repositories created after 15 July 2026 get the immutable format automatically. Existing repositories keep the name-based format until opted in.

The error message is unhelpfully shaped. It says no matching record was found, which reads like the credential is missing, when in fact the credential exists and its subject string differs.

**Fix**

Updated the Subject Identifier on the federated credential in the Azure portal, under App registration, Certificates and secrets, Federated credentials.

The bootstrap script creates two credentials, one for `main` and one for pull requests, so both needed the same treatment:

![Federated credentials blade showing gh-actions-main and gh-actions-pr](images/azure-federated-credentials.png)

The fix itself is one field, pasted verbatim out of the error message:

![Subject identifier field containing the immutable subject with numeric owner and repository IDs](images/federated-credential-immutable-subject.png)

That is the useful trick here: the error prints the subject GitHub actually sent. Copy it rather than trying to construct it. Subject matching is an exact string comparison, so a single character off fails identically to being completely wrong.

One practical note on retrying, and it only applies when the fix was outside the repository. Here nothing in the repo changed, only Azure-side configuration, so the re-run button is right and pushing an empty commit would risk the concurrent-run problem from item 1. When the fix is a file change, re-run is wrong: it replays the original commit and your change is not in it.

![GitHub Actions re-run jobs menu](images/github-actions-rerun-menu.png)

![Re-run all jobs confirmation dialog with the failed Terraform job listed](images/github-actions-rerun-dialog.png)

**Fixed properly in Phase 0.** The portal edit only patched the running setup; the script would have recreated a broken credential on the next run. It now reads the numeric IDs and writes both subject formats, so either token matches:

```bash
REPO_ID=$(gh api "repos/${GITHUB_ORG}/${GITHUB_REPO}" --jq '.id')
OWNER_ID=$(gh api "repos/${GITHUB_ORG}/${GITHUB_REPO}" --jq '.owner.id')
IMMUTABLE="repo:${GITHUB_ORG}@${OWNER_ID}/${GITHUB_REPO}@${REPO_ID}"
```

Four federated credentials instead of two: `main` and `pull_request`, each in name-based and immutable form. Azure allows up to 20 per app, so the redundancy is free.

**Reference**

Microsoft's migration guide: [Migrate GitHub Actions federated credentials to immutable subjects](https://learn.microsoft.com/en-us/entra/workload-id/workload-identities-github-immutable-subjects). GitHub's announcement: [Immutable subject claims for GitHub Actions OIDC tokens](https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/).

---

### 3. Basic SKU public IP blocked

**Symptom**

```text
IPv4BasicSkuPublicIpCountLimitReached: Cannot create more than 0 IPv4 Basic SKU
public IP addresses for this subscription in this region.
```

It failed once per public IP, and Terraform reported both in the same run:

![Apply log showing IPv4BasicSkuPublicIpCountLimitReached for pip-vpn-hub and pip-vpn-onprem](images/basic-sku-public-ip-error.png)

Worth noting from that log that `peer-hub-to-spoke` had already been created successfully a few lines earlier. A partial apply is the normal outcome here, not an all-or-nothing rollback.

**Root cause**

`azurerm_public_ip` historically defaulted to Basic SKU with dynamic allocation. Azure has retired Basic SKU public IPs and the effective quota for new ones is zero, which is what "more than 0" is saying. It is a quota message describing a deprecation.

The trap is that the failure comes from a provider default, not from anything written in the config. The resource block did not mention a SKU at all.

**Fix**

Made both properties explicit in `terraform/main.tf`:

```hcl
resource "azurerm_public_ip" "vpn_pip" {
  allocation_method = "Static"
  sku               = "Standard"
}
```

Standard SKU only supports static allocation, so both had to change together.

![main.tf public IP resource with allocation_method Static and sku Standard set explicitly](images/public-ip-standard-sku-fix.png)

**Lesson**

Provider defaults age. When a resource fails on a property the config never set, check what the provider is defaulting to rather than assuming the config is at fault.

---

### 4. `terraform fmt -check` exits 3

**Symptom**

The format check step failed with exit code 3. The only output was the name of the offending file:

![Terraform Format Check step failing with main.tf listed and exit code 3](images/terraform-fmt-check-exit-3.png)

Which file, but not which line, and not what was wrong with it.

**Root cause**

Formatting drift from hand-editing, plus non-breaking space characters that came in with code pasted from a browser. Those are invisible in most editors and `fmt` treats them as unexpected characters.

**Fix**

Ran `terraform fmt` locally, which rewrote the file and printed the same one-line answer, this time having actually fixed it:

![Local terminal running terraform fmt and printing main.tf](images/terraform-fmt-local-run.png)

The affected lines were then retyped to clear the invisible characters.

**How to avoid it**

Run `terraform fmt -recursive` before committing. A pre-commit hook makes it automatic. Note that `fmt -check` only reports that something is unformatted; `terraform fmt -diff` shows what it would change, which is what you actually want when the check fails in CI.

**Aside on exit codes**

`terraform fmt -check` returns non-zero when files need formatting. That is the whole point of it in CI. Do not "fix" this by removing the step.

---

### 5. Non-AZ gateway SKU rejected

**Symptom**

```text
NonAzSkusNotAllowedForVPNGateway: VpnGw1-5 non-AZ SKUs are no longer supported
for VPN gateways. Only VpnGw1-5AZ SKUs can be created going forward.
```

Once for each gateway, and with a documentation link included in the error:

![Apply log showing NonAzSkusNotAllowedForVPNGateway for vgw-onprem and vgw-hub](images/non-az-gateway-sku-error.png)

**Root cause**

Azure retired the non-availability-zone gateway SKUs for new deployments. `VpnGw1` is no longer creatable; `VpnGw1AZ` is the replacement.

This is a clearly worded error, which is not always the case. It names both the problem and the fix.

**Fix**

Changed the SKU on both gateways in `terraform/main.tf`:

```hcl
sku = "VpnGw1AZ"
```

**Consequence**

AZ SKUs cost more than their non-AZ equivalents. For a lab on trial credits that is worth knowing, and there is no cheaper alternative, so the mitigation is destroying the lab when not in use rather than choosing a smaller gateway.

It also introduced the next error.

---

### 6. AZ gateway requires zoned public IP

**Symptom**

```text
VmssVpnGatewayPublicIpsMustHaveZonesConfigured: Standard Public IPs associated with
VPN Gateways with AZ VPN skus must have zones configured.
```

![Apply log showing VmssVpnGatewayPublicIpsMustHaveZonesConfigured for both gateways](images/gateway-public-ip-zones-error.png)

Same two gateways, same line numbers in `main.tf`, third different error.

**Root cause**

Direct consequence of the previous fix. Once a gateway uses an AZ SKU, Azure requires its public IP to declare availability zones explicitly. A Standard public IP with no zones specified is not acceptable to a zone-redundant gateway.

This is a cascade: fixing the Basic SKU issue produced a Standard IP, fixing the gateway SKU made it an AZ gateway, and the combination of the two triggered a third requirement that neither change implied on its own.

**Fix**

Added zones to the public IP resource:

```hcl
zones = ["1", "2", "3"]
```

All three zones, making the IP zone-redundant to match the gateway.

**Lesson**

Azure requirements chain. Three separate applies were needed to get through what was really one platform-modernisation change. It is worth reading the whole plan and thinking about downstream constraints rather than fixing one error and immediately re-running, though in practice the cascade is often only visible once you hit it.

---

## Phase 0: Pipeline fixes

One entry, and the most dangerous of the lot, because it failed by succeeding.

### 7. Apply step silently skipped

Fixed in Phase 0. Listed in full because a green pipeline that deploys nothing is a worse failure than a red one, and the shape of it is worth recognising elsewhere.

**Symptom**

The deploy workflow completes successfully and no resources change in Azure.

This has not been caught in a live run yet, because the last full apply happened under the previous trigger configuration and genuinely did deploy:

![Workflow run succeeding in 21m 54s with every step green including Terraform Apply](images/successful-deploy-run.png)

That run is real. The gateways exist. The problem is that the same workflow, triggered the way it is now triggered, cannot repeat it.

**Root cause**

The workflow originally applied on every push to `main`, and the apply step was gated accordingly:

```yaml
if: github.ref == 'refs/heads/main' && github.event_name == 'push'
```

The triggers were later changed to `workflow_dispatch` and `pull_request` for cost control:

![terraform-apply.yml showing workflow_dispatch and pull_request triggers with a paths filter](images/workflow-triggers-manual-and-pr.png)

The step condition was left as it was. `push` is no longer in that list, so `github.event_name` can only ever be `workflow_dispatch` or `pull_request`, and the condition cannot evaluate true. GitHub skips the step and reports the job as successful, because a skipped step is not a failed one.

**Fix**

Change the condition to match the actual trigger:

```yaml
if: github.event_name == 'workflow_dispatch'
```

Worth adding a GitHub Environment with a required reviewer at the same time, so the apply needs a deliberate approval. That restores the protection the old push-gate was only appearing to provide.

The reasoning behind the trigger change is in [decisions.md](decisions.md#7-why-does-deployment-need-a-button-press).

**Verified fixed.** The next manual run reached the apply step and stayed there for 24 minutes, rather than skipping it and finishing in one.

**Lesson**

When changing workflow triggers, audit every `if:` in the file. Conditions referencing `github.event_name` are the ones that quietly stop matching, and they fail open into a green tick rather than an error.

---

## Phase 2: Workloads and access

Three failures, none of them in the network config. Two were environment constraints that only appear at apply time, and one was a service limitation that the portal does not warn about.

### 8. Provider rejects ed25519 SSH keys

**Symptom**

```text
Error: - the provided ssh-ed25519 SSH key is not supported.
Only RSA SSH keys are supported by Azure
```

**Root cause**

The message is wrong about Azure. Microsoft's documentation lists both RSA (2048-bit minimum) and ED25519 (256-bit) as supported, and rejects only ECDSA and ECDH. The rejection is client-side validation in azurerm 3.117.1, before any request reaches Azure.

Current provider documentation confirms this was later relaxed: `public_key` "needs to be in `ssh-rsa` format with at least 2048-bit or in `ssh-ed25519` format". So the pinned provider version, not the platform, is the constraint.

**Fix**

```bash
ssh-keygen -m PEM -t rsa -b 4096 -C "az-network-lab" -f ~/.ssh/az-network-lab-rsa
```

`-m PEM` is not incidental. Bastion's portal session asks for the private key and expects PEM (`-----BEGIN RSA PRIVATE KEY-----`), not the newer OpenSSH container. Omitting it moves the failure one step later.

**Lesson**

Read error messages as coming from a specific component, not from the platform they describe. "Azure does not support this" from a provider often means "this provider version does not send it". Checking the current resource documentation took a minute and changed the conclusion.

---

### 9. VM size not available in the region

**Symptom**

```text
SkuNotAvailable: The requested VM size for resource 'Following SKUs have failed
for Capacity Restrictions: Standard_B1s' is currently not available in location
'SwedenCentral'.
```

**Root cause**

A capacity restriction on the subscription, not a quota. Quota problems say the limit is exceeded; this says the SKU cannot be offered at all. Listing what is actually available showed the entire v1 B-series absent from Sweden Central, so `B1ms` or `B2s` would have failed identically.

**Fix**

`Standard_B2as_v2`, confirmed unrestricted in zones 1, 2 and 3 before applying rather than after:

```bash
az vm list-skus -l swedencentral --resource-type virtualMachines --query "[?length(restrictions)==\`0\`].name" -o tsv | grep B2
```

Two related checks worth running at the same time. Regional vCPU quota was 4, and every v2 B-series size starts at 2 vCPU, so two VMs fit exactly with nothing spare. And the ARM variants (`B2ps_v2` and similar) are amd64-incompatible, so they would have failed on the image reference instead.

**Lesson**

`SkuNotAvailable` and quota errors read similarly and have different fixes. Check availability with `az vm list-skus` and quota with `az vm list-usage`; one is a config change, the other is a support request.

---

### 10. Bastion cannot reach the on-premises VNet

**Status: resolved operationally in Phase 3.** The cross-gateway service limitation remains documented because the diagnosis took three attempts and the portal's error message points at the wrong thing.

**Symptom**

```text
Connection Error
The target machine is unreachable. Please verify that your NSG rules allow
traffic to ports 22 (SSH) and 3389 (RDP) from the private IP address
168.63.129.16.
```

**Root cause**

Not the NSG, despite what the message says. The first `deny-all-inbound` rule genuinely was blocking the Bastion subnet, so adding an allow rule looked like the answer. It was not sufficient, and `test-ip-flow` proved the NSG had stopped being the problem:

```text
Allow  securityRules/allow-ssh-from-bastion
```

The real cause is that `vnet-hub` and `vnet-onprem` are joined by a gateway connection, not a peering. Bastion Basic supports peered VNets only. Upgrading to Standard adds IP-based connection, which is the documented mechanism for reaching a machine across a VPN connection, but it must be started from the Bastion resource with a target address. Going to the VM blade and choosing Connect still uses the resource-ID path, which has no route.

The `168.63.129.16` in the message is Azure's platform address and generic boilerplate. It is not the source Bastion connects from, and chasing it wastes time.

**Resolution and earlier workaround**

Phase 3 moved Bastion into the simulated on-premises VNet as part of the Denmark East migration. Bastion can now reach `vm-onprem` inside its own VNet, so the administrative-access problem is resolved without depending on a cross-gateway resource-ID connection.

Before that redesign, the workaround was to SSH from `vm-spoke`, which the NSGs already permitted. A keypair could be generated on the spoke and authorised on the on-premises VM through `az vm run-command`, so no private key was copied onto a VM.

That hop is arguably the better demonstration anyway: reaching the simulated datacenter through the spoke, across the peering, through the hub gateway and over the tunnel is the architecture doing its job, and the prompt changing from `vm-spoke` to `vm-onprem` proves it.

For non-interactive checks, `az vm run-command invoke` sidesteps the problem entirely and returns output to a local terminal, which also solves the browser clipboard.

**Lesson**

An NSG that is genuinely misconfigured can mask a second, unrelated blocker. Prove each layer separately: `test-ip-flow` for the rules, `show-next-hop` for the routing. Fixing the first and assuming you are done is how one problem becomes three attempts.

## Phase 3: Azure Firewall, forced routing and regional migration

### 11. Terraform plan reports `Unsupported block type`

**Symptom**

Terraform rejected the diagnostic-setting configuration after the repository moved to AzureRM 5.x.

![Terraform plan reporting an unsupported block type](images/error-unsupported-block-type.png)

**Root cause**

The diagnostic setting still contained the legacy `metric` block used to set `enabled = false`. AzureRM 5.x removed that block shape, so Terraform rejected the configuration before it could build a plan.

**Fix**

Remove the obsolete block. The Phase 3 diagnostic setting now declares only the required `AZFWNetworkRule` and `AZFWApplicationRule` log categories.

**Lesson**

A major provider constraint such as `~> 5.0` is an explicit migration decision. Run `terraform validate` against the locked provider and review the provider upgrade guide before relying on configuration written for the previous major version.

---

### 12. Deployment failed with `PublicIPCountLimitReached`

**Symptom**

Terraform failed while creating the firewall public IP in Sweden Central.

![Terraform apply failing because the Sweden Central public-IP quota was exhausted](images/pip-limit-reached.png)

**Root cause**

The subscription's regional public-IP quota was already consumed by the two VPN gateways and Azure Bastion. Adding the Azure Firewall public IP exceeded the Sweden Central limit.

**Fix**

Move the simulated on-premises VNet, VPN gateway, workload VM, and Bastion to Denmark East. The hub VPN gateway and Azure Firewall remain in Sweden Central, distributing the four public IPs evenly across the two regions.

**Lesson**

Check regional quotas before placing gateways, firewalls, and Bastion in one region. In this lab the constraint improved the architecture: the simulated datacenter is now geographically separate from the Azure estate.

---

### 13. `nmap` and `nc` report ports 80 and 443 open despite deny rules

**Symptom**

From `vm-onprem`, `nmap` reported ports 22, 80, and 443 as open on `vm-spoke`, and `nc -vz` completed TCP connections to ports 80 and 443. Neither VM runs a web service, and the workload NSGs do not allow those ports.

![nmap reporting ports 80 and 443 as open](images/nmap-http-https.png)

![netcat reporting successful TCP connections to ports 80 and 443](images/phase3-tcp-handshake-false-positive.png)

**Root cause**

The test measured TCP connection establishment, not end-to-end application access. Azure Firewall performs application-layer processing and can accept or intercept a TCP connection before returning its final HTTP or TLS decision. Raw-IP HTTPS also lacks the hostname needed for SNI matching, so it is denied with `SNI TLS extension was missing`.

**Fix and proof**

Test the application protocol and inspect the firewall logs:

```bash
curl -v -m 5 http://10.1.0.4
```

![HTTP request receiving Azure Firewall status 470 and a default deny](images/phase3-firewall-http-deny.png)

The response is HTTP `470`, `Action: Deny`, `Reason: No rule matched`. Log Analytics records the same flow as a default deny.

![Azure Firewall application-rule logs showing the deciding rules](images/phase3-application-rule-logs.png)

**Lesson**

An open TCP handshake is not proof that an application is reachable through a Layer 7 firewall. Use a protocol-aware request and correlate it with firewall logs. For HTTPS application rules, test with a real hostname and SNI rather than a bare IP address.

---

## Phase 4: Private Link and Key Vault

### 14. Private DNS zone link rejected by AzureRM 5.x

**Symptom**

```text
Error: Missing required argument
The argument "private_dns_zone_id" is required, but no definition was found.

Error: Unsupported argument
An argument named "resource_group_name" is not expected here.

Error: Unsupported argument
An argument named "private_dns_zone_name" is not expected here.
```

**Root cause**

`azurerm_private_dns_zone_virtual_network_link` was written with name-based arguments from an older
resource shape. With the locked AzureRM 5.x provider, the link takes the private zone resource ID
and the VNet resource ID.

**Fix**

```hcl
resource "azurerm_private_dns_zone_virtual_network_link" "kv" {
  for_each            = var.linked_vnet_ids
  name                = "link-${each.key}"
  private_dns_zone_id = azurerm_private_dns_zone.kv.id
  virtual_network_id  = each.value
}
```

**Lesson**

When Terraform reports one required argument missing and the old-looking alternatives unsupported,
check the schema for the provider version in the lock file. This is a configuration-shape error, not
an Azure permission or dependency error.

---

### 15. Linux VM reports `custom_data` as unsupported

**Symptom**

```text
Error: Unsupported argument
on modules/compute/main.tf line 40, in resource "azurerm_linux_virtual_machine" "vm":
custom_data = each.key == "onprem" ? base64encode(...)
An argument named "custom_data" is not expected here.
```

**Root cause**

`custom_data` is valid on `azurerm_linux_virtual_machine`, but it had been placed inside the dynamic
`identity` block. Terraform validates an argument against its immediate block, so it correctly said
the identity block did not accept it.

**Fix**

The immediate fix was to close the identity block first, then place `custom_data` at virtual-machine
resource scope. The current implementation also removes the key-name coupling: each root VM object
sets `enable_identity` and `custom_data` explicitly, and the compute module reads those typed
attributes.

**Lesson**

“Unsupported argument” can mean incorrect nesting rather than an unavailable feature. Read the
surrounding braces before changing provider versions or deleting a valid argument.

---

### 16. CI cannot manage a secret in the private Key Vault

**Symptom**

Terraform apply failed while checking the proposed `demo-secret`:

```text
StatusCode=403
Code="Forbidden"
Action: 'Microsoft.KeyVault/vaults/secrets/getSecret/action'
Assignment: (not found)
InnerError={"code":"ForbiddenByRbac"}
```

![Terraform failing while checking demo-secret](images/phase4-ci-secret-rbac-failure.png)

**Root cause**

Key Vault secret operations use the data plane. The GitHub Actions service principal had management
permissions for the vault resource but no secret data-plane role. Granting a secret role would only
solve the first half of the design problem: the GitHub-hosted runner is also outside the VNets, while
the vault has public network access disabled. The `AzureServices` firewall bypass does not turn a
GitHub-hosted runner into a private-network caller.

Terraform also refreshes managed secrets by calling `GetSecret`; “write it but never read it” is not
a stable Terraform lifecycle.

**Fix**

Remove `azurerm_key_vault_secret.demo`. Terraform now manages the vault, endpoint, DNS, identity,
and role assignment, but no secret data. Phase 4 validates the workload path with an authorized list
request from `vm-spoke`; a real secret must be created by a caller inside the private network.

**Lesson**

Management-plane permission to deploy a vault is separate from data-plane permission and network
reachability to use it. Design private PaaS tests around the workload that will consume the service,
not around the CI runner that provisions it.

---

### 17. Spoke VM reaches Key Vault but gets `ForbiddenByRbac`

**Symptom**

DNS returned `10.1.1.4` and IMDS issued a managed-identity token, but the Key Vault request returned:

```text
"code": "Forbidden"
"Action": "Microsoft.KeyVault/vaults/secrets/readMetadata/action"
"Assignment": "(not found)"
"innererror": { "code": "ForbiddenByRbac" }
```

![VM request denied before its Key Vault role assignment](images/phase4-spoke-rbac-denied.png)

**Root cause**

The VM had an identity but no Key Vault data-plane role. Identity creation proves who the VM is; it
does not grant access by itself.

**Fix**

Add an `azurerm_role_assignment` at root, where the compute module's principal ID and the Private
Link module's vault ID are both available. Assign the built-in `Key Vault Secrets User` role at vault
scope, and bootstrap the deployment identity with authority to create that constrained assignment.

The repeated request returned HTTP 200 and an empty secret list. The response header reported
`conn_type=PrivateLink`, proving authorization and transport independently.

**Lesson**

Test private PaaS access as four separate claims: DNS, route/endpoint, token issuance, and RBAC. A
403 after private DNS and token acquisition is useful evidence. The network path works and the fault
is authorization.

---

## Phase 5: Azure DNS Private Resolver

### 18. Cloud-init cannot install `dnsmasq` during resolver deployment

**Symptom**

The spoke's `app.corp.internal` lookup timed out. On `vm-onprem`, the service did not exist, and the
cloud-init log contained:

```text
Temporary failure resolving 'archive.ubuntu.com'
Failure when attempting to install packages: ['dnsmasq']
Failed to restart dnsmasq.service: Unit dnsmasq.service not found.
```

![Cloud-init could not resolve the Ubuntu repositories](images/phase5-troubleshooting-cloud-init-dns-failure.png)

**Root cause**

The on-premises VNet DNS setting and the resolver were changing in the same deployment. The VM's
first boot tried to install its DNS package while its configured upstream `10.0.3.4` was not yet
ready to answer. Cloud-init's package module failed once and did not retry after resolution became
healthy.

**Fix**

After `nslookup archive.ubuntu.com` succeeded, running `apt-get update` and installing `dnsmasq`
recovered the live VM. The Terraform source now removes the race structurally: `module.compute` declares
`depends_on = [module.connectivity]`, so no VM is created until both gateways and the tunnel
exist and `10.0.3.4` answers at first boot. As a second layer, cloud-init installs `dnsmasq` from
a bounded `runcmd` retry loop rather than the one-shot `packages` module, which does not
re-attempt after resolution becomes healthy. Both changes were made after the captured
deployment and have not yet been proven by a rebuild.

**Lesson**

A successful infrastructure apply does not prove that guest bootstrap completed. When a deployment
changes the DNS server a VM needs in order to install packages, make the bootstrap tolerate the
control-plane convergence window and inspect `/var/log/cloud-init-output.log`.

---

### 19. `dnsmasq` fails with `Address already in use`

**Symptom**

The package installed, but the service failed immediately:

```text
failed to create listening socket for 0.0.0.0: Address already in use
dnsmasq.service: Failed with result 'exit-code'
```

![dnsmasq cannot bind every interface while systemd-resolved owns a local DNS socket](images/phase5-troubleshooting-dnsmasq-bind-conflict.png)

The generated file confirmed `listen-address=0.0.0.0`.

![Original dnsmasq configuration listening on all addresses](images/phase5-troubleshooting-dnsmasq-original-config.png)

**Root cause**

Ubuntu's `systemd-resolved` already listens on the loopback stub address `127.0.0.53:53`. Asking
`dnsmasq` to bind `0.0.0.0:53` includes that address, so the two services contend for the same port.
The stub is also why `nslookup` reports server `127.0.0.53` even when the actual VNet-provided
upstream is `10.0.3.4`.

**Fix**

Bind `dnsmasq` only to the workload interface:

```text
listen-address=192.168.1.4
bind-interfaces
```

After restart, `ss -luntp` showed `dnsmasq` on UDP and TCP `192.168.1.4:53`, while
`systemd-resolved` retained its loopback sockets. Terraform now declares the scoped listener in
[`terraform/locals.tf`](../terraform/locals.tf), interpolated from `local.onprem_workload_ip` so
the listener and the NIC address cannot drift apart. The screenshot validates the equivalent live
repair; the generated file has not yet been re-checked on a fresh build.

**Lesson**

Before adding a DNS daemon, inspect existing listeners with `ss -luntp | grep ':53'`. A service can
fail locally even when the network path, NSG, resolver, and forwarding rule are all correct.

---

### 20. The DNS server returns an A record followed by `SERVFAIL` or `NXDOMAIN`

**Symptom**

After fixing the listener, `nslookup app.corp.internal 192.168.1.4` printed the correct A address
and then reported `SERVFAIL`. Adding `local=/corp.internal/` changed the trailing error to
`NXDOMAIN`, but did not make the response clean.

**Root cause**

`nslookup` asks for more than one record type. The original `address=/name/IP` rule supplied the A
answer, while other queries were either forwarded into the VM's own resolver path or answered as
nonexistent under the newly local zone. One command therefore showed a valid address and an error
for a separate record query.

**Fix**

Make the namespace local and define the test name as a host record:

```text
local=/corp.internal/
host-record=app.corp.internal,192.168.1.4
```

The local query then returned one clean answer, and the same record resolved from `vm-spoke` through
the outbound resolver path.

![The corrected local DNS record returns cleanly](images/phase5-troubleshooting-dnsmasq-final-resolution.png)

**Lesson**

Read the complete DNS response, not only the first A address. Test the target DNS server locally
before debugging the outbound endpoint; otherwise an application-level DNS configuration problem
looks like a tunnel, firewall, or resolver failure.
