# Azure Private Hybrid Network

Three private Azure networks in separate address spaces, joined by an encrypted IPsec tunnel and VNet peering, with shared services centralized in a hub and zero public exposure on any workload. The hub and spoke are located in Sweden Central, with the simulated "on-prem" network in Denmark East.

This is the pattern for connecting two private networks that do not implicitly trust each other: an on-premises datacenter reaching into Azure, two separate cloud estates, or an acquired company's network. Here vnet-onprem plays the datacenter role, but the mechanics could be identical regardless of the scenario.

Built with Terraform and deployed from GitHub Actions.

## What it does

- **Encrypted connectivity between separate address domains.** An IPsec tunnel between
  two VPN gateways connects on-premises workloads in Denmark East with the cloud environment
  in Sweden Central. VNet peering with gateway transit allows the spoke to reach across the
  tunnel through the hub's gateway rather than deploying its own.
- **Centralised inspection.** A firewall in the hub uses user-defined routes (UDRs) to
  force spoke-to-on-premises traffic and spoke egress through it.
- **No public exposure.** Workloads have no public IPs. Administrative access goes through
  Azure Bastion, spoke egress leaves through the firewall instead of Azure's default SNAT,
  and Key Vault data-plane access uses a private endpoint with public access disabled.
- **Bidirectional hybrid name resolution.** Azure DNS Private Resolver lets the simulated
  datacenter resolve Azure private endpoints and lets Azure workloads resolve the
  `corp.internal` namespace across the tunnel.
- **Keyless delivery.** OIDC federation into Entra ID eliminates static credentials in the repository.
  Infrastructure changes use remote state and execute only when manually triggered in GitHub Actions.

Built incrementally in phases, with each layer validated before moving to the next. Phases 0 through
5 are complete: core networking, VPN connectivity, Bastion access, Azure Firewall, private Key
Vault access, and bidirectional hybrid DNS are deployed and validated.

---

## Architecture

```mermaid
flowchart TB
    subgraph OP["vnet-onprem - 192.168.0.0/16 - simulated datacenter (denmarkeast)"]
        direction TB
        OGW["GatewaySubnet<br/>vgw-onprem"]
        HBA["AzureBastionSubnet<br/>admin-onprem"]
        OVM["snet-onprem-workloads<br/>vm-onprem"]
    end

    subgraph HUB["vnet-hub - 10.0.0.0/16 - shared services (swedencentral)"]
        direction TB
        HGW["GatewaySubnet<br/>vgw-hub"]
        HFW["AzureFirewallSubnet<br/>Azure Firewall"]
        HDN["snet-dns-inbound /28<br/>inbound 10.0.3.4<br/>snet-dns-outbound /28<br/>DNS Private Resolver"]
    end

    subgraph SP["vnet-spoke - 10.1.0.0/16 - workload (swedencentral)"]
        direction TB
        SVM["snet-spoke-workloads<br/>vm-spoke"]
        SPL["snet-privatelink<br/>private endpoint to Key Vault<br/>10.1.1.4"]
    end

    OGW <-->|"IPsec tunnel"| HGW
    HUB -->|"peering, gateway transit"| SP
    SP -->|"peering, remote gateways"| HUB
    SVM -.->|"UDR forces inspection<br/>phase 3"| HFW
    OVM -.->|"Azure private names<br/>inbound endpoint"| HDN
    HDN -.->|"corp.internal<br/>outbound endpoint"| OVM

    classDef built stroke:#2da44e,stroke-width:2px,color:#e6edf3
    class OGW,OVM,HGW,HBA,SVM,HFW,SPL,HDN built
    linkStyle 0 stroke-width:3px,stroke:#2da44e
```

Three non-overlapping ranges, chosen so the simulated on-prem datacenter looks nothing like the Azure side. Neither VM has a public IP; admin access is through Bastion to the "on-prem" vm. The spoke has no gateway on its own, which is the point of the network topology: one gateway in the hub that serves every spoke.

---

## Documentation

| Document | What is in it |
|---|---|
| [plan.md](plan.md) | The completed phases, current operating constraints, and next improvements |
| [docs/worklog.md](docs/worklog.md) | What was built and in what order, with the evidence |
| [docs/decisions.md](docs/decisions.md) | Architecture decisions as questions, each with alternatives and trade-offs |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Real failures and diagnostic traps grouped by phase, with the error, root cause, and fix |
| [docs/terraform/README.md](docs/terraform/README.md) | Where Terraform configuration belongs, module boundaries, typed contracts, and the safe change workflow |
| [docs/terraform/patterns.md](docs/terraform/patterns.md) | Loops, collections, `flatten()`, `for_each`, dynamic blocks, and a concrete subnet walkthrough |
| [docs/validation/README.md](docs/validation/README.md) | Phase-by-phase control-plane and data-plane evidence through Phase 5 hybrid DNS |

---

## Stack

Azure (Sweden Central, Denmark East), Terraform with the AzureRM provider, GitHub Actions, Entra ID workload identity federation, Azure RBAC custom roles.
