# Decisions

Why this lab is built the way it is. Each entry records the decision, why it was taken, what it was taken over, and what it gives up.

Kept short on purpose. The value is in the reasoning, not the ceremony.

## 1. Simulated on-premises environment

Decision: a third VNet, `vnet-onprem`, using RFC1918 space (`192.168.0.0/16`) that looks nothing like the Azure ranges, connected to the hub with a [VNet-to-VNet](https://learn.microsoft.com/azure/vpn-gateway/vpn-gateway-howto-vnet-vnet-resource-manager-portal) gateway connection.

Why: real hardware is not available, and a software VPN appliance adds a VM, its patching, its NSG rules, and a class of debugging that has nothing to do with the topology being learned. VNet-to-VNet uses the same gateways, the same IPsec, the same pre-shared key, and the same routing behaviour as site-to-site. What it skips is the on-premises equipment configuration.

Alternatives: a real [site-to-site connection](https://learn.microsoft.com/azure/vpn-gateway/tutorial-site-to-site-portal) to hardware, or a VM in Azure running strongSwan or RRAS behind a [local network gateway](https://learn.microsoft.com/azure/vpn-gateway/vpn-gateway-about-vpn-gateway-settings).

Trade-off: it is not literally site-to-site, and the README says so. There is no local network gateway resource, no BGP peering with on-premises equipment, and no exposure to the part that goes wrong most often in reality, which is the far-end device.

Notes: the address space was deliberately chosen to look like a datacenter range so the routing behaviour stays realistic.

## 2. Gateway placement

Decision: a single [VPN gateway](https://learn.microsoft.com/azure/vpn-gateway/vpn-gateway-about-vpngateways) in the hub, lent to the spoke through [peering flags](https://learn.microsoft.com/azure/vpn-gateway/vpn-gateway-peering-gateway-transit): `allow_gateway_transit` on the hub side, `use_remote_gateways` on the spoke side.

Why: this is the actual point of hub and spoke. Gateways are the expensive, slow to provision resource, so centralising one in the hub and sharing it with every spoke is the entire argument for the pattern. Building it any other way would draw the diagram without demonstrating the reason for it.

Alternatives: giving the spoke its own gateway, or connecting the spoke directly to on-premises.

Trade-off: the spoke peering has a hard ordering dependency on the hub gateway, which forces an explicit `depends_on`. Azure rejects `use_remote_gateways` if the gateway it points at does not exist yet, and the error is not especially clear about why.

## 3. Pipeline authentication to Azure

Decision: an Entra ID app registration with [federated credentials](https://learn.microsoft.com/entra/workload-id/workload-identity-federation) trusting [GitHub's OIDC issuer](https://learn.microsoft.com/azure/developer/github/connect-from-azure-openid-connect).

Why: a client secret means a long-lived credential exists in two places, expires on a date nobody has diarised, and has to be rotated by hand. OIDC means nothing long-lived is stored anywhere. GitHub mints a token per run, Azure validates it against the subject, and it dies with the job.

Alternatives: `az ad sp create-for-rbac`, dropping the resulting JSON into a GitHub secret.

Trade-off: the failure mode is worse when it breaks. A wrong secret gives a clear authentication error. A subject mismatch gives `AADSTS700213`, which means nothing until you understand what a subject claim is. This bit hard once, and it is written up in [troubleshooting.md](troubleshooting.md#2-oidc-subject-mismatch-aadsts700213).

Notes: the bootstrap script now writes both subject formats, so a fresh run produces credentials that work either way.

## 4. Pipeline permissions

Decision: a [custom role definition](https://learn.microsoft.com/azure/role-based-access-control/custom-roles), `HybridNetworkLabTFDeployer`, scoped to the subscription. Phase 4 adds a separate [Key Vault Data Access Administrator](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/security#key-vault-data-access-administrator) assignment at subscription scope.

Why: [Contributor](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles/privileged#contributor) can do essentially everything except manage access. The thing worth protecting against in an automated pipeline is a compromised or buggy workflow reaching outside its blast radius. A named role also documents what the pipeline is allowed to touch. The Key Vault role's built-in condition permits delegation only to the supported Key Vault data-plane roles, not unrestricted Owner or general role assignment.

Alternatives: assigning the built-in Contributor role.

Trade-off: the custom role grants provider-level wildcards (`Microsoft.Network/*`, `Microsoft.Compute/*`, and so on), so it is narrower than Contributor but not genuinely least privilege. The additional conditional Key Vault delegation role means the CI identity can widen Key Vault data access within that allowed role set, although it still cannot grant itself Owner or arbitrary roles. Describing the combined permissions as least privilege would overstate them.

Notes: a first cut, flagged for tightening.

## 5. Terraform state backend

Decision: state in an Azure Storage Account through the [azurerm backend](https://developer.hashicorp.com/terraform/language/backend/azurerm), [partially configured](https://developer.hashicorp.com/terraform/language/backend#partial-configuration). `backend.tf` hardcodes only the container and blob key; the resource group and storage account name are passed as `-backend-config` flags during `terraform init`.

Why: local state does not survive a CI runner and cannot be locked. Committing the storage account name puts an infrastructure detail in the repo for no benefit. Terraform Cloud would work but adds a second control plane to a project whose point is Azure.

Alternatives: committing the full backend block, or using Terraform Cloud.

Trade-off: `terraform init` cannot be run without two values that are not in the repo, so the local-run instructions are slightly more awkward.

Notes: because `use_azuread_auth` is not set, the backend does not reach blob storage as the service principal. It looks up the storage account access key through the management plane and authenticates with that. This is why the custom role needs `Microsoft.Storage/*`, and it is visible in the failure captured in [troubleshooting.md](troubleshooting.md#2-oidc-subject-mismatch-aadsts700213), where the first line of the error is `Error retrieving keys for Storage Account`. Setting `use_azuread_auth = true` and granting Storage Blob Data Contributor would remove that whole path, and is queued for change.

## 6. Topology definition

Decision: the topology in a single `local.networks` map, with [`for_each`](https://developer.hashicorp.com/terraform/language/meta-arguments/for_each) and [`flatten()`](https://developer.hashicorp.com/terraform/language/functions/flatten) producing every VNet and subnet from two resource blocks.

Why: the map reads as an address plan on its own. Adding a network becomes a data change rather than a code change.

Alternatives: nine separate resource blocks.

Trade-off: plan output is noisier, errors point at the loop rather than the offending entry, and map keys are part of the state address, so renaming a key destroys and recreates the resource. On a gateway that means 40 minutes.

Notes: the map is in [`locals.tf`](../terraform/locals.tf); the expansion is in [`modules/network/main.tf`](../terraform/modules/network/main.tf). Worth re-evaluating if individual networks start needing genuinely different treatment.

## 7. Deployment trigger

Decision: `terraform-apply.yml` triggers on [`workflow_dispatch`](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_dispatch) and on `pull_request` for a read-only plan, with a `paths` filter limiting it to `terraform/**`. There is no push trigger.

Why: the first version deployed on any push, so a typo fix in a comment kicked off a full run against Azure. Beyond the wasted spend, that makes running the pipeline feel risky, which quietly discourages committing small improvements. Separating "I changed a file" from "I want this deployed" fixes both. The pull request trigger stays because a plan is safe and genuinely useful for review, and the `paths` filter means editing documentation starts nothing at all.

Alternatives: the original setup, which applied on every push to `main`.

Trade-off: deployment is no longer automatic, so `main` can be ahead of what is actually running in Azure. For a lab that is the right way round. For a production system it would need drift detection.

Notes: this change introduced a bug. The apply step's `if` was left checking for `github.event_name == 'push'`. With push gone as a trigger the step could never run, and the job still reported success. Fixed in Phase 0, and written up in [troubleshooting.md](troubleshooting.md#7-apply-step-silently-skipped) because a pipeline that fails by succeeding is worth recognising.

## 8. Teardown

Decision: `terraform-destroy.yml`, [manual trigger](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_dispatch) only.

Why: teardown has to be as easy as deployment or it does not happen. Running it through the same pipeline also means it goes through the same state file, so state stays consistent instead of drifting after a portal deletion.

Alternatives: relying on `az group delete`, or running [`terraform destroy`](https://developer.hashicorp.com/terraform/cli/commands/destroy) from a local machine.

Trade-off: it is a one-click, `-auto-approve`, no-confirmation destroy sitting next to the deploy button in the same menu. Fine for a lab. A typed-confirmation input would be sensible before this pattern went near an environment that mattered. The workflow also does not pin a Terraform version, unlike the apply workflow, which is an inconsistency worth fixing.

Notes: run end to end, removing all 19 resources in roughly 17 minutes. That number is also the first authoritative count of what the lab consists of, and it matches the README inventory. Screenshots in [worklog.md](worklog.md#stage-4-stop-the-pipeline-from-burning-credits).

## 9. Gateway and public IP SKUs

Decision: [`VpnGw1AZ`](https://learn.microsoft.com/azure/vpn-gateway/about-gateway-skus) gateways and [zone-redundant](https://learn.microsoft.com/azure/reliability/availability-zones-overview) Standard public IPs with `zones = ["1", "2", "3"]`.

Why: not really a choice. Azure has [retired Basic SKU public IPs](https://learn.microsoft.com/azure/virtual-network/ip-services/public-ip-basic-upgrade-guidance) and non-AZ gateway SKUs for new deployments, and both surfaced as apply failures rather than as anything visible up front. Once the gateway is AZ, Azure additionally requires its public IP to have zones configured, which was a third failure discovered only after fixing the first two.

Alternatives: `VpnGw1` and Basic public IPs, which is what the config originally used and is no longer offered for new deployments.

Trade-off: none available. There is no cheaper or simpler path still open, which is what makes this a forced decision rather than a real one. Recording it matters anyway, because the config now contains three settings that look arbitrary without the history.

Notes: all three failures are in [troubleshooting.md](troubleshooting.md).

## 10. VPN pre-shared key

Decision: `VPN_SHARED_KEY` as a [GitHub repository secret](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets), injected as the environment variable `TF_VAR_vpn_shared_key`, declared [`sensitive = true`](https://developer.hashicorp.com/terraform/language/values/variables#sensitive-values-in-variables) in `variables.tf`.

Why: it keeps the key out of the repository with no additional infrastructure, and the `sensitive` flag keeps it out of plan output and logs.

Alternatives: hardcoding it, or reading it from Key Vault.

Trade-off: the key sits in plain text [inside the Terraform state file](https://developer.hashicorp.com/terraform/language/state/sensitive-data). That is unavoidable, it is how Terraform works, and Key Vault would not change it. It is the reason state protection is the control that actually matters here, rather than where the key is sourced from.

Notes: revisited in phase 4. Moving the key into Key Vault was originally on the plan, on the grounds that it makes rotation an Azure operation rather than a repository settings change. It is not going to happen, and the reason is worth recording: Terraform needs the key at plan time, and a vault Terraform can read from CI is a vault that cannot have public access disabled. See [decision 14](#14-key-vault-access-from-terraform).

## 11. Subnet reservation

Decision: reserve the service-specific subnets, [`AzureFirewallSubnet`](https://learn.microsoft.com/azure/firewall/firewall-faq) and [`AzureBastionSubnet`](https://learn.microsoft.com/azure/bastion/configuration-settings), before deploying Azure Firewall and Bastion.

Why: both services require subnets with exact names and minimum sizes. Carving the address space up front means the plan does not have to be renegotiated later, and the address plan reads as intentional rather than as whatever was left over.

Alternatives: adding each subnet at the same time as its service.

Trade-off: the base network initially contained empty service subnets, which could make the topology look more complete than it was.

Notes: `AzureFirewallSubnet` is now occupied in the Sweden Central hub. During Phase 3, Bastion moved with the simulated on-premises environment to `AzureBastionSubnet` (`192.168.2.0/26`) in Denmark East. The same reservation pattern extends to the DNS resolver and private endpoint subnets.

## 12. Regions

Decision: keep the hub and spoke in `swedencentral`, and place the simulated on-premises VNet, gateway, VM, and Bastion in `denmarkeast`.

Why: Sweden Central offers low latency from the operator and supports the [zones](https://learn.microsoft.com/azure/reliability/availability-zones-overview) required by the selected AZ gateway and chosen for the firewall deployment. Denmark East separates the simulated datacenter from the Azure estate and avoids concentrating all public-IP-consuming services under one [regional quota](https://learn.microsoft.com/azure/azure-resource-manager/management/azure-subscription-service-limits#azure-networking-limits).

Alternatives: keeping everything in one region, which is how the lab started.

Trade-off: the cross-region tunnel adds latency and makes per-resource location part of the module interface. Anyone redeploying elsewhere must check SKU availability, availability-zone support, and regional quota in both regions.

Notes: adopted during Phase 3 after Sweden Central returned `PublicIPCountLimitReached` for the firewall public IP. The migration itself is [decision 15](#15-on-premises-region-migration).

## 13. Firewall SKU

Decision: [Azure Firewall Standard](https://learn.microsoft.com/azure/firewall/choose-firewall-sku) with a Standard firewall policy.

Why: three things get in the way of [Basic](https://learn.microsoft.com/azure/firewall/features-by-sku). It requires a second dedicated subnet, `AzureFirewallManagementSubnet` at /26 minimum, on top of `AzureFirewallSubnet`. It is available in limited regions rather than all of them. And it has no [DNS proxy](https://learn.microsoft.com/azure/firewall/dns-details). That last one decides it: Phase 5 is entirely about DNS, and Standard preserves the option to enable DNS proxy so FQDN-based firewall rules can resolve the same names as the rest of the network.

Alternatives: Basic, which is explicitly positioned for dev, test, and small workloads, and looks like the obvious lab choice.

Trade-off: more per hour than Basic, and Basic would have been adequate for everything phase 3 alone needs. This is paying in phase 3 to avoid rework in phase 5.

Notes: DNS proxy is not enabled in Phase 3. Choosing Basic then would have removed that Phase 5 capability or forced a firewall redesign later. Deployed with a zone-redundant public IP, symmetric UDRs, and diagnostic logging.

## 14. Key Vault access from Terraform

Decision: deploy Key Vault with [public network access disabled](https://learn.microsoft.com/azure/key-vault/general/network-security) and reachable only through a [private endpoint](https://learn.microsoft.com/azure/key-vault/general/private-link-service). Terraform manages the vault, endpoint, DNS, managed identity, and [vault-scoped role assignment](https://learn.microsoft.com/azure/key-vault/general/rbac-guide), but it does not create or read secret data. The spoke VM validates access at runtime using its system-assigned managed identity.

Why: with public access disabled, only callers inside the virtual network or arriving over a private endpoint reach the data plane. A GitHub-hosted runner is on the public internet and outside the VNet. Key Vault's trusted-services bypass does not cover CI services, and Microsoft's documented workarounds are a self-hosted agent inside the VNet or an IP allowlist entry. Neither is appealing: one adds infrastructure whose only job is to run the pipeline, the other pokes a permanent hole in the thing being demonstrated.

Alternatives: having Terraform read the secret at plan time, which is the more obvious design.

Trade-off: a secret cannot be used as a Terraform input or seeded by the hosted pipeline. Anything Terraform genuinely needs at plan time has to come from somewhere else. In practice that is one thing, the VPN pre-shared key, which is why [decision 10](#10-vpn-pre-shared-key) stands. It also makes Phase 4 depend on Phase 2, since without a VM there is no private caller and no useful proof.

Notes: the first implementation tried to split the difference by having Terraform write `demo-secret` but never read it. That does not work as a lifecycle rule: the provider calls `GetSecret` while checking existing state, and the apply failed with `ForbiddenByRbac`. Even granting that permission would leave the hosted runner outside the vault's private network. Moving all Key Vault secret data operations out of Terraform removes the conflict rather than working around it, and it happens to be the pattern worth showing. The Phase 4 test uses a successful list request with an empty result, which proves DNS, Private Link transport, token issuance, and RBAC without a demo secret. The initial secret resource was removed after the failed apply, and `vm-spoke` now receives `Key Vault Secrets User` at vault scope and returns HTTP 200 over `conn_type=PrivateLink`.

## 15. On-premises region migration

Decision: move the simulated on-premises VNet, VPN gateway, workload VM, and Bastion to Denmark East while keeping the Azure hub and spoke in Sweden Central.

Why: Phase 3 exhausted the Sweden Central [public IP quota](https://learn.microsoft.com/azure/azure-resource-manager/management/azure-subscription-service-limits#azure-networking-limits) when Azure Firewall was added. The move distributes the VPN gateway, firewall, and Bastion public IPs across two regions without weakening the design.

Alternatives: requesting a higher Sweden Central public-IP quota, or removing a public-IP-consuming service.

Trade-off: modules and resources must use per-network locations rather than assuming one root location, and the VNet-to-VNet tunnel now crosses regions.

Notes: the topology now represents two geographically separate environments, Azure workloads in Sweden and a simulated datacenter in Denmark. Keeping Bastion on the Denmark side also models an administrator entering from the on-premises environment before reaching cloud workloads across the tunnel.

## 16. Hybrid name resolution

Decision: [Azure DNS Private Resolver](https://learn.microsoft.com/azure/dns/dns-private-resolver-overview) in the hub, with [inbound endpoint](https://learn.microsoft.com/azure/dns/private-resolver-endpoints-rulesets) `10.0.3.4` for Azure private names and an outbound endpoint plus forwarding ruleset for `corp.internal.`.

Why: a direct VNet link only works because the simulated datacenter happens to be an Azure VNet. Real on-premises DNS cannot attach to an Azure Private DNS zone. The resolver exposes a private IP that a site DNS server can forward to, while the outbound path lets Azure query namespaces owned by the site. It therefore demonstrates [the boundary in both directions](https://learn.microsoft.com/azure/dns/private-resolver-hybrid-dns) without maintaining another DNS VM in the hub.

Alternatives: directly [linking](https://learn.microsoft.com/azure/dns/private-dns-virtual-network-links) the Key Vault private DNS zone to `vnet-onprem`, or running a general DNS-forwarder VM in the Azure hub.

Trade-off: the resolver requires two dedicated delegated `/28` subnets, a ruleset and links, and working UDP and TCP 53 paths to the on-premises DNS target. DNS changes also depend on DHCP renewal or a VM restart before guests use the new VNet DNS setting.

Notes: the temporary direct on-premises private-zone link was removed before the negative baseline was recorded.

## Appendix: services used, and what else could have been used

Every Azure capability this lab deploys, with the docs for it and the realistic
alternative that was passed over. "Alternative" means an option that would actually
have worked here, not an exhaustive list. The numbered decisions above explain *why*
for the choices that were close calls.

### Topology and connectivity

| Used | Role in this lab | Docs | Alternative |
| --- | --- | --- | --- |
| Virtual Network + subnets | Hub, spoke, and the simulated datacenter | [Hub-and-spoke topology](https://learn.microsoft.com/azure/networking/design-guide/hub-spoke) | [Azure Virtual WAN](https://learn.microsoft.com/azure/networking/design-guide/virtual-wan): a Microsoft-managed hub, worth it past ~30 branches |
| VNet peering with gateway transit | Spoke borrows the hub gateway | [Hub-spoke design guide](https://learn.microsoft.com/azure/networking/design-guide/hub-spoke) | A gateway per VNet, or [Virtual WAN](https://learn.microsoft.com/azure/virtual-wan/virtual-wan-about) connections |
| VPN Gateway `VpnGw1AZ`, VNet-to-VNet | IPsec tunnel to "on-prem" | [VNet-to-VNet](https://learn.microsoft.com/azure/vpn-gateway/vpn-gateway-howto-vnet-vnet-resource-manager-portal), [gateway SKUs](https://learn.microsoft.com/azure/vpn-gateway/about-gateway-skus) | [ExpressRoute](https://learn.microsoft.com/azure/expressroute/expressroute-introduction): a private circuit, weeks to provision ([comparison](https://learn.microsoft.com/azure/networking/hybrid-connectivity/hybrid-connectivity#compare-vpn-gateway-and-expressroute)) |

### Traffic control

| Used | Role in this lab | Docs | Alternative |
| --- | --- | --- | --- |
| Network security groups | Subnet-level allow/deny | [NSG overview](https://learn.microsoft.com/azure/virtual-network/network-security-groups-overview) | [AVNM security admin rules](https://learn.microsoft.com/azure/virtual-network-manager/concept-security-admins): central, evaluated before NSGs |
| Route tables (UDR) | Force spoke and gateway traffic to the firewall | [Service tags](https://learn.microsoft.com/azure/virtual-network/service-tags-overview) | [AVNM-managed UDRs](https://learn.microsoft.com/azure/virtual-network-manager/how-to-create-user-defined-route), or BGP over the gateway |
| Azure Firewall Standard + Firewall Policy | Central inspection, FQDN and network rules | [Overview](https://learn.microsoft.com/azure/firewall/overview), [choose a SKU](https://learn.microsoft.com/azure/firewall/choose-firewall-sku) | [Basic](https://learn.microsoft.com/azure/firewall/features-by-sku) (needs a management subnet, no DNS proxy), Premium (IDPS, TLS inspection), a third-party NVA, or NSGs alone |
| Azure Bastion Standard | Browser SSH without public IPs on VMs | [Overview](https://learn.microsoft.com/azure/bastion/bastion-overview), [SKU comparison](https://learn.microsoft.com/azure/bastion/bastion-sku-comparison) | Developer SKU (free, one VM), Premium (no public IP at all), or [P2S VPN / just-in-time access](https://learn.microsoft.com/azure/networking/design-guide/developer-admin-access) |

### Name resolution

| Used | Role in this lab | Docs | Alternative |
| --- | --- | --- | --- |
| Private DNS zone + VNet links | Resolves the Key Vault private endpoint | [Azure Private DNS](https://learn.microsoft.com/azure/dns/private-dns-overview), [virtual network links](https://learn.microsoft.com/azure/dns/private-dns-virtual-network-links) | Host records on a custom DNS server |
| DNS Private Resolver (inbound, outbound, ruleset) | Two-way hybrid resolution across the tunnel | [Overview](https://learn.microsoft.com/azure/dns/dns-private-resolver-overview), [endpoints and rulesets](https://learn.microsoft.com/azure/dns/private-resolver-endpoints-rulesets), [hybrid DNS](https://learn.microsoft.com/azure/dns/private-resolver-hybrid-dns) | A DNS forwarder VM in the hub, Azure Firewall DNS proxy, or linking the private zone straight to on-prem. See [decision 16](#16-hybrid-name-resolution) |
| Private endpoint DNS records | `privatelink.vaultcore.azure.net` | [Private endpoint DNS](https://learn.microsoft.com/azure/private-link/private-endpoint-dns) | Manual A records, which drift |

### Identity and secrets

| Used | Role in this lab | Docs | Alternative |
| --- | --- | --- | --- |
| Key Vault (standard) behind a private endpoint | Secret store with no public access | [About Key Vault](https://learn.microsoft.com/azure/key-vault/general/overview), [Key Vault + Private Link](https://learn.microsoft.com/azure/key-vault/general/private-link-service) | Premium (HSM-backed keys), or App Configuration for non-secrets |
| Private Endpoint / Private Link | Private IP for the vault | [Private Link overview](https://learn.microsoft.com/azure/private-link/private-link-overview) | [Service endpoints](https://learn.microsoft.com/azure/virtual-network/vnet-integration-for-azure-services#compare-private-endpoints-and-service-endpoints): free, but no on-prem reach and no per-instance scoping |
| System-assigned managed identity on the VM | Vault access without credentials | [Managed identities](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/overview) | User-assigned, if the identity should outlive the VM |
| Custom RBAC role for the pipeline | Least privilege for CI | [Azure RBAC](https://learn.microsoft.com/azure/role-based-access-control/overview) | Built-in Contributor: simpler, far broader. See [decision 4](#4-pipeline-permissions) |
| OIDC federation for GitHub Actions | No stored cloud credential | [Workload identity federation](https://learn.microsoft.com/entra/workload-id/workload-identity-federation) | Service principal client secret, which expires and leaks. See [decision 3](#3-pipeline-authentication-to-azure) |

### Delivery and observability

| Used | Role in this lab | Docs | Alternative |
| --- | --- | --- | --- |
| Terraform, `azurerm` provider, local modules | The whole deployment | [Terraform on Azure](https://learn.microsoft.com/azure/developer/terraform/overview) | [Bicep](https://learn.microsoft.com/azure/azure-resource-manager/bicep/deploy-to-resource-group), the [AzAPI provider](https://learn.microsoft.com/azure/developer/terraform/overview-azapi-provider) for new resource types, or [Azure Verified Modules](https://azure.github.io/Azure-Verified-Modules/) instead of hand-rolled ones |
| `azurerm` backend, partially configured | Shared state, locked | [Store state in Azure Storage](https://learn.microsoft.com/azure/developer/terraform/store-state-in-azure-storage) | Local state (no locking), or Terraform Cloud. See [decision 5](#5-terraform-state-backend) |
| Log Analytics workspace + diagnostic settings | Firewall logs | [Diagnostic settings](https://learn.microsoft.com/azure/azure-monitor/platform/diagnostic-settings) | [Storage or Event Hubs](https://learn.microsoft.com/azure/azure-monitor/essentials/resource-logs) as the sink |
| Firewall rule logs | Proving traffic hit the rules | [Diagnostic settings](https://learn.microsoft.com/azure/azure-monitor/platform/diagnostic-settings) | [VNet flow logs](https://learn.microsoft.com/azure/network-watcher/vnet-flow-logs-overview) + [Traffic Analytics](https://learn.microsoft.com/azure/network-watcher/traffic-analytics) for flow-level visibility |
