# Plan

Current state and the next build step. Completed implementation detail lives in
[the worklog](docs/worklog.md); test evidence lives in [docs/validation](docs/validation/README.md).

**Status:** Phases 0 through 4 are complete. Phase 5 is next. The hub-and-spoke network,
cross-region IPsec tunnel, workload NSGs, symmetric firewall inspection, and private Key
Vault access from `vm-spoke` have all been deployed and validated.

## Completed phases

| Phase | Outcome | Evidence |
|---|---|---|
| 0 — prerequisites | Fixed the apply gate, remote-state concurrency, topology map, outputs, OIDC subjects, and version pinning | [Pipeline validation](docs/validation/phase-0-pipeline.md) |
| 1 — tunnel | Built three VNets, two VPN gateways, the encrypted VNet-to-VNet tunnel, and hub-to-spoke gateway transit | [Tunnel validation](docs/validation/phase-1-tunnel.md) |
| 2 — workloads | Added private VMs, Bastion, explicit NSGs, and proved traffic crosses the tunnel in both directions | [Connectivity validation](docs/validation/phase-2-connectivity.md) |
| 3 — inspection | Added Azure Firewall Standard, symmetric UDRs, policy rules, and diagnostic logs | [Routing and firewall validation](docs/validation/phase-3-route+firewall.md) |
| 4 — Private Link | Added a private Key Vault endpoint, private DNS, managed identity, and vault-scoped RBAC; proved the VM reaches the vault over Private Link | [Private Link validation](docs/validation/phase-4-private-link.md) |

## Constraints that still shape the design

| Constraint | Consequence |
|---|---|
| GitHub-hosted runners are outside the VNets | Terraform does not manage Key Vault secrets while public access is disabled |
| DNS resolver endpoints require dedicated delegated `/28` subnets | `snet-dns-inbound` and `snet-dns-outbound` are already reserved |
| Azure-to-on-premises forwarding needs an on-premises DNS target | `vm-onprem` will run `dnsmasq` for `corp.internal` |
| The resolver inbound address must be stable for the simulated site | Phase 5 pins it to `10.0.3.4` |
| Private DNS links provide direct Azure resolution | The temporary `vnet-onprem` link must be removed before Phase 5 testing, otherwise it bypasses the resolver being demonstrated |

## Phase 5: Azure DNS Private Resolver

The Terraform module exists, but the resolver resources have not been deployed and the GitHub
Actions workflow does not yet expose `deploy_dns`. Phase 5 is therefore **prepared, not complete**.

### Prepare

1. Remove `onprem` from the Key Vault private DNS zone links. Keep the zone linked to `hub` and
   `spoke`; on-premises resolution must go through the resolver inbound endpoint.
2. Add a `deploy_dns` boolean input and `TF_VAR_deploy_dns` mapping to the deploy workflow.
3. Review the `vm-onprem` bootstrap for idempotent `dnsmasq` installation and a test record in
   `corp.internal`.
4. Add TCP/53 from the resolver outbound subnet to `vm-onprem`; the current NSG rule permits only
   UDP/53, while DNS must support TCP fallback as well.

### Deploy

- `dnspr-hub` in `vnet-hub`.
- Inbound endpoint at `10.0.3.4` in `snet-dns-inbound`.
- Outbound endpoint in `snet-dns-outbound`.
- `ruleset-hub`, linked to hub and spoke, forwarding `corp.internal.` to `192.168.1.4:53`.
- `vnet-onprem` custom DNS set to `10.0.3.4`.

### Validate

Capture both directions and the negative baseline:

1. Before deployment, show that `vm-onprem` does not resolve the Key Vault private address after
   the direct zone link is removed.
2. After deployment, resolve the vault FQDN from `vm-onprem` and receive `10.1.1.4`.
3. From an Azure VM, resolve the `corp.internal` test record served by `vm-onprem`.
4. In the portal, capture the resolver, inbound/outbound endpoints, forwarding rule, ruleset links,
   and the on-premises VNet DNS setting.
5. Run `terraform plan` again with the same phase flags and confirm no unexpected changes.

## Deliberately out of scope

- BGP and point-to-site remote-worker simulation until the five-phase path is complete.
- AKS, Application Gateway, Front Door, and Firewall Premium; they dilute the networking story.
- Multiple environments and workspaces; this repository represents one lab environment.
- Further module splitting until another spoke or repeated service creates real reuse.

## Definition of complete

A reader can trace the path from the simulated datacenter to Azure, identify the control enforcing
each hop, and reproduce the evidence. The final Phase 5 proof is private Key Vault name resolution
from `vm-onprem` through Azure DNS Private Resolver, without a direct private-zone link to the
on-premises VNet.
