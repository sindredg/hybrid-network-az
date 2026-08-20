# Terraform loops and collection patterns

[Terraform guide](README.md) > Loops and collection patterns

This guide explains the main non-obvious pattern in the repository: turning one nested network map
into three VNets and nine subnets. It uses one real subnet—`hub-snet-dns-inbound`—and follows it
from the input map to its Terraform resource address.

## Terraform looping fundamentals

Terraform has several features that look like loops but do different jobs:

| Feature | Purpose | Result |
|---|---|---|
| `for` expression | Transform or filter data | A new list, tuple, map, or object value |
| Resource `for_each` | Create one resource instance per map or set entry | Multiple keyed resource instances |
| Resource `count` | Create a known nonnegative number of positionally identified instances | Multiple numbered resource instances |
| `dynamic` block | Repeat a nested configuration block | Zero or more nested blocks inside one resource instance |

The most important distinction is this:

> A `for` expression builds a value. `for_each` and `count` build resource instances.

### Collections you can loop over

You need to know the input shape before writing a loop.

The most reliable way to identify an exact type is to read its type constraint:

```hcl
# List: ordered values of one element type, addressed by numeric index.
variable "locations" {
  type    = list(string)
  default = ["swedencentral", "denmarkeast"]
}

# Set: unique values of one element type with no meaningful position.
variable "protocols" {
  type    = set(string)
  default = ["Tcp", "Udp"]
}

# Map: dynamic string keys whose values all have the same type.
variable "vnet_ranges" {
  type = map(string)
  default = {
    hub   = "10.0.0.0/16"
    spoke = "10.1.0.0/16"
  }
}

# Object: a fixed schema of named attributes, which may have different types.
variable "hub" {
  type = object({
    name          = string
    address_space = list(string)
    has_gateway   = bool
  })

  default = {
    name          = "vnet-hub"
    address_space = ["10.0.0.0/16"]
    has_gateway   = true
  }
}
```

Literal syntax alone is not always enough to name the exact type. `[...]` initially describes a
tuple value and `{...}` initially describes an object value; Terraform may convert them to
`list(...)`, `set(...)`, or `map(...)` when a variable constraint, function, or resource argument
provides the required context.

The practical distinction is:

- a list has ordered elements of one type;
- a set has unique elements of one type and no positional identity;
- a map has potentially dynamic string keys and values of one type;
- an object has a declared set of attributes and can give each attribute a different type.

A list or set loop normally uses one iterator name for the current value. A map loop can use two:
the current key and its value.

### Basic list transformation

The general shape is:

```hcl
[for current_value in collection : result_expression]
```

Example:

```hcl
upper_names = [
  for network_name in ["hub", "spoke"] : upper(network_name)
]
```

Result:

```hcl
["HUB", "SPOKE"]
```

Read it aloud:

> For every `network_name` in the input list, put `upper(network_name)` into a new list.

`network_name` exists only while evaluating the expression. It does not change the input list.

### Use an index when you genuinely need one

For a list or tuple, Terraform permits two iterator names. The first receives the numeric index and
the second receives the value:

```hcl
numbered_names = [
  for index, network_name in ["hub", "spoke"] :
  "${index}-${network_name}"
]
```

Result:

```hcl
["0-hub", "1-spoke"]
```

Do not use the index as a resource identity merely because it is available. Positions change when
items are inserted or removed; meaningful map keys are safer for resources.

### Loop over a map

The general shape is:

```hcl
[
  for current_key, current_value in map_name :
  result_expression
]
```

Example:

```hcl
network_descriptions = [
  for network_key, address_range in {
    hub   = "10.0.0.0/16"
    spoke = "10.1.0.0/16"
  } :
  "${network_key} uses ${address_range}"
]
```

Result:

```hcl
[
  "hub uses 10.0.0.0/16",
  "spoke uses 10.1.0.0/16"
]
```

For the `hub` iteration:

```text
network_key  = "hub"
address_range = "10.0.0.0/16"
```

That is all `k` and `v` usually mean: someone shortened `network_key` and `address_range` to single
letters.

### Build a map instead of a list

Square brackets produce a list or tuple. Curly braces with `=>` produce a map or object:

```hcl
vnet_names = {
  for network_name in ["hub", "spoke"] :
  network_name => "vnet-${network_name}"
}
```

Result:

```hcl
{
  hub   = "vnet-hub"
  spoke = "vnet-spoke"
}
```

Read the expression after the colon as:

```text
new map key => new map value
```

In the example, the new key is `network_name` and the new value is `"vnet-${network_name}"`.

### Filter with `if`

