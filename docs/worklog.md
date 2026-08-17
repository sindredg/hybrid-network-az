# Work log

What was built, in the order it was built.

Reasoning lives in [decisions.md](decisions.md), errors in [troubleshooting.md](troubleshooting.md), and test evidence in [validation/](validation/). This file is the narrative that connects them.

Phase numbering follows [plan.md](../plan.md). Entries are chronological, which is why Phase 0 appears after Phase 1: it was a list of fixes that only became visible once Phase 1 was built.

---

## Phase 1: S2S tunnel foundation

### Stage 1: Define the network

Address plan first, resources second. Three non-overlapping ranges, the on-premises one chosen to look nothing like the Azure side:

| Network | Range | Subnets |
|---|---|---|
| `vnet-onprem` | `192.168.0.0/16` | `GatewaySubnet`, `snet-onprem-workloads` |
| `vnet-hub` | `10.0.0.0/16` | `GatewaySubnet`, `AzureFirewallSubnet`, `AzureBastionSubnet` |
| `vnet-spoke` | `10.1.0.0/16` | `snet-spoke-workloads` |

Non-overlapping matters specifically here: a tunnel and a peering both push routes into the same tables, so overlap either fails to build or builds and routes traffic somewhere unexpected.

That plan went into `locals.tf` as a map, not a comment. Two resource blocks produce all three VNets and all six subnets via `flatten()`, explained in [terraform-patterns.md](terraform-patterns.md).

Then two gateways, two connections pointing at each other, and hub-to-spoke peering with `allow_gateway_transit` on one side and `use_remote_gateways` on the other. Those two flags are the whole point: the spoke reaches on-prem through the hub's gateway rather than paying for its own.

The firewall and Bastion subnets were carved now despite being empty, because both services demand exact names and minimum sizes.

---

### Stage 2: Bootstrap identity and state

`scripts/bootstrap-azure.sh`, idempotent, run once.

![Custom role HybridNetworkLabTFDeployer assigned to sp-github-actions-hybrid-lab](images/azure-custom-role-assignment.png)

