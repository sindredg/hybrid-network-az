# Decisions

Why this lab is built the way it is. Each entry answers one question: what was chosen, what it was chosen over, and what it gives up.

Kept short on purpose. The value is in the reasoning, not the ceremony.

---

## 1. Why simulate on-premises with a second Azure VNet?

**Chosen:** a third VNet, `vnet-onprem`, using RFC1918 space (`192.168.0.0/16`) that looks nothing like the Azure ranges, connected to the hub with a VNet-to-VNet gateway connection.

**Over:** a real site-to-site connection to hardware, or a VM in Azure running strongSwan or RRAS behind a local network gateway.

**Why:** real hardware is not available, and a software VPN appliance adds a VM, its patching, its NSG rules and a class of debugging that has nothing to do with the topology being learned. VNet-to-VNet uses the same gateways, the same IPsec, the same pre-shared key and the same routing behaviour as site-to-site. What it skips is the on-premises equipment configuration.

**Trade-off:** it is not literally site-to-site, and the README says so. There is no local network gateway resource, no BGP peering with on-premises equipment, and no exposure to the part that goes wrong most often in reality, which is the far-end device. The address space was deliberately chosen to look like a datacenter range so the routing behaviour stays realistic.

**Status:** accepted, with the caveat documented.

---

## 2. Why one shared gateway in the hub instead of one per VNet?

**Chosen:** a single VPN gateway in the hub, lent to the spoke through peering flags: `allow_gateway_transit` on the hub side, `use_remote_gateways` on the spoke side.

**Over:** giving the spoke its own gateway, or connecting the spoke directly to on-premises.

**Why:** this is the actual point of hub-and-spoke. Gateways are the expensive, slow-to-provision resource, so centralising one in the hub and sharing it with every spoke is the entire argument for the pattern. Building it any other way would draw the diagram without demonstrating the reason for it.

**Trade-off:** the spoke peering has a hard ordering dependency on the hub gateway, which forces an explicit `depends_on`. Azure rejects `use_remote_gateways` if the gateway it points at does not exist yet, and the error is not especially clear about why.

**Status:** accepted.

---

## 3. Why OIDC federation instead of a service principal secret?

**Chosen:** an Entra ID app registration with federated credentials trusting GitHub's OIDC issuer.

**Over:** `az ad sp create-for-rbac`, dropping the resulting JSON into a GitHub secret.

**Why:** the secret version means a long-lived credential exists in two places, expires on a date nobody has diarised, and has to be rotated by hand. OIDC means nothing long-lived is stored anywhere. GitHub mints a token per run, Azure validates it against the subject, and it dies with the job.