Place `if` after the output expression:

```hcl
web_ports = [
  for port in [22, 80, 443] : port
  if port == 80 || port == 443
]
```

Result:

```hcl
[80, 443]
```

Read it as:

> For every port, copy the port into the result only if it is 80 or 443.

A map comprehension can filter in exactly the same way:

```hcl
gateway_networks = {
  for network_key, network_config in local.networks :
  network_key => network_config
  if network_config.has_gateway
}
```

### Resource `for_each`

A `for` expression can prepare a map, and a resource can consume that map with `for_each`:

```hcl
locals {
  vnet_ranges = {
    hub   = "10.0.0.0/16"
    spoke = "10.1.0.0/16"
  }
}

resource "azurerm_virtual_network" "example" {
  for_each = local.vnet_ranges

  name          = "vnet-${each.key}"
  address_space = [each.value]
}
```

Terraform creates two instances:

```text
azurerm_virtual_network.example["hub"]
azurerm_virtual_network.example["spoke"]
```

Inside the `hub` instance:

```text
each.key   = "hub"
each.value = "10.0.0.0/16"
```

For resources, `for_each` accepts a map or a set of strings. A list of objects must first be
converted into a map with stable keys, as the subnet walkthrough later demonstrates.

### Resource `count`

`count` creates numbered instances:

```hcl
resource "example_resource" "server" {
  count = 3
  name  = "server-${count.index}"
}
```

The addresses are:

```text
example_resource.server[0]
example_resource.server[1]
example_resource.server[2]
```

The count value can be any nonnegative integer known before Terraform expands the resource, not only
a hard-coded number:

```hcl
count = length(var.server_names)
name  = var.server_names[count.index]
```

Those instances may have different argument values through `count.index`, but their identities are
still positional: `[0]`, `[1]`, and so on. Removing an item from the middle of `server_names` shifts
the later positions.

Use `count` when positional identity is acceptable, or when a simple condition should produce zero
or one instance:

```hcl
count = var.deploy_firewall ? 1 : 0
```

Use `for_each` when instances have meaningful identities such as `hub`, `spoke`, or a subnet key.

### A repeatable method for writing your own loop

When writing a `for` expression from scratch:

1. **Write down the input type.** Is it a list, set, map, or object?
2. **Take one real input item.** For example, `"hub" = "10.0.0.0/16"`.
3. **Write the desired output for that one item.** For example, `"hub" = "vnet-hub"`.
4. **Choose descriptive iterator names.** Use `network_key`, not `k`.
5. **Choose the output brackets.** Use `[...]` for a list and `{ key => value }` for a map.
6. **Add a filter last.** First make the transformation work; then append `if condition`.
7. **For resource `for_each`, choose a stable unique key.** That key becomes part of the instance
   address and should not depend on list position.

The reusable templates are:

```hcl
# List result
[for current_value in collection : new_value]

# List result from a map
[for current_key, current_value in map : new_value]

# Map result
{ for current_value in collection : new_key => new_value }

# Filtered map result
{
  for current_key, current_value in map :
  new_key => new_value
  if condition
}
```

### Test expressions before putting them in resources

After `terraform init`, use `terraform console` to experiment without applying infrastructure:

```text
> [for name in ["hub", "spoke"] : upper(name)]
[
  "HUB",
  "SPOKE",
]

> { for name in ["hub", "spoke"] : name => "vnet-${name}" }
{
  "hub"   = "vnet-hub"
  "spoke" = "vnet-spoke"
}
```

The safest debugging technique is to run the expression mentally for one item: substitute the real
key and value, calculate the output, then repeat for the next item.

### Common beginner mistakes

- Confusing `for` with `for_each`: one creates a value; the other creates resource instances.
- Using `{}` when a list is wanted, or `[]` when a keyed map is needed.
- Forgetting `key => value` when building a map.
- Passing a `list(object)` directly to resource `for_each`.
- Choosing a non-unique map key, which produces a duplicate-key error.
- Using a list index as long-term resource identity.
- Reading `k`, `v`, or `s` as Terraform keywords instead of arbitrary local names.

## The 30-second interview explanation

> I modelled the topology as a nested map so the address plan is data rather than repeated resource
> blocks. The network module loops directly over the VNet map. Because subnets are nested inside each
> VNet, I use nested `for` expressions and `flatten()` to produce one flat subnet list. I preserve the
> parent VNet key in every subnet object, then convert the list to a map keyed by a stable composite
> key such as `hub-snet-dns-inbound`. `for_each` creates one resource per map entry, and the preserved
> parent key lets each subnet reference its VNet. I chose `for_each` over `count` so resource addresses
> remain stable when unrelated entries are added or removed.

