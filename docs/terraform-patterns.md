# Terraform patterns used here

Notes on the one non-obvious technique in this repo: building three VNets and six subnets out of two resource blocks and a map.

---

## The problem

The naive version of this network is nine resource blocks. Three `azurerm_virtual_network`, six `azurerm_subnet`, each one a near-copy of the last with a different name and prefix. It works, and for three VNets it is arguably fine. It stops being fine the moment someone adds a fourth VNet and copies a block without changing every field in it.

The bigger issue is that the topology becomes something you have to reconstruct by reading resource blocks, instead of something you can just look at.

## The approach

Put the topology in one place, as data. Then loop over it.

### Step 1: the map

`terraform/locals.tf` holds the whole network shape:

```hcl
locals {
  networks = {
    onprem = {
      name          = "vnet-onprem"
      address_space = ["192.168.0.0/16"]
      subnets = {
        GatewaySubnet         = "192.168.0.0/24"
        snet-onprem-workloads = "192.168.1.0/24"
      }
    }
    hub = {
      name          = "vnet-hub"
      address_space = ["10.0.0.0/16"]
      subnets = {
        GatewaySubnet       = "10.0.0.0/24"
        AzureFirewallSubnet = "10.0.1.0/24"
        AzureBastionSubnet  = "10.0.2.0/24"
      }
    }
    spoke = {
      name          = "vnet-spoke"
      address_space = ["10.1.0.0/16"]
      subnets = {
        snet-spoke-workloads = "10.1.0.0/24"
      }
    }
  }
}
```

That block is now the address plan. It answers "what is the spoke's range" without reading a single resource.

The top-level keys (`onprem`, `hub`, `spoke`) are short handles used elsewhere in the config to refer to a network. They are separate from the Azure resource names (`vnet-onprem` and so on) on purpose, so a rename in Azure does not ripple through every reference.

### Step 2: VNets loop directly

VNets sit at the top level of the map, so `for_each` can consume it as-is:

```hcl
resource "azurerm_virtual_network" "vnet" {
  for_each            = local.networks
  name                = each.value.name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = each.value.address_space
}
```

Three VNets, one block. Terraform addresses them as `azurerm_virtual_network.vnet["hub"]`, which is how the rest of the config refers back to them.

### Step 3: subnets need flattening first

Subnets are nested one level down, inside each network. `for_each` wants a flat map or set, not a map of maps of strings. So the nesting has to be unrolled.

```hcl
all_subnets = flatten([
  for vnet_key, vnet_val in local.networks : [
    for subnet_name, address_prefix in vnet_val.subnets : {
      key            = "${vnet_key}-${subnet_name}"
      vnet_key       = vnet_key
      vnet_name      = vnet_val.name
      subnet_name    = subnet_name
      address_prefix = address_prefix
    }
  ]
])
```

Two nested `for` expressions walk networks, then subnets within each network, producing one object per subnet. Without `flatten()` the result would be a list of lists, one inner list per VNet. `flatten()` collapses that into a single flat list:

```text
{ key = "onprem-GatewaySubnet",         vnet_key = "onprem", address_prefix = "192.168.0.0/24" }
{ key = "onprem-snet-onprem-workloads", vnet_key = "onprem", address_prefix = "192.168.1.0/24" }
{ key = "hub-GatewaySubnet",            vnet_key = "hub",    address_prefix = "10.0.0.0/24"    }
{ key = "hub-AzureFirewallSubnet",      vnet_key = "hub",    address_prefix = "10.0.1.0/24"    }
{ key = "hub-AzureBastionSubnet",       vnet_key = "hub",    address_prefix = "10.0.2.0/24"    }
{ key = "spoke-snet-spoke-workloads",   vnet_key = "spoke",  address_prefix = "10.1.0.0/24"    }
```

Each object carries `vnet_key` along with it. That is the important detail. Once flattened, a subnet has lost its position in the hierarchy, so it has to remember which VNet it belongs to.

The composite `key` matters too. Both `vnet-onprem` and `vnet-hub` contain a subnet called `GatewaySubnet`, and Azure requires that exact name. Prefixing with the network handle keeps the two distinguishable.

### Step 4: the subnet loop

```hcl
resource "azurerm_subnet" "subnet" {
  for_each             = { for s in local.all_subnets : s.key => s }
  name                 = each.value.subnet_name
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet[each.value.vnet_key].name
  address_prefixes     = [each.value.address_prefix]
}
```

`for_each` needs a map, and `flatten()` returned a list, so there is one more conversion: `{ for s in local.all_subnets : s.key => s }` turns the list into a map keyed by the composite key.

