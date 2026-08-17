# Phase 0 validation: the pipeline

Phase 0 fixed a pipeline that reported success while deploying nothing. The only check that matters is whether it now deploys.

---

## The condition that could never match

```yaml
if: github.event_name == 'workflow_dispatch'
```

![Terraform Apply step gated on workflow_dispatch](../images/phase0-apply-condition-fixed.png)

> Must name an event that appears in the `on:` block. It previously named `push`, which had been removed as a trigger.

---

## Runs cannot race for the state lock

![Concurrency block, group terraform-state, cancel-in-progress false](../images/phase0-concurrency-group.png)

> Shared group name across apply and destroy, so the two cannot overlap either.

---

## Both workflows use the same Terraform

![terraform-destroy.yml pinned to 1.9.0](../images/phase0-destroy-version-pin.png)

> Apply was already pinned. Two versions against one state file is a problem waiting for a quiet moment.

---

## Verification is possible without the portal

![outputs.tf exposing the address plan, subnet IDs, gateway public IPs and a tunnel status command](../images/phase0-outputs-tf.png)

> Every later phase reads its addresses from here.

---

## The check that actually proves it

![Workflow run succeeding in 24m 28s with a green tick on Terraform Apply](../images/phase0-apply-step-now-runs.png)

> **Pass.** The apply step ran for 24 minutes instead of being skipped. Duration is the giveaway: a skipped apply finishes the whole job in under two minutes.

A skipped step renders as a circle-and-slash, not a tick, and does not fail the job. Worth knowing what that looks like:

![A run where the plan failed and Terraform Apply shows the skipped icon](../images/phase2-plan-failed-apply-skipped.png)
