# Plan

Where this lab goes next, in the order it should be built.

The sequencing rule is that **each phase must be provable before the next begins**. Phase 3 is meaningless without phase 2 to observe, phase 5 has nothing to resolve without phase 4. Building them out of order produces resources that exist but demonstrate nothing.

Short version of where things stand: phases 0, 1 and 2 are done. The tunnel carries real traffic, gateway transit is confirmed by effective-route lookup rather than assumed, and the NSGs have been proven scoped rule by rule. What is missing is any control over where traffic goes once it is inside.

---

## Constraints that shape all of this

Verified against Microsoft's documentation rather than assumed. Several of these change the design rather than just the detail.

| Constraint | Consequence here |
|---|---|
| `AzureFirewallSubnet` needs /26 minimum | Current /24 is fine |
| `AzureBastionSubnet` needs /26 minimum (deployments after Nov 2021) | Current /24 is fine |
| Firewall **Basic** needs a second `AzureFirewallManagementSubnet` (/26), has **no DNS proxy**, and is in limited regions | Pushes phase 3 toward Standard |
| NSGs are **not supported** on `GatewaySubnet` and can stop the gateway working | Phase 3 puts NSGs on workload subnets only |
| Route tables belong on **workload** subnets, not the firewall subnet | Shapes the phase 3 UDR design |
| DNS resolver endpoints need dedicated subnets, /28 minimum, delegated to `Microsoft.Network/dnsResolvers`, nothing else in them | The current subnet map cannot express this, see 0.3 |
| A Key Vault with public access disabled **blocks CI runners outside the VNet**, and GitHub Actions is not a trusted service | Drives the whole phase 4 design |
| Private endpoints consume IPs from an ordinary subnet | A dedicated subnet is for clarity, not a requirement |

---

## Phase 0: Fix what is broken, before the next apply

