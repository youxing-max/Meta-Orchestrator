---
name: Crystallization proposal
about: Suggest a workflow to bake into `workflows/` as a built-in
title: "[crystallize] "
labels: ["workflow"]
assignees: []
---

> Use this template when you've noticed a recurring task shape (3+
> non-trivial invocations with the same signature) and want to bake it
> into the project's `workflows/` directory as a built-in.

## Pattern signature

```
<!-- e.g. Read → Explore → Edit → Agent -->
```

## Task family

<!-- e.g. ui-bug-fix, config-update -->

## Count

<!-- How many times has this fired? -->

## First / last seen

<!-- YYYY-MM-DD -->

## Intent (one sentence)

<!-- What does this pattern represent? -->

## Proposed workflow YAML

```yaml
name: <kebab-case-name>
description: "<one-line>"
triggers:
  - <phrase users would say>
meta_priority: 10
composition:
  steps:
    - id: <step_id>
      kind: agent | generate | classify | input | tool
      prompt: |
        <full prompt>
      agent_type: <type if kind=agent>
      depends_on: []
```

## Why this should be a built-in (not just a user-local workflow)

<!-- Examples: this is a universally useful pattern / fixes a common
     failure mode / reduces a class of repeated mistakes -->

## Test plan

<!-- How would we verify this works after merging? -->
