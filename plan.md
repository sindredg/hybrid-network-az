# Plan

**Status:** Completed. The hub-and-spoke network, cross-region IPsec tunnel, workload NSGs, 
symmetric firewall inspection, private Key Vault access, and bidirectional hybrid DNS 
have all been deployed and validated.

## Completed phases

| Phase | Outcome | Evidence |
|---|---|---|
| 0: prerequisites | Fixed the apply gate, remote-state concurrency, topology map, outputs, OIDC subjects, and version pinning | [Pipeline validation](docs/validation/phase-0-pipeline.md) |
| 1: tunnel | Built three VNets, two VPN gateways, the encrypted VNet-to-VNet tunnel, and hub-to-spoke gateway transit | [Tunnel validation](docs/validation/phase-1-tunnel.md) |
| 2: workloads | Added private VMs, Bastion, explicit NSGs, and proved traffic crosses the tunnel in both directions | [Connectivity validation](docs/validation/phase-2-connectivity.md) |
| 3: inspection | Added Azure Firewall Standard, symmetric UDRs, policy rules, and diagnostic logs | [Routing and firewall validation](docs/validation/phase-3-route+firewall.md) |
| 4: Private Link | Added a private Key Vault endpoint, private DNS, managed identity, and vault-scoped RBAC; proved the VM reaches the vault over Private Link | [Private Link validation](docs/validation/phase-4-private-link.md) |
| 5: hybrid DNS | Added Azure DNS Private Resolver, inbound and outbound endpoints, a forwarding ruleset, and an on-premises DNS target; proved both resolution directions | [DNS Resolver validation](docs/validation/phase-5-dns-resolver.md) |