That is the entire pattern. The rest of this document takes it apart line by line.

## First: `k`, `v`, and `s` do not mean anything special

In a Terraform `for` expression, iterator names are chosen by the author. Terraform does not assign
special meaning to `k`, `v`, or `s`.

```hcl
{ for k, v in local.networks : k => v }
```

This is identical to:

```hcl
{
  for network_key, network_config in local.networks :
  network_key => network_config
}
```

For a map, the first name receives the current map key and the second receives its value:

| Shorthand | Descriptive name | Example value |
|---|---|---|
| `k` | `network_key` | `"hub"` |
| `v` | `network_config` | the object containing `name`, `location`, `address_space`, and `subnets` |
| `s` | `subnet` | one object from `local.all_subnets` |

Use descriptive names when explaining the code. Single letters save a few keystrokes but hide the
data model.

Two names *are* provided by Terraform:

- `each.key` and `each.value` exist inside a resource or module using `for_each`.
- A `dynamic "delegation"` block creates an iterator called `delegation`, so its current item is
  available as `delegation.value`.

## Where the data starts

The root `terraform/locals.tf` contains the address plan. This is the relevant part of the real hub
entry:

```hcl
networks = {
  hub = {
    name          = "vnet-hub"
    location      = "swedencentral"
    address_space = ["10.0.0.0/16"]
    has_gateway   = true
    subnets = {
      GatewaySubnet       = { prefix = "10.0.0.0/24" }
      AzureFirewallSubnet = { prefix = "10.0.1.0/24" }
      snet-dns-inbound = {
        prefix     = "10.0.3.0/28"
        delegation = "Microsoft.Network/dnsResolvers"
      }
      snet-dns-outbound = {
        prefix     = "10.0.3.16/28"
        delegation = "Microsoft.Network/dnsResolvers"
      }
    }
  }
}
```

`hub` is the Terraform map key. `vnet-hub` is the Azure resource name. Keeping those separate gives
the configuration a short, stable handle for references.

The root module passes this map into the network module as `networks`. Therefore:

- at root it is called `local.networks`;
- inside `modules/network` it is called `var.networks`.

They are the same data at different module scopes.

## Concrete walkthrough: one subnet through the whole transformation

### Step 1: create one object for every nested subnet

The network module contains this local value:

```hcl
locals {
  all_subnets = flatten([
    for network_key, network_config in var.networks : [
      for subnet_name, subnet_config in network_config.subnets : {
        key            = "${network_key}-${subnet_name}"
        vnet_key       = network_key
        subnet_name    = subnet_name
        address_prefix = subnet_config.prefix
        delegation     = subnet_config.delegation
      }
    ]
  ])
}
```

Now follow only `hub → snet-dns-inbound`.

The outer loop assigns:

```text
network_key    = "hub"
network_config = the complete hub object
```

The inner loop then assigns:

```text
subnet_name   = "snet-dns-inbound"
subnet_config = {
  prefix     = "10.0.3.0/28"
  delegation = "Microsoft.Network/dnsResolvers"
}
```

Those four values produce this one output object:

```hcl
{
  key            = "hub-snet-dns-inbound"
  vnet_key       = "hub"
  subnet_name    = "snet-dns-inbound"
  address_prefix = "10.0.3.0/28"
  delegation     = "Microsoft.Network/dnsResolvers"
}
```

The object carries `vnet_key = "hub"` because flattening removes the original nesting. Without that
field, the subnet would no longer remember which VNet owns it.

The module contract declares `delegation` as optional. Terraform therefore supplies `null` when a
subnet omits it; normal workload subnets do not need to repeat `delegation = null` in the input map.

### Step 2: understand what `flatten()` changes

The outer loop produces one inner list per VNet:

```text
[
  [four hub subnet objects],
  [three on-premises subnet objects],
  [two spoke subnet objects]
]
```

Terraform traverses map keys lexically, which is why `hub` appears before `onprem` and `spoke` here.
The design does not rely on that order; the stable map keys provide identity later.

`flatten()` removes one or more nested list layers:

```text
[
  subnet object 1,
  subnet object 2,
  ...
  subnet object 9
]
```

It does not merge the objects or discard fields. It only changes a list of lists into one list.

### Step 3: turn the flat list into a map for `for_each`

Resource `for_each` accepts a map or a set of strings. `local.all_subnets` is a `list(object)`, so it
cannot be passed directly; it must become a map whose keys identify the resource instances.

The real subnet resource says:

```hcl
for_each = { for subnet in local.all_subnets : subnet.key => subnet }
```

