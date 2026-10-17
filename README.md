# Azure hub and spoke with an external network

An external network connected to private Azure workloads over IPsec, with firewall inspection
and hybrid DNS.
Terraform and GitHub Actions deployed the VPN gateways, Azure Firewall, Private Link, and DNS
Private Resolver.

> **Completed lab; environment torn down.** Results are historical. Later source changes have
> not all been validated by redeployment; see [limits](#limits-that-matter).

## How it fits together

![Hybrid network overview: an external network reaches an Azure spoke through two VPN gateways, an IPsec tunnel, the hub firewall, and VNet peering. Cross-site DNS uses the same gateways and IPsec tunnel, branching to the hub resolver. The spoke queries Azure-provided DNS and its forwarding ruleset. The spoke reaches Key Vault through a private endpoint.](docs/diagrams/network-overview.svg)

The pattern connects a datacenter, another cloud, or another private network to an Azure hub and
spoke. The VPN peer and address plan depend on the network being connected.

- **Connectivity and inspection:** the spoke borrows the hub's VPN gateway through peering.
  User-defined routes on the spoke workload subnet and hub gateway subnet send traffic between
  spoke workloads and the external network through Azure Firewall in both directions. The spoke's
  default route also uses the firewall. Workload NSGs apply independently.
- **Private service access:** a private endpoint in the spoke connects to Key Vault with public
  network access disabled. Managed identity and vault-scoped RBAC authorize the spoke VM.
- **Hybrid DNS:** the external network sends Azure private-name queries to the resolver's inbound
  endpoint. Azure forwards `corp.internal` queries through a ruleset and outbound endpoint to
  `dnsmasq` on the external network. Both cross-site DNS legs use the VPN gateways and IPsec tunnel.
  The hub resolver uses the gateway route; the firewall UDRs target the spoke workloads.
- **Administration and delivery:** workload VMs had no public IPs; lab administration used
  Azure Bastion. GitHub Actions authenticated to Azure through OIDC. Terraform applies and
  destroys required manual workflow dispatch.

The [architecture notes](docs/architecture.md) trace individual flows. The
[topology definition](terraform/locals.tf) holds the address plan and subnet rules.

## What was verified

Each evidence record contains the checks, screenshots, and qualifications behind these results.

| Behavior checked | Observed result | Evidence |
| --- | --- | --- |
| Connectivity across the tunnel | Traffic crossed the tunnel in both directions; 11 NSG assertions passed, with allowed and blocked ports also checked from a VM | [Tunnel traffic](docs/validation/phase-2-connectivity.md#a-packet-crosses-the-tunnel), [NSG matrix](docs/validation/phase-2-connectivity.md#nsg-matrix) |
| Firewall enforcement after forced routing | ICMP and SSH remained reachable; unmatched HTTP received a default deny, confirmed in application-rule logs | [HTTP denial](docs/validation/phase-3-route+firewall.md#why-ports-80-and-443-appeared-open), [rule logs](docs/validation/phase-3-route+firewall.md#log-analytics-evidence) |
| Private Key Vault access and authorization | A request failed without RBAC, then returned HTTP 200 after assignment; the response identified `conn_type=PrivateLink` | [Data-plane checks](docs/validation/phase-4-private-link.md#data-plane-validation-from-vm-spoke) |
| Hybrid DNS in both directions | An external client resolved the vault to its private endpoint; the spoke resolved `app.corp.internal` after its earlier `NXDOMAIN` baseline | [Inbound lookup](docs/validation/phase-5-dns-resolver.md#inbound-validation-on-premises-to-azure-private-dns), [outbound lookup](docs/validation/phase-5-dns-resolver.md#outbound-validation-azure-to-the-on-premises-namespace) |

The evidence distinguishes configured controls from observed traffic. A tunnel reporting
`Connected` was insufficient; so was a successful TCP handshake when the firewall later denied HTTP.

## Limits that matter

- **Implementation scope:** the external network was an Azure VNet in Denmark East, connected
  with VNet-to-VNet gateways. Third-party VPN devices and BGP interoperability were outside the tests.
- **Permissive lab policy:** spoke HTTP/HTTPS egress permits wildcard FQDNs.
  The deployment identity has broad provider permissions. See the
  [firewall limitation](docs/validation/phase-3-route+firewall.md#result-and-remaining-limitation)
  and [permission trade-offs](docs/decisions.md#4-pipeline-permissions).
- **Rebuild not fully validated:** DNS evidence follows a manual repair. Later Terraform bootstrap
  changes still need a new plan and smoke tests. See the
  [source/evidence boundary](docs/validation/phase-5-dns-resolver.md#evidence-boundary-for-the-terraform-hardening).
- **Partial TCP evidence:** the DNS test proved the client-to-local-stub leg, not TCP between
  the resolver and `dnsmasq`. See the
  [acceptance matrix](docs/validation/phase-5-dns-resolver.md#acceptance-matrix).

## Find your way around

| To understand | Start here |
| --- | --- |
| How traffic moves and which control applies | [Architecture](docs/architecture.md) |
| The checks and evidence behind the results | [Validation index](docs/validation/README.md) |
| Why these services and trade-offs were chosen | [Decisions](docs/decisions.md), with links to Microsoft and Terraform documentation |
| What was built, in order | [Worklog](docs/worklog.md) |
| Failures, diagnoses, and fixes | [Troubleshooting](docs/troubleshooting.md) |
| How the infrastructure is declared and deployed | [Terraform root](terraform/main.tf), [deployment workflow](.github/workflows/terraform-apply.yml) |