**Trade-off:** the failure mode is worse when it breaks. A wrong secret gives a clear authentication error. A subject mismatch gives `AADSTS700213`, which means nothing until you understand what a subject claim is. This bit hard once, and it is written up in [troubleshooting.md](troubleshooting.md#2-oidc-subject-mismatch-aadsts700213).

**Status:** accepted. The bootstrap script now writes both subject formats, so a fresh run produces credentials that work either way.

---

## 4. Why a custom RBAC role instead of Contributor?

**Chosen:** a role definition, `HybridNetworkLabTFDeployer`, scoped to the subscription.

**Over:** assigning the built-in Contributor role.

**Why:** Contributor can do essentially everything except manage access. The thing worth protecting against in an automated pipeline is a compromised or buggy workflow reaching outside its blast radius. A named role also documents what the pipeline is allowed to touch. Phase 4 adds a separate `Key Vault Data Access Administrator` assignment at subscription scope; its built-in condition permits delegation only to the supported Key Vault data-plane roles, not unrestricted Owner or general role assignment.

**Trade-off:** the custom role grants provider-level wildcards (`Microsoft.Network/*`, `Microsoft.Compute/*`, and so on), so it is narrower than Contributor but not genuinely least-privilege. The additional conditional Key Vault delegation role means the CI identity can widen Key Vault data access within that allowed role set, although it still cannot grant itself Owner or arbitrary roles. Describing the combined permissions as least-privilege would overstate them.

**Status:** accepted as a first cut, flagged for tightening.

---

## 5. Why is the backend only partially configured?

**Chosen:** state in an Azure Storage Account. `backend.tf` hardcodes only the container and blob key; the resource group and storage account name are passed as `-backend-config` flags during `terraform init`.

**Over:** committing the full backend block, or using Terraform Cloud.

**Why:** local state does not survive a CI runner and cannot be locked. Committing the storage account name puts an infrastructure detail in the repo for no benefit. Terraform Cloud would work but adds a second control plane to a project whose point is Azure.

**Trade-off:** `terraform init` cannot be run without two values that are not in the repo, so the local-run instructions are slightly more awkward.

**Worth knowing:** because `use_azuread_auth` is not set, the backend does not reach blob storage as the service principal. It looks up the storage account access key through the management plane and authenticates with that. This is why the custom role needs `Microsoft.Storage/*`, and it is visible in the failure captured in [troubleshooting.md](troubleshooting.md#2-oidc-subject-mismatch-aadsts700213), where the first line of the error is `Error retrieving keys for Storage Account`. Setting `use_azuread_auth = true` and granting Storage Blob Data Contributor would remove that whole path.

**Status:** accepted, with the auth mode queued for change.

---

## 6. Why drive the whole topology from one map?

**Chosen:** the topology in a single `local.networks` map, with `for_each` and `flatten()` producing every VNet and subnet from two resource blocks.

**Over:** nine separate resource blocks.

**Why:** the map reads as an address plan on its own. Adding a network becomes a data change rather than a code change.

**Trade-off:** plan output is noisier, errors point at the loop rather than the offending entry, and map keys are part of the state address, so renaming a key destroys and recreates the resource. On a gateway that means 40 minutes. Written up in full in [terraform-patterns.md](terraform-patterns.md).

**Status:** accepted. Worth re-evaluating if individual networks start needing genuinely different treatment.

---

## 7. Why does deployment need a button press?

**Chosen:** `terraform-apply.yml` triggers on `workflow_dispatch` and on `pull_request` for a read-only plan. There is no push trigger.

**Over:** the original setup, which applied on every push to `main`.

**Why:** the first version deployed on any push, so a typo fix in a comment kicked off a full run against Azure. Beyond the wasted spend, that makes running the pipeline feel risky, which quietly discourages committing small improvements. Separating "I changed a file" from "I want this deployed" fixes both. The pull request trigger stays because a plan is safe and genuinely useful for review, and a `paths` filter limits it to `terraform/**` so editing documentation starts nothing at all.

**Trade-off:** deployment is no longer automatic, so `main` can be ahead of what is actually running in Azure. For a lab that is the right way round. For a production system it would need drift detection.

**Bug this change introduced:** the apply step's `if` was left checking for `github.event_name == 'push'`. With push gone as a trigger the step could never run, and the job still reported success. Fixed in Phase 0, and written up in [troubleshooting.md](troubleshooting.md#7-apply-step-silently-skipped) because a pipeline that fails by succeeding is worth recognising.

**Status:** accepted, and now implemented correctly.

---

## 8. Why a separate destroy workflow?

**Chosen:** `terraform-destroy.yml`, manual trigger only.

**Over:** relying on `az group delete`, or destroying from a local machine.

**Why:** teardown has to be as easy as deployment or it does not happen. Running it through the same pipeline also means it goes through the same state file, so state stays consistent instead of drifting after a portal deletion.

**Trade-off:** it is a one-click, `-auto-approve`, no-confirmation destroy sitting next to the deploy button in the same menu. Fine for a lab. A typed-confirmation input would be sensible before this pattern went near an environment that mattered. The workflow also does not pin a Terraform version, unlike the apply workflow, which is an inconsistency worth fixing.

**Since verified:** run end to end, removing all 19 resources in roughly 17 minutes. That number is also the first authoritative count of what the lab consists of, and it matches the README inventory. Screenshots in [worklog.md](worklog.md#stage-4-stop-the-pipeline-from-burning-credits).

**Status:** accepted with reservations, and proven to work.

---

## 9. Why these gateway and public IP SKUs?

**Chosen:** `VpnGw1AZ` gateways and zone-redundant Standard public IPs with `zones = ["1", "2", "3"]`.

**Over:** `VpnGw1` and Basic public IPs, which is what the config originally used.

**Why:** not really a choice. Azure has retired Basic SKU public IPs and non-AZ gateway SKUs for new deployments, and both surfaced as apply failures rather than as anything visible up front. Once the gateway is AZ, Azure additionally requires its public IP to have zones configured, which was a third failure discovered only after fixing the first two. All three are in [troubleshooting.md](troubleshooting.md).

**Trade-off:** none available. There is no cheaper or simpler path still open, which is what makes this a forced decision rather than a real one. Recording it matters anyway, because the config now contains three settings that look arbitrary without the history.

**Status:** forced, accepted.

---

## 10. Where does the VPN pre-shared key live, and why?

**Chosen:** `VPN_SHARED_KEY` as a GitHub repository secret, injected as the environment variable `TF_VAR_vpn_shared_key`, declared `sensitive = true` in `variables.tf`.

**Over:** hardcoding it, or reading it from Key Vault.

**Why:** it keeps the key out of the repository with no additional infrastructure, and the `sensitive` flag keeps it out of plan output and logs.

**Trade-off:** the key sits in plain text inside the Terraform state file. That is unavoidable, it is how Terraform works, and Key Vault would not change it. It is the reason state protection is the control that actually matters here, rather than where the key is sourced from.

**Revisited in phase 4.** Moving the key into Key Vault was originally on the plan, on the grounds that it makes rotation an Azure operation rather than a repository settings change. It is not going to happen, and the reason is worth recording: Terraform needs the key at plan time, and a vault Terraform can read from CI is a vault that cannot have public access disabled. See [decision 14](#14-why-does-terraform-never-read-from-key-vault).

**Status:** accepted, and now a deliberate choice rather than a deferred improvement.

---

## 11. Why create the firewall and Bastion subnets before the services?

**Chosen:** reserve the service-specific subnets before deploying Azure Firewall and Bastion.

**Over:** adding each subnet at the same time as its service.

**Why:** both services require subnets with exact names and minimum sizes. Carving the address space up front means the plan does not have to be renegotiated later, and the address plan reads as intentional rather than as whatever was left over.

**Trade-off:** the base network initially contained empty service subnets, which could make the topology look more complete than it was.

**Status:** implemented. `AzureFirewallSubnet` is now occupied in the Sweden Central hub. During Phase 3, Bastion moved with the simulated on-premises environment to `AzureBastionSubnet` (`192.168.2.0/26`) in Denmark East. The same reservation pattern extends to the DNS resolver and private endpoint subnets in [plan.md](../plan.md) item 0.4.

---

## 12. Why Sweden Central for Azure and Denmark East for on-prem?

**Chosen:** keep the hub and spoke in `swedencentral`, and place the simulated on-premises VNet, gateway, VM, and Bastion in `denmarkeast`.

**Why:** Sweden Central offers low latency from the operator and supports the zones required by the selected AZ gateway and chosen for the firewall deployment. Denmark East separates the simulated datacenter from the Azure estate and avoids concentrating all public-IP-consuming services under one regional quota.

**Trade-off:** the cross-region tunnel adds latency and makes per-resource location part of the module interface. Anyone redeploying elsewhere must check SKU availability, availability-zone support, and regional quota in both regions.

**Status:** implemented during Phase 3 after Sweden Central returned `PublicIPCountLimitReached` for the firewall public IP.

---

## 13. Why Azure Firewall Standard rather than Basic?

**Chosen:** Azure Firewall Standard.

**Over:** Basic, which is explicitly positioned for dev, test and small workloads, and looks like the obvious lab choice.

**Why:** three things get in the way of Basic. It requires a second dedicated subnet, `AzureFirewallManagementSubnet` at /26 minimum, on top of `AzureFirewallSubnet`. It is available in limited regions rather than all of them. And it has no DNS proxy.

That last one decides it. Phase 5 is entirely about DNS, and Standard preserves the option to enable DNS proxy so FQDN-based firewall rules can resolve the same names as the rest of the network. DNS proxy is not enabled in Phase 3; choosing Basic now would remove that Phase 5 capability or require a firewall redesign later.

**Trade-off:** more per hour than Basic, and Basic would have been adequate for everything phase 3 alone needs. This is paying in phase 3 to avoid rework in phase 5.

**Status:** implemented in Phase 3 with a Standard firewall policy, zone-redundant public IP, symmetric UDRs, and diagnostic logging.

---

## 14. Why does Terraform never read from Key Vault?

**Chosen:** deploy Key Vault with public network access disabled and reachable only through a private endpoint. Terraform manages the vault, endpoint, DNS, managed identity, and vault-scoped role assignment, but it does not create or read secret data. The spoke VM validates access at runtime using its system-assigned managed identity.

**Over:** having Terraform read the secret at plan time, which is the more obvious design.

**Why:** those two things cannot both be true. With public access disabled, only callers inside the virtual network or arriving over a private endpoint reach the data plane. A GitHub-hosted runner is on the public internet and outside the VNet. Key Vault's trusted-services bypass does not cover CI services, and Microsoft's documented workarounds are a self-hosted agent inside the VNet or an IP allowlist entry. Neither is appealing: one adds infrastructure whose only job is to run the pipeline, the other pokes a permanent hole in the thing being demonstrated.

The first implementation tried to split the difference by having Terraform write `demo-secret` but never read it. That does not work as a lifecycle rule: the provider calls `GetSecret` while checking existing state, and the apply failed with `ForbiddenByRbac`. Even granting that permission would leave the hosted runner outside the vault's private network.

Moving all Key Vault secret data operations out of Terraform removes the conflict rather than working around it, and it happens to be the pattern worth showing. A VM authenticating with a managed identity over a private link, with no Key Vault credential stored in the repository or VM, is a better demonstration than a pipeline fetching a secret. The Phase 4 test uses a successful list request with an empty result, which proves DNS, Private Link transport, token issuance, and RBAC without a demo secret. The VPN pre-shared key remains in protected Terraform state as recorded in decision 10.

**Trade-off:** a secret cannot be used as a Terraform input or seeded by the hosted pipeline. Anything Terraform genuinely needs at plan time has to come from somewhere else. In practice that is one thing, the VPN pre-shared key, which is why [decision 10](#10-where-does-the-vpn-pre-shared-key-live-and-why) stands. It also makes Phase 4 depend on Phase 2, since without a VM there is no private caller and no useful proof.

**Status:** implemented and validated in Phase 4. The initial secret resource was removed after the failed apply; `vm-spoke` now receives `Key Vault Secrets User` at vault scope and returns HTTP 200 over `conn_type=PrivateLink`.

---

## 15. Why migrate "on-prem" from Sweden Central to Denmark East?

**Chosen:** move the simulated on-premises VNet, VPN gateway, workload VM, and Bastion to Denmark East while keeping the Azure hub and spoke in Sweden Central.

**Over:** requesting a higher Sweden Central public-IP quota or removing a public-IP-consuming service.

**Why:** Phase 3 exhausted the Sweden Central public-IP quota when Azure Firewall was added. The move distributes the VPN gateway, firewall, and Bastion public IPs across two regions without weakening the design.

**Gain:** the topology now represents two geographically separate environments: Azure workloads in Sweden and a simulated datacenter in Denmark. Keeping Bastion on the Denmark side also models an administrator entering from the on-premises environment before reaching cloud workloads across the tunnel.

**Trade-off:** modules and resources must use per-network locations rather than assuming one root location, and the VNet-to-VNet tunnel now crosses regions.

**Status:** implemented and validated in Phase 3.
