# Terraform guide

This section explains how the Terraform in this repository is organised, where configuration belongs,
and how data becomes Azure resources. Start here before changing the infrastructure. Use
[patterns.md](patterns.md) when you need the detailed explanation of `for`, `for_each`, `flatten()`,
`dynamic`, `each.key`, and `each.value`.

## The four-layer mental model

| Layer | Location | Responsibility |
|---|---|---|
| Environment inputs | `terraform/variables.tf` and GitHub `TF_VAR_*` values | Values supplied from outside Terraform, including deployment switches and secrets |
| Environment model | `terraform/locals.tf` | This lab's regions, address plan, VM definitions, DNS settings, peerings, connections, and NSG rules |
| Composition | `terraform/main.tf` | Creates the resource group and connects modules by passing values and resource IDs |
| Implementation | `terraform/modules/*` | Translates typed inputs into Azure resources and returns useful outputs |

The main data path is:

```text
root local value
  -> module argument in terraform/main.tf
  -> typed variable in modules/<name>/variables.tf
  -> resource arguments in modules/<name>/main.tf
  -> module output
  -> root module or root output
```

For example, `local.workload_vms` is passed to the compute module as `workload_vms`. Inside that
module the same value is called `var.workload_vms`. The module creates one NIC and VM for every map
entry, then returns maps of private IP addresses and managed-identity principal IDs.

## Where to make a change

| Change | Primary file | Why |
|---|---|---|
| Add or resize a VNet or subnet | `terraform/locals.tf` | The address plan is environment data |
| Add a VM or change its private IP | `terraform/locals.tf` | VM instances are part of this environment's topology |
| Enable a VM identity or supply cloud-init | `terraform/locals.tf` | These are explicit properties of each VM definition |
| Change DNS resolver addresses, zone, or test record | `terraform/locals.tf` | DNS values belong to the environment, not reusable module logic |
| Add a user-selectable deployment switch | `terraform/variables.tf` | Root variables are the external interface |
| Pass a new value between components | `terraform/main.tf` | The root module owns composition |
| Change how every VM, subnet, or gateway is created | The relevant `terraform/modules/*/main.tf` | Modules own repeated resource behavior |
| Change what a module accepts | The relevant `terraform/modules/*/variables.tf` | Module variables are typed contracts |
| Change Terraform or provider versions | `terraform/providers.tf` | Version selection is centralised for these private local modules |
| Change remote state configuration | `terraform/backend.tf` | Backend configuration is separate from providers and resources |

Use this rule:

> `locals.tf` describes this environment, `main.tf` connects components, and `modules/*` implement
> reusable behavior.

Do not add an environment-specific IP address or DNS name inside a child module. Pass it from the
root environment instead.

## Root variables, locals, and module variables

These three constructs have different jobs.

### Root variables

Root variables accept values from a caller, a `.tfvars` file, environment variables, or GitHub
Actions. Examples include `deploy_dns`, `vm_size`, and the sensitive VPN shared key.

```hcl
variable "deploy_dns" {
  type    = bool
  default = false
}
```

Use a root variable when a value should be selected at deployment time.

### Root locals

Locals name and transform values inside the configuration. They cannot be set directly by a caller.

```hcl
dns_config = {
  resolver_inbound_ip = "10.0.3.4"
  onprem_zone         = "corp.internal."
}
```

Use a root local when the value is part of this lab's design and should be reviewed in source control.

A local can also derive from an input, resource, or another local. For example,
`local.location = var.location` gives an input a convenient internal name; it does not turn that
caller-supplied value into a fixed constant.

### Module variables

A module variable defines the contract between the root module and a child module. Complex values use
explicit object types so Terraform can reject missing or incorrectly typed attributes before resource
creation.

```hcl
variable "workload_vms" {
  type = map(object({
    name            = string
    subnet_key      = string
    private_ip      = string
    location        = string
    enable_identity = optional(bool, false)
    custom_data     = optional(string)
  }))
}
```

`map(object(...))` means:

- the outer value has stable string keys such as `onprem` and `spoke`;
- every map value must match the declared object structure;
- `enable_identity` defaults to `false` when omitted;
- `custom_data` may be omitted or set to `null`.