Custom role rather than Contributor. Not because it is minimal, it grants provider wildcards, but because it cannot create role assignments, so a compromised pipeline cannot widen its own access. See [decisions.md](decisions.md#4-why-a-custom-rbac-role-instead-of-contributor).

![Federated credentials: gh-actions-main and gh-actions-pr](images/azure-federated-credentials.png)

Two trusted subjects, `main` and pull requests. No client secret anywhere.

![Repository secrets: AZURE_CLIENT_ID, AZURE_SUBSCRIPTION_ID, AZURE_TENANT_ID, TF_STATE_RG, TF_STATE_SA](images/github-secrets-azure-ids.png)

![The same list with VPN_SHARED_KEY added](images/github-secrets-complete.png)

Five identifiers and one actual secret.

![Workflow env block mapping ARM_ variables and TF_VAR_vpn_shared_key](images/workflow-env-oidc-and-tfvar.png)

`ARM_USE_OIDC: true` is what makes the provider use the federated token. The `TF_VAR_` prefix turns a GitHub secret into a Terraform variable without it appearing on a command line.

---

### Stage 3: Build the pipeline, then fight it

Six failures between writing the workflow and getting a deployment. Four were Azure withdrawing something.

| Failure | Cause | Detail |
|---|---|---|
| `terraform init` hangs | Two runs racing the state lock | [1](troubleshooting.md#1-terraform-init-hangs-forever) |
| `AADSTS700213` | Immutable OIDC subject format | [2](troubleshooting.md#2-oidc-subject-mismatch-aadsts700213) |
| `IPv4BasicSkuPublicIpCountLimitReached` | Basic public IPs retired | [3](troubleshooting.md#3-basic-sku-public-ip-blocked) |
| `fmt -check` exit 3 | Invisible characters from pasted code | [4](troubleshooting.md#4-terraform-fmt--check-exits-3) |
| `NonAzSkusNotAllowedForVPNGateway` | Non-AZ gateway SKUs retired | [5](troubleshooting.md#5-non-az-gateway-sku-rejected) |
| `VmssVpnGatewayPublicIpsMustHaveZonesConfigured` | AZ gateways need zoned IPs | [6](troubleshooting.md#6-az-gateway-requires-zoned-public-ip) |

![Init step failing with AADSTS700213 and the presented assertion subject](images/oidc-aadsts700213-error.png)

![IPv4BasicSkuPublicIpCountLimitReached for both public IPs](images/basic-sku-public-ip-error.png)

The last three are one cascade, not three problems. Fixing the Basic SKU produced a Standard IP, fixing the gateway SKU made it zone-redundant, and the combination triggered a third requirement neither change implied alone. Three applies for one platform-modernisation change, each costing a 20-minute gateway build.

Then it went through:

![Plan reading 18 to add, apply creating the resource group](images/terraform-plan-and-apply-start.png)

![Run succeeding in 21m 54s](images/successful-deploy-run.png)

![Resource group listing both connections, three public IPs, two gateways, three VNets](images/deployed-resources-portal.png)

`pip-vpn-spoke` is visible there, attached to nothing. The public IP resource looped over all three networks while only two have gateways. Fixed in Phase 0.

Full record in [validation/phase-1-tunnel.md](validation/phase-1-tunnel.md).

---

### Stage 4: Stop the pipeline from burning credits

The workflow originally applied on every push, so any edit triggered a full run against two VPN gateways.

![Triggers: workflow_dispatch, and pull_request filtered to terraform/**](images/workflow-triggers-manual-and-pr.png)

The `paths` filter matters as much as the trigger change: editing documentation now starts nothing.

![Terraform Deploy page with a Run workflow button](images/deploy-workflow-run-button.png)

![Terraform Destroy page with its own button](images/destroy-workflow-run-button.png)

Teardown has to be as easy as deployment or it does not happen. It has since been used:

![Destroy Infrastructure job started](images/destroy-run-started.png)

![Plan: 0 to add, 0 to change, 19 to destroy](images/destroy-plan-19-resources.png)

![Destroy complete! Resources: 19 destroyed](images/destroy-complete-19-resources.png)

Nineteen in roughly 17 minutes, and the first authoritative count of what the lab consists of.

**Left behind:** the apply step's condition still required a `push` event that no longer existed, so it was skipped on every run while the job reported success. Fixed in Phase 0.

---

### Stage 5: Documentation

Writing it up found three things reading the code had not: the orphaned public IP, the skipped apply step, and that state is reached via an access key looked up through the management plane rather than by the service principal authenticating to blob storage, which is why `Microsoft.Storage/*` is in the custom role.

---

## Phase 0: Prerequisites and pipeline fixes

Done with the subscription empty, immediately after a destroy. Deliberate timing: changing the subnet map with resources deployed means `moved` blocks or a 45-minute gateway rebuild.

![Terraform Apply gated on workflow_dispatch](images/phase0-apply-condition-fixed.png)

![Concurrency block, group terraform-state](images/phase0-concurrency-group.png)

![Destroy workflow pinned to terraform_version 1.9.0](images/phase0-destroy-version-pin.png)

![outputs.tf exposing the address plan, subnet IDs and gateway IPs](images/phase0-outputs-tf.png)

Also in this phase, without screenshots because they are config diffs: subnet values became objects so they can carry delegation and, later, route tables and NSGs; a `has_gateway` flag removed the orphaned public IP; and the bootstrap script now writes both OIDC subject formats.

Composite subnet keys were left identical, so nine subnets refreshed against their existing state addresses with nothing replaced.

The proof is not any of the above:

![Run succeeding in 24m 28s with a green tick on Terraform Apply](images/phase0-apply-step-now-runs.png)

Twenty-four minutes in the apply step rather than skipping it. Duration is the giveaway.

**End state:** 21 resources, subnets 6 to 9, public IPs 3 to 2. Evidence in [validation/phase-0-pipeline.md](validation/phase-0-pipeline.md).

---

## Phase 2: Workloads, NSGs and access

Two Ubuntu VMs, one per workload subnet, no public IPs. Subnet NSGs alongside them rather than after, ungated, each ending in an explicit deny-all that overrides Azure's permissive `AllowVnetInBound` default.

![Run workflow dialog with a Deploy test VMs and Bastion checkbox](images/phase2-deploy-workloads-checkbox.png)

![Apply step env with TF_VAR_deploy_workloads set to true](images/phase2-apply-env-vars.png)

Compute is opt-in per run rather than committed to the repo.

![VM_SSH_PUBLIC_KEY in repository secrets](images/phase2-ssh-key-secret.png)

![Resource group with both VMs, both NSGs, Bastion and its public IP](images/phase2-deployed-resources-portal.png)

Two failures cost a deploy cycle each, an [ed25519 key the provider refused](troubleshooting.md#8-provider-rejects-ed25519-ssh-keys) and a [VM size with no capacity in the region](troubleshooting.md#9-vm-size-not-available-in-the-region). A third, [Bastion not reaching the on-premises VNet](troubleshooting.md#10-bastion-cannot-reach-the-on-premises-vnet), is still open.

Then the thing this phase exists for:

![vm-spoke at 10.1.0.4 pinging 192.168.1.4, 0% packet loss](images/phase2-ping-across-tunnel.png)

First real traffic in the project. Until this, the topology was believed to work because Azure reported both connections as `Connected`, which is a status field rather than evidence.

![NSG matrix: allows matched to named rules, denies to deny-all-inbound](images/phase2-nsg-matrix-results.png)

Eleven assertions, all as intended. The row worth reading twice is SSH from the hub gateway subnet to the spoke, denied by `deny-all-inbound`, because Azure's defaults would have allowed it.

Full matrix, the wire-level checks and the Phase 3 baselines are in [validation/phase-2-connectivity.md](validation/phase-2-connectivity.md).

**End state:** a packet has crossed the tunnel, the NSGs are scoped rather than merely present, and egress and DNS baselines are recorded for the next two phases.

---

## Where things stand

Phases 0, 1 and 2 complete. [plan.md](../plan.md) holds 3 through 5.

**Built and proven:** three VNets and nine subnets; an encrypted tunnel carrying real traffic; gateway transit confirmed by effective-route lookup; subnet NSGs that override Azure's defaults; Bastion for private access with no public IP on either VM; keyless OIDC deployment with working apply and destroy.

**Not built:** Azure Firewall and the route tables without which it would be bypassed; private endpoints; any DNS story.

**Known gaps:** egress unrestricted in both directions by default rather than by decision; NSG sources at `/16` where the workload `/24` would be tighter; Bastion unable to reach the on-premises VNet.

Next is the firewall and the routing that makes it mean anything. The check to watch is `show-next-hop` flipping from `VirtualNetworkGateway` to `VirtualAppliance`. If it does not, the UDRs are decorative and the firewall is being bypassed.