Read it with `s` renamed:

```hcl
for_each = {
  for subnet in local.all_subnets :
  subnet.key => subnet
}
```

Read that sentence aloud as:

> For every subnet object in `local.all_subnets`, create a map entry whose key is `subnet.key` and
> whose value is the complete subnet object.

For the example subnet, the generated map contains:

```hcl
"hub-snet-dns-inbound" = {
  key            = "hub-snet-dns-inbound"
  vnet_key       = "hub"
  subnet_name    = "snet-dns-inbound"
  address_prefix = "10.0.3.0/28"
  delegation     = "Microsoft.Network/dnsResolvers"
}
```

The expression uses `=>` because it is building a map: left side is the new map key, right side is
the new map value.

### Step 4: `each.value` configures the resource instance

```hcl
resource "azurerm_subnet" "subnet" {
  for_each = { for subnet in local.all_subnets : subnet.key => subnet }

  name                 = each.value.subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet[each.value.vnet_key].name
  address_prefixes     = [each.value.address_prefix]
}
```

For the instance keyed by `hub-snet-dns-inbound`:

```text
each.key                  = "hub-snet-dns-inbound"
each.value.subnet_name    = "snet-dns-inbound"
each.value.vnet_key       = "hub"
each.value.address_prefix = "10.0.3.0/28"
```

Therefore this reference:

```hcl
azurerm_virtual_network.vnet[each.value.vnet_key].name
```

becomes conceptually:

```hcl
azurerm_virtual_network.vnet["hub"].name
```

That resolves to `vnet-hub`. It also creates an implicit dependency, so Terraform knows to create
the VNet before its subnet.

The final Terraform state address is:

```text
module.network.azurerm_subnet.subnet["hub-snet-dns-inbound"]
```

## Why the composite key matters

Both the hub and on-premises VNets contain a subnet literally named `GatewaySubnet`. A map cannot
contain the same key twice, so `subnet_name` alone is not unique.

Combining the parent and child keys produces stable unique identities:

```text
hub-GatewaySubnet
onprem-GatewaySubnet
```

These are instance keys embedded in the full Terraform state addresses. Renaming `hub` to `core` is
therefore not cosmetic: Terraform sees the old resource key disappear and a new key appear. Use a
`moved` block when a key must change.

## Two smaller patterns in the same code

### Filter a map

The root configuration filters the network map with descriptive iterator names:

```hcl
gateway_networks = {
  for network_key, network_config in local.networks :
  network_key => network_config
  if network_config.has_gateway
}
```

Read it as: “copy every network into a new map only if `has_gateway` is true.” The result contains
`hub` and `onprem`, but not `spoke`.

### Conditionally emit a nested block

Only the two DNS resolver subnets need Azure delegation:

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

Terraform does not have a direct `if` argument for nested blocks, so this uses a zero-or-one-item
collection:

- no delegation value → `[]` → create zero `delegation` blocks;
- delegation value present → `[value]` → create one `delegation` block.

Inside the dynamic block, `delegation.value` is the single string being iterated.

## Why `for_each` instead of `count`

`count` identifies instances by position, such as `[0]`, `[1]`, and `[2]`. Removing an item from the
middle can shift later indexes and make an unrelated resource appear to change.

`for_each` identifies instances by stable keys:

```text
azurerm_subnet.subnet["hub-GatewaySubnet"]
azurerm_subnet.subnet["hub-snet-dns-inbound"]
```

Adding another subnet does not renumber either existing instance.

## Interview questions this pattern answers

**Why use a map?**

It makes the address plan the source of truth and removes repeated resource blocks.

**Why flatten the data?**

The source data is hierarchical—networks contain subnets—but each Terraform resource instance needs
one subnet object. `flatten()` creates that list of objects; the following map expression reshapes it
into a type resource `for_each` accepts.

**Why preserve `vnet_key`?**

Flattening removes hierarchy, so the child object must carry a reference to its parent.

**Why convert the list to a map?**

A map supplies stable, meaningful keys for `for_each` and Terraform state.

**What is the trade-off?**

The code is more abstract than separate resource blocks. Plan addresses are longer, errors often
point at the shared loop, and changing a map key changes the state address. For repeated, structurally
similar resources the consistency is worth it; if exceptions start dominating the loop, separate
resources or a different module boundary may be clearer.

## A rule for readable Terraform

Prefer this:

```hcl
for network_key, network_config in local.networks
```

over this:

```hcl
for k, v in local.networks
```

Both work. Only the first one helps the next person—including you in an interview—explain what the
expression is doing without mentally decoding every letter.
