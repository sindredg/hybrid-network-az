# Plan

Current state and the next improvements. Completed implementation detail lives in
[the worklog](docs/worklog.md); test evidence lives in [docs/validation](docs/validation/README.md).

**Status:** Phases 0 through 5 are complete. The hub-and-spoke network, cross-region IPsec tunnel,
workload NSGs, symmetric firewall inspection, private Key Vault access, and bidirectional hybrid DNS
have all been deployed and validated.

## Completed phases

| Phase | Outcome | Evidence |
|---|---|---|
| 0 — prerequisites | Fixed the apply gate, remote-state concurrency, topology map, outputs, OIDC subjects, and version pinning | [Pipeline validation](docs/validation/phase-0-pipeline.md) |
| 1 — tunnel | Built three VNets, two VPN gateways, the encrypted VNet-to-VNet tunnel, and hub-to-spoke gateway transit | [Tunnel validation](docs/validation/phase-1-tunnel.md) |
| 2 — workloads | Added private VMs, Bastion, explicit NSGs, and proved traffic crosses the tunnel in both directions | [Connectivity validation](docs/validation/phase-2-connectivity.md) |
| 3 — inspection | Added Azure Firewall Standard, symmetric UDRs, policy rules, and diagnostic logs | [Routing and firewall validation](docs/validation/phase-3-route+firewall.md) |
| 4 — Private Link | Added a private Key Vault endpoint, private DNS, managed identity, and vault-scoped RBAC; proved the VM reaches the vault over Private Link | [Private Link validation](docs/validation/phase-4-private-link.md) |
| 5 — hybrid DNS | Added Azure DNS Private Resolver, inbound and outbound endpoints, a forwarding ruleset, and an on-premises DNS target; proved both resolution directions | [DNS Resolver validation](docs/validation/phase-5-dns-resolver.md) |

## Current operating constraints

| Constraint | Consequence |
|---|---|
| GitHub-hosted runners are outside the VNets | Terraform does not manage Key Vault secrets while public access is disabled |
| DNS resolver endpoints require dedicated delegated `/28` subnets | `snet-dns-inbound` and `snet-dns-outbound` cannot host other workloads |
| Azure-to-on-premises forwarding needs a reachable DNS target | `vm-onprem` serves `corp.internal` on `192.168.1.4`; its listener and NSG support UDP and TCP 53 |
| The simulated site needs a stable DNS destination | The resolver inbound endpoint is pinned to `10.0.3.4` |
| A GitHub-hosted runner is outside the private data plane | VM and portal validation remain necessary even when Terraform plan succeeds |

## Phase 5 outcome: Azure DNS Private Resolver

`dnspr-hub` provides an inbound endpoint at `10.0.3.4` and an outbound endpoint connected to
`ruleset-hub`. The ruleset is linked to hub and spoke and forwards `corp.internal.` to
`192.168.1.4:53`. The direct Key Vault private-zone link to `vnet-onprem` was removed, so the
on-premises success case must pass through the inbound endpoint.

The validation proved:

1. Before deployment, on-premises Azure-provided DNS returned public Key Vault addresses and the
   spoke could not resolve `app.corp.internal`.
2. After deployment, `vm-onprem` used `10.0.3.4` and resolved the vault to private endpoint
   `10.1.1.4`.
3. `vm-spoke` resolved `app.corp.internal` to `192.168.1.4` through the outbound path.
4. `dnsmasq` listened only on the on-premises VM address, avoiding a collision with
   `systemd-resolved` on the local stub address.

The live repair is validated. The matching Terraform hardening — scoped `dnsmasq` listener, bounded
package retry, and `depends_on = [module.connectivity]` so the VM waits for the tunnel — was added
afterward; its next authenticated plan may replace `vm-onprem` and must be followed by the same
smoke tests.

Commands, screenshots, the failure analysis, and the acceptance matrix are in
[the Phase 5 validation record](docs/validation/phase-5-dns-resolver.md).

## Deferred: what operating this would require

None of these are needed to demonstrate the topology. They are what a continuously operated
environment would add on top of it, listed so the boundary is explicit rather than implied.

- Add a post-deployment smoke test that runs the two DNS assertions automatically.
- Alert on DNS Private Resolver endpoint query-volume anomalies and endpoint health.
- Tighten the CI deployment role from provider-level wildcards to the actions observed in use.
- Move the Terraform backend to Entra ID data-plane authentication instead of storage account keys.
- Add drift detection before treating this lab pattern as a continuously operated environment.

## Deliberately out of scope

- BGP and point-to-site remote-worker simulation; neither is needed to prove this topology.
- AKS, Application Gateway, Front Door, and Firewall Premium; they dilute the networking focus.
- Multiple environments and workspaces; this repository represents one lab environment.
- Further module splitting until another spoke or repeated service creates real reuse.

## Definition of complete

A reader can trace the path from the simulated datacenter to Azure, identify the control enforcing
each hop, and reproduce the evidence. The final Phase 5 proof is private Key Vault name resolution
from `vm-onprem` through Azure DNS Private Resolver without a direct private-zone link, plus
`corp.internal` resolution from the spoke through the outbound endpoint and the IPsec tunnel.