**Done.** The apply step runs, the orphaned public IP is gone, the subnet map carries per-subnet settings, `outputs.tf` exists, both workflows share a concurrency group, the destroy workflow is version-pinned, and the bootstrap script writes immutable OIDC subjects. Nine subnets, two public IPs, 21 resources. Written up in [worklog.md](docs/worklog.md#phase-0-prerequisites-and-pipeline-fixes).

Kept below because the reasoning is still the record of why each change was made.

### 0.1 The apply step can never run

[`.github/workflows/terraform-apply.yml:58`](.github/workflows/terraform-apply.yml) gates the apply on:

```yaml
if: github.ref == 'refs/heads/main' && github.event_name == 'push'
```

The triggers are `workflow_dispatch` and `pull_request`. `push` is not among them, so the condition can never be true. GitHub skips the step and reports the job as successful, which is the dangerous part. The trigger change itself was deliberate and correct; only this leftover condition needs updating:

```yaml
if: github.event_name == 'workflow_dispatch'
```

Worth pairing with a GitHub Environment carrying a required reviewer, so the apply needs a deliberate approval click. That restores the protection the old push-gate only appeared to give.

### 0.2 Orphaned public IP

`azurerm_public_ip.vpn_pip` loops over `local.networks`, which has three entries, but only two networks have a gateway. `pip-vpn-spoke` is created and billed for nothing.

Fix as part of 0.3 rather than separately: add a `has_gateway` flag to the map and filter on it, keeping the DRY pattern intact instead of hardcoding two resources.

### 0.3 Restructure the network map

`locals.tf` models a subnet as `name = prefix`, a bare string. Phase 5 needs subnet delegation and phase 3 needs per-subnet route tables and NSGs. Neither fits.

This is exactly the leak predicted in [terraform-patterns.md](docs/terraform-patterns.md#honest-trade-offs). Fix it by enriching the data, not by abandoning the pattern:

```hcl
hub = {
  name          = "vnet-hub"
  address_space = ["10.0.0.0/16"]
  has_gateway   = true
  subnets = {
    GatewaySubnet       = { prefix = "10.0.0.0/24" }
    AzureFirewallSubnet = { prefix = "10.0.1.0/24" }
    AzureBastionSubnet  = { prefix = "10.0.2.0/24" }
    snet-dns-inbound    = { prefix = "10.0.3.0/28",  delegation = "Microsoft.Network/dnsResolvers" }
    snet-dns-outbound   = { prefix = "10.0.3.16/28", delegation = "Microsoft.Network/dnsResolvers" }
  }
}
```

Composite keys (`hub-GatewaySubnet`) stay identical, so existing state addresses are stable and nothing is destroyed and recreated. Only the value shape changes: `address_prefix = v.prefix`, plus `delegation = try(v.delegation, null)` and a `dynamic "delegation"` block on `azurerm_subnet`.

This approach has been evaluated offline: it validates, and the flatten produces nine subnets with delegation on exactly the two DNS ones.

### 0.4 Decide the whole address plan once

Every later phase adds subnets. Deciding them now avoids renumbering later. Carving space ahead of the service follows the reasoning already recorded for the firewall and Bastion subnets in [decisions.md](docs/decisions.md#11-why-create-the-firewall-and-bastion-subnets-before-the-services).

| VNet | Subnet | Prefix | Needed by |
|---|---|---|---|
| hub | `GatewaySubnet` | 10.0.0.0/24 | built |
| hub | `AzureFirewallSubnet` | 10.0.1.0/24 | phase 3 |
| hub | `AzureBastionSubnet` | 10.0.2.0/24 | phase 2 |
| hub | `snet-dns-inbound` | 10.0.3.0/28 | phase 5 |
| hub | `snet-dns-outbound` | 10.0.3.16/28 | phase 5 |
| hub | `AzureFirewallManagementSubnet` | 10.0.4.0/26 | phase 3, only if Basic SKU |
| spoke | `snet-spoke-workloads` | 10.1.0.0/24 | built |
| spoke | `snet-privatelink` | 10.1.1.0/24 | phase 4 |
| onprem | `GatewaySubnet` | 192.168.0.0/24 | built |
| onprem | `snet-onprem-workloads` | 192.168.1.0/24 | built |

### 0.5 Add `outputs.tf`

There is no outputs file at all, so every verification step in every later phase means opening the portal. Expose gateway public IPs, subnet IDs, the deployed address plan, and connection names. Later phases add the firewall private IP and the resolver inbound address.

### 0.6 Concurrency guard

Nothing prevents the state-lock race that caused the hung `terraform init` in [troubleshooting.md](docs/troubleshooting.md#1-terraform-init-hangs-forever).

```yaml
concurrency:
  group: terraform-${{ github.ref }}
  cancel-in-progress: false
```

`cancel-in-progress: false` is the important half. Cancelling an in-flight apply is how a stale lock and a half-built network happen.

### 0.7 Bootstrap script writes the wrong OIDC subject

The script still emits the name-based subject format. GitHub now issues immutable subjects containing numeric owner and repository IDs, so on any repository created after 15 July 2026 the credential will not match. Read `repository_id` and `repository_owner_id` and build the subject from them, or move to a flexible federated credential using claims matching. Details in [troubleshooting.md](docs/troubleshooting.md#2-oidc-subject-mismatch-aadsts700213).

### 0.8 Pin the Terraform version in the destroy workflow

`terraform-apply.yml` pins 1.9.0. `terraform-destroy.yml` pins nothing and will drift to whatever `setup-terraform` defaults to. Two Terraform versions touching one state file is asking for trouble.

---

## Phase 1: S2S tunnel foundation

**Done.** Three VNets, six subnets, two AZ gateways, an encrypted VNet-to-VNet tunnel, and hub-to-spoke peering with gateway transit. Deployed in one 21m54s run and torn down in roughly 17 minutes, both from the pipeline.

---

## Phase 2: Test VMs, to prove baseline connectivity

**Done.** Two `Standard_B2as_v2` VMs, one per workload subnet, no public IPs, gated behind a `deploy_workloads` checkbox on the workflow. Subnet NSGs deployed alongside them, ungated, each ending in an explicit deny-all that overrides Azure's default `AllowVnetInBound`. Bastion Standard for private access.

Proven, not assumed:

- A packet crosses the tunnel. `ping` succeeds spoke to on-prem and back.
- Gateway transit is real. `show-next-hop` returns `VirtualNetworkGateway` in both directions, route source `Gateway Route`.
- The NSGs are scoped, not decorative. Eleven `test-ip-flow` assertions matched intent, including SSH from the hub gateway subnet being denied, which Azure's defaults would have allowed.

Baselines captured for later phases: current egress addresses, and `168.63.129.16` as the resolver on both VNets.

Three failures along the way, in [troubleshooting.md](docs/troubleshooting.md#phase-2-workloads-and-access). Full write-up in [worklog.md](docs/worklog.md#phase-2-workloads-nsgs-and-access).

**Left open:** egress is unrestricted in both directions, NSG sources are `/16` where the workload `/24` would be tighter, and Bastion cannot reach the on-premises VNet.

---

## Phase 3: Azure Firewall and UDRs, to prove inspection

### SKU choice

Basic is cheaper, but it needs a **second /26 subnet**, is available in **limited regions**, and has **no DNS proxy**. Phase 5 is entirely about DNS, and DNS proxy is what keeps FQDN rules resolving consistently with the rest of the network.

**Standard is the recommendation.** More per hour, one subnet instead of two, available in Sweden Central, and it does not paint phase 5 into a corner. Confirm Basic's regional availability before choosing it purely on price.

### Routing, which is the part that is easy to get wrong

Deploying the firewall changes nothing by itself. Without UDRs, peered traffic routes directly and never sees it. This is the most common real hub-and-spoke mistake.

- Route table on `snet-spoke-workloads` sending `0.0.0.0/0` and `192.168.0.0/16` to the firewall private IP.
- Route table on `snet-onprem-workloads` for the return path.
- **No default route on `AzureFirewallSubnet`.** Keep route tables on workload subnets unless a documented forced-tunneling design requires otherwise.
- Disable BGP route propagation on the workload route tables where gateway-learned routes would otherwise override the firewall path.

Also leave `AzureBastionSubnet` alone. UDRs are unsupported there when IP-based connection is enabled, which it now is.

### Rules

The firewall denies by default, so a policy with no rule collection group turns the phase 2 ping off rather than inspecting it. Allow ICMP and TCP 22 between `10.1.0.0/16` and `192.168.0.0/16` explicitly. Nothing else, so the first thing the logs show is a deny.

### NSGs

Tighten the phase 2 sources from `/16` to the workload `/24` at the same time. That stops the DNS resolver and private link subnets inheriting SSH access they were never meant to have when phases 4 and 5 land.

### Verification, which is the point of this phase

Deploying a firewall is easy. Proving traffic goes through it is the part that separates a working design from a diagram.

**Before and after on one command.** `show-next-hop` from spoke to on-prem currently returns `VirtualNetworkGateway`. After the UDRs it must return `VirtualAppliance` with the firewall's private IP. If it does not, the route table is not associated or propagation is overriding it, and the firewall is being bypassed while appearing to work.

**Egress identity.** `curl ifconfig.me` from each VM currently returns Azure's default SNAT address. Once `0.0.0.0/0` points at the firewall it should return the firewall's public IP. This is the single clearest demonstration that routing changed, and both baselines are already captured.

**The logs, not just the connection.** Enable diagnostic settings and confirm the phase 2 ping now appears in `AZFWNetworkRule`. A ping that still succeeds with nothing logged means the UDR is inert. That is the failure mode worth deliberately reproducing once, because it is silent.

**Asymmetry.** Remove the `GatewaySubnet` route table and watch connections break while the firewall shows only one direction of the flow. Azure Firewall is stateful, so seeing half a conversation drops it. Understanding this is most of understanding hub-and-spoke routing.

**A deny that is visible.** Try a port with no allow rule and find the corresponding `Deny` in the logs. Proves the rules are being evaluated rather than everything falling through.

---

## Phase 4: Private endpoints and Key Vault, to prove PaaS security

The phase with a genuine constraint, and getting it right is the interesting part.

### The constraint

With `public_network_access_enabled = false`, only callers inside the VNet or arriving via private endpoint reach the Key Vault data plane. A GitHub-hosted runner is on the public internet, outside the VNet, and the trusted-services bypass does not cover CI services. Microsoft's documented fixes are a self-hosted agent inside the VNet or an IP allowlist entry, neither of which is attractive here.

So: **if Terraform in CI must read a secret at plan time, the vault cannot be private.** The two requirements are in direct conflict.

### The resolution, which is also the better demonstration

Do not have Terraform read the secret. Have the **VM** read it, over the private endpoint, using a managed identity.

- Key Vault with public network access disabled, RBAC authorization, purge protection on.
- Private endpoint in `snet-privatelink`.
- Private DNS zone `privatelink.vaultcore.azure.net` linked to hub and spoke.
- System-assigned managed identity on the spoke VM, granted Key Vault Secrets User.
- Terraform creates the vault and the secret. It never reads the secret back.

This sidesteps the conflict and demonstrates the real pattern: a workload authenticating with a managed identity over a private link, with no credential stored anywhere. A stronger story than a pipeline reading a secret.

### The VPN pre-shared key stays where it is

[decisions.md](docs/decisions.md#10-where-does-the-vpn-pre-shared-key-live-and-why) flags moving the PSK into Key Vault. Resist it here. Terraform needs the PSK at plan time, which is precisely the read that would force the vault public. Leave it in GitHub secrets and record why, since the reasoning is the valuable part.

**Proof:** from the spoke VM, `az keyvault secret show` succeeds via the managed identity, and `nslookup` on the vault FQDN returns a `10.1.1.x` address rather than a public one. From the on-prem VM the same lookup fails. That failure is the gap phase 5 closes.

---

## Phase 5: Azure DNS Private Resolver, to connect the namespaces

Phase 4 makes private resolution work inside Azure. Phase 5 makes it work from the simulated on-premises site. That ordering is what makes this phase land: there is already a real `privatelink` record that on-prem cannot resolve, and this fixes it.

- `azurerm_private_dns_resolver` bound to `vnet-hub`. A resolver references exactly one VNet and must be in the same region.
- Inbound endpoint in `snet-dns-inbound`, static IP `10.0.3.4`. Dynamic allocation takes the fifth address in the subnet, which is the same value, but pinning it makes it documentable.
- Outbound endpoint in `snet-dns-outbound`.
- Forwarding ruleset on the outbound endpoint, linked to hub and spoke, with a rule sending an on-premises zone to the on-premises DNS server.
- `dns_servers = ["10.0.3.4"]` on `vnet-onprem`, so the simulated site resolves Azure private names through the inbound endpoint across the tunnel.

**Dependency to accept:** the Azure-to-on-premises direction needs a real DNS server in `vnet-onprem` for the forwarding rule to target, which means dnsmasq or bind on the phase 2 on-prem VM serving a zone. Without it, only the inbound half is demonstrable.

Check that `azurerm ~> 3.90` exposes all the `azurerm_private_dns_resolver_*` resources before starting. If any are missing, do the 4.x upgrade first rather than pinning around it.

**Proof:** from the on-prem VM, resolving the Key Vault FQDN returns the `10.1.1.x` private endpoint address instead of a public one. That single command is the payoff for all five phases.

---

## Deliberately not doing

Stated explicitly, because the temptation on a project like this is to keep adding.

- **BGP, point-to-site, and a simulated remote worker.** Deliberately parked until phases 3 to 5 are finished. The idea: an isolated VNet in `denmarkeast` holding one VM that plays a remote worker's laptop, dialling into the hub over P2S. The isolation is the demonstration, since you can prove it reaches nothing before connecting and everything it should after.

  It does not stand alone. Microsoft's P2S routing documentation is explicit that without BGP on the S2S connection, clients reach only the VNet they dial into, so a remote worker could reach the hub and spoke but not the simulated datacenter. That makes BGP the prerequisite, and BGP means different ASNs on both gateways plus a gateway update. Denmark East has its own regional vCPU quota, so the VM would not compete with Sweden Central's four.

  Worth building if there is time at the end. Not worth interrupting the routing and DNS work for.
- **Splitting into modules.** A single flat config is easier to read than three modules that each wrap one resource. Revisit once a second spoke and a firewall exist.
- **Multi-environment workspaces.** There is one environment. Structure for it.
- **AKS, Application Gateway, Front Door.** They dilute a clear networking story into a generic Azure demo.
- **Azure Firewall Premium.** Large cost increase, marginal learning over Standard for this topology.

---

## Worth doing at some point, not scheduled

- **Offline config tests.** `terraform test` with `mock_provider` runs with no credentials and no infrastructure. It would encode the address plan and the peering flags so a careless map edit cannot silently break them. It would not have caught any of the six errors in [troubleshooting.md](docs/troubleshooting.md), because those were all platform rejections at apply time.
- **Commit `.terraform.lock.hcl`.** Currently absent, so CI can resolve `~> 3.90` to a different patch on any run. Generate it for `linux_amd64` as well as the local platform, or CI will fail on a hash mismatch.
- **Tags.** Zero of the deployed resources carry one, so spend cannot be attributed and orphans cannot be found by query.
- **Cost visibility.** Infracost on pull requests, a budget resource with alert thresholds, and a scheduled teardown so a forgotten weekend costs nothing.
- **Observability.** Diagnostic settings on the gateways and firewall into Log Analytics, plus a committed set of KQL queries.
- **A runbook and deliberate failure drills.** [troubleshooting.md](docs/troubleshooting.md) is the most distinctive document in this repo and it was written from accidents. Breaking things on purpose, such as mismatching the PSK or removing a UDR after phase 3, and writing up detection and recovery, extends that strength more cheaply than another service does.

---

## What finished looks like

A reader should be able to open this repo and, without running anything, answer:

- what gets deployed and how the pieces connect
- how traffic actually flows, and what enforces that
- how the pipeline authenticates, and why no secret is stored
- what it costs and how to tear it down
- what is deliberately not built, and why

And by running it: open a PR, read the plan, merge, click apply, wait for the gateways, ping across the tunnel, see the packet in the firewall log, resolve a private endpoint name from the simulated datacenter, then click destroy.