The `vnet_key` carried through the flatten is what makes `azurerm_virtual_network.vnet[each.value.vnet_key].name` work. That reference is also what tells Terraform the subnet depends on its VNet, so no explicit `depends_on` is needed.

---

## Why `for_each` and not `count`

`count` indexes by position. Removing the second of three subnets shifts everything after it down by one, and Terraform reads that as "subnet 2 changed and subnet 3 was deleted" rather than "subnet 2 was deleted".

`for_each` indexes by key. `azurerm_subnet.subnet["hub-AzureFirewallSubnet"]` stays that address regardless of what else is added or removed. For a map-driven config this is not a preference, it is the only correct choice.

The corollary: **the keys are part of the state address.** Renaming `spoke` to `spoke1` in the map is not a rename to Terraform. It is a destroy and a create. Fine for a subnet, considerably less fine for a VPN gateway that takes 40 minutes to build. Use `terraform state mv` or a `moved` block if a key ever has to change.

---

## Where the loop is currently wrong

The public IP resource also loops over `local.networks`:

```hcl
resource "azurerm_public_ip" "vpn_pip" {
  for_each = local.networks
  name     = "pip-vpn-${each.key}"
  ...
}
```

But only two of the three networks have a gateway. The spoke deliberately has none, since it borrows the hub's. So this produces `pip-vpn-spoke`, which is created, billed, and attached to nothing.

This is the classic failure mode of map-driven config: the map became the answer to a question it was not built for. `local.networks` describes address space, not which networks have gateways.

The fix is to make that fact explicit in the data rather than filtering by hand:

```hcl
networks = {
  onprem = { ...  has_gateway = true  }
  hub    = { ...  has_gateway = true  }
  spoke  = { ...  has_gateway = false }
}

resource "azurerm_public_ip" "vpn_pip" {
  for_each = { for k, v in local.networks : k => v if v.has_gateway }
  ...
}
```

Now the map still answers the question, and the config still has no hardcoded resource names.

---

## Where the schema has to grow next

A subnet is currently modelled as a bare string: `GatewaySubnet = "10.0.0.0/24"`. That works for exactly as long as every subnet needs the same treatment.

Phase 5 of [plan.md](../plan.md) breaks it. Azure DNS Private Resolver endpoints need subnets delegated to `Microsoft.Network/dnsResolvers`, and delegation is a nested block, not a string. Phase 3 breaks it again with per-subnet route tables and NSGs.

There are two ways to respond. The tempting one is to pull those subnets out of the loop and write them as standalone resources, which is how map-driven configs usually start to rot: the general case stays in the loop and the interesting cases accumulate outside it, until the loop describes less and less of the network.

The better response is to make the value an object, so a subnet can carry extra settings without any other subnet having to care:

```hcl
subnets = {
  GatewaySubnet       = { prefix = "10.0.0.0/24" }
  AzureFirewallSubnet = { prefix = "10.0.1.0/24" }
  snet-dns-inbound    = { prefix = "10.0.3.0/28", delegation = "Microsoft.Network/dnsResolvers" }
}
```

The flatten changes by two lines, `address_prefix = subnet.prefix` and `delegation = try(subnet.delegation, null)`, and the resource grows a block that produces nothing for subnets that did not ask for one:

```hcl
dynamic "delegation" {
  for_each = each.value.delegation == null ? [] : [each.value.delegation]
  content {
    name = "delegation"
    service_delegation {
      name    = delegation.value
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}
```

Two details make this safe. The composite keys are unchanged, so `azurerm_subnet.subnet["hub-GatewaySubnet"]` stays at the same state address and nothing is destroyed and recreated. And `try()` keeps every existing entry valid without having to write `delegation = null` on all of them.

This approach has been checked offline against the real config: it validates, and the flatten expands to nine subnets with delegation set on exactly the two DNS ones. The change itself has not been made yet.

The general lesson is worth more than the specific fix. When a loop stops fitting, the question is whether the *data* is missing a field or whether the *abstraction* is wrong. Here it was the data. It is only the abstraction being wrong when the conditionals start outnumbering the things they configure.

---

## Honest trade-offs

**Reading a plan gets harder.** `azurerm_subnet.subnet["hub-AzureFirewallSubnet"]` is more to parse than `azurerm_subnet.firewall`. On a large change the diff is noisier.

**Errors point at the loop, not the entry.** A bad CIDR in one subnet produces an error against the resource block, and you have to work out which map entry caused it.

**Abstractions leak.** The moment one VNet needs something the others do not, such as DDoS protection or a specific DNS server list, the uniform loop has to grow conditionals. Two or three of those and the map is harder to read than nine plain resource blocks would have been.

For a topology of this shape and size, the trade is clearly worth it. It is worth re-checking, not assuming, when the config grows.