This is safer than `type = any`, which accepts nearly any shape and moves mistakes deeper into the
module.

## Explicit behavior instead of magic names

A map key identifies an instance. It should not secretly decide what that instance does.

```hcl
spoke = {
  name            = "vm-spoke"
  subnet_key      = "spoke-snet-spoke-workloads"
  private_ip      = "10.1.0.4"
  location        = "swedencentral"
  enable_identity = true
  custom_data     = null
}
```

The compute module checks `each.value.enable_identity`. It does not check whether `each.key` happens
to equal `"spoke"`. Renaming a key still changes the Terraform instance address, but it no longer
silently changes VM capabilities.

The same rule applies to relationships. An NSG definition carries an explicit `vnet_key`; the network
module does not try to discover the VNet by splitting a subnet-name string.

## Module boundaries

| Module | Owns | Important inputs | Important outputs |
|---|---|---|---|
| `network` | VNets, subnets, NSGs, and associations | Network and NSG maps | VNet and subnet ID maps |
| `connectivity` | VPN public IPs, gateways, and connections | Gateway-network map, subnet IDs, connections | Gateway IDs and public IPs |
| `compute` | Lab VMs and Bastion | VM map, subnet IDs, SSH settings | VM IPs and identity principal IDs |
| `firewall` | Firewall, policy, rules, workspace, diagnostics | Firewall subnet and address ranges | Firewall public and private IPs |
| `routing` | Route tables and subnet associations | Firewall IP, subnet IDs, address ranges | No cross-module output is currently needed |
| `privatelink` | Key Vault, private endpoint, private DNS zone | Endpoint subnet and linked VNets | Vault ID/name and endpoint IP |
| `dns` | Private Resolver endpoints, ruleset, forwarding rule, links | Resolver subnets, DNS server, zone, linked VNets | Resolver name, inbound IP, outbound endpoint name, and ruleset name |

The modules are private implementation modules for this repository. Provider configuration and version
selection therefore remain in the root. If a module is later published or consumed independently, add
its own `terraform.required_providers`, supported Terraform version, README, examples, and tests.

## Phase 5 DNS configuration path

The hybrid DNS values are environment data in `terraform/locals.tf`:

```hcl
dns_config = {
  resolver_inbound_ip = "10.0.3.4"
  onprem_zone         = "corp.internal."
  onprem_dns_server   = local.onprem_workload_ip
  test_record_name    = "app.corp.internal"
}
```

The root module passes those values into the DNS module, which implements the resolver endpoints,
ruleset, forwarding rule, and links. The same local values generate the on-premises VM's cloud-init
configuration. That generated `dnsmasq` file binds only to `192.168.1.4`, marks `corp.internal` as
local, and creates the test host record.

Change the address, zone, or record in the root local rather than editing the child module or the
live VM. A manual repair on a VM disappears when the VM is replaced. Also review the plan carefully:
changing VM `custom_data` can require VM replacement because cloud-init is a first-boot mechanism.

## Safe change workflow

Run the static checks from `terraform/` before opening a pull request:

```bash
terraform fmt -recursive
terraform init -backend=false
terraform validate
tflint --recursive --format compact --config="$(pwd)/../.tflint.hcl"
```

`fmt`, `validate`, and TFLint check syntax, contracts, style, and static rules without accessing remote
state. In an authenticated planning environment, initialise the real backend and create a plan:

```bash
terraform init
terraform plan
```

Only `plan` shows the proposed infrastructure changes. Read it for unexpected replacement or deletion
before apply. GitHub Actions performs the authenticated backend initialization and plan for this
repository.

For a loop or type error, reduce the problem to one real map entry and inspect it with
`terraform console`. The complete method is in [patterns.md](patterns.md).

## tldr

> The root locals model the environment as typed data. The root main file composes domain-focused
> modules and passes resource IDs between them. Child modules enforce explicit input contracts and use
> stable map keys with `for_each` to create repeated resources. Environment-specific addresses and
> behavior stay at the root; modules implement the reusable mechanics.

## Related documentation

- [Terraform loops and collection patterns](patterns.md)
- [Architecture decisions](../decisions.md)
- [Troubleshooting](../troubleshooting.md)
- [Validation evidence](../validation/README.md)
