# Azure Hybrid Network Lab

An Azure hub-and-spoke network with a simulated on-premises site, defined entirely in Terraform and deployed from GitHub Actions with no stored Azure credentials.

---

## Target architecture

```mermaid
flowchart TB
    subgraph OP["vnet-onprem 192.168.0.0/16<br/>simulated datacenter"]
        direction LR
        OGW["GatewaySubnet<br/>vgw-onprem"]
        OVM["snet-onprem-workloads<br/>test VM + DNS server<br/>phase 2 and 5"]
    end

    subgraph HUB["vnet-hub 10.0.0.0/16<br/>shared services"]
        direction LR
        HGW["GatewaySubnet<br/>vgw-hub"]
        HFW["AzureFirewallSubnet<br/>Azure Firewall Standard<br/>phase 3"]
        HBA["AzureBastionSubnet<br/>Bastion<br/>phase 2"]
        HDI["snet-dns-inbound /28<br/>resolver inbound 10.0.3.4<br/>phase 5"]
        HDO["snet-dns-outbound /28<br/>resolver outbound<br/>phase 5"]
    end

    subgraph SP["vnet-spoke 10.1.0.0/16<br/>workload"]
        direction LR
        SVM["snet-spoke-workloads<br/>test VM + managed identity<br/>phase 2 and 4"]
        SPL["snet-privatelink<br/>private endpoint<br/>phase 4"]
    end

    KV["Key Vault<br/>public access disabled<br/>phase 4"]

    OGW <-->|"IPsec tunnel"| HGW
    HUB -->|"peering, gateway transit"| SP
    SP -->|"peering, remote gateways"| HUB
    SVM -.->|"UDR forces inspection<br/>phase 3"| HFW
    OVM -.->|"UDR return path<br/>phase 3"| HFW
    SPL ---|"private link"| KV
    OVM -.->|"resolves privatelink<br/>across the tunnel<br/>phase 5"| HDI
    HDO -.->|"conditional forward<br/>to on-prem DNS<br/>phase 5"| OVM

    classDef planned stroke-dasharray: 5 5
    class OVM,HFW,HBA,HDI,HDO,SVM,SPL,KV planned
```
