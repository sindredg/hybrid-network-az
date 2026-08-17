# Phase 1 validation: the tunnel

The topology deploys from the pipeline, the connections come up, and it all tears down again. What this phase does *not* establish is that any traffic crosses the tunnel: that is [Phase 2](phase-2-connectivity.md).

---

## Deploy

![Terraform plan reading 18 to add, followed by the apply creating the resource group](../images/terraform-plan-and-apply-start.png)

![Workflow run succeeding in 21m 54s](../images/successful-deploy-run.png)

> **Pass.** 21m54s, almost all of it the two gateways.

---

## Resources in the portal

![Resource group listing both connections, three public IPs, two gateways and three VNets in Sweden Central](../images/deployed-resources-portal.png)

> `pip-vpn-spoke` is visible here and attached to nothing. The spoke has no gateway, but the public IP resource looped over all three networks. Fixed in Phase 0.

---

## Teardown

![Destroy Infrastructure job started from workflow_dispatch](../images/destroy-run-started.png)

![Plan: 0 to add, 0 to change, 19 to destroy](../images/destroy-plan-19-resources.png)

![Destroy complete! Resources: 19 destroyed](../images/destroy-complete-19-resources.png)

> **Pass.** 19 resources removed in roughly 17 minutes. This is also the first authoritative count of what the lab consists of.

---

## What was not established

Both connections reported `Connected`. That is a status field, not evidence: it says the IPsec security association is established, not that a packet can traverse it, that routing works, or that anything at the far end would answer.

Everything in Phase 2 exists because of that gap.
