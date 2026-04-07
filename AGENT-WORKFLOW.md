# Agent Workflow — Skills & Subagents

## The Documents

Every ticket starts with two documents at the workspace root:

| Document | Purpose |
|----------|---------|
| `{TICKET}-PLAN.md` | Phased implementation plan with steps, files, dependencies, verification commands |
| `{TICKET}-contracts.md` | Exact API contracts, DTOs, DB schema, frontend types, error messages |

---

## Phase 1: Planning

**Skill**: `planner-architect`
**How to invoke**: Start a new chat and say something like *"Plan PRCR-1300"* or *"Create a plan for this feature: ..."*

The agent asks you clarifying questions, reads the relevant source code, then produces both documents. Each phase in the plan gets a structured `phase-meta` YAML block that the downstream skills parse. You review and iterate before finalizing.

---

## Phase 2: Implementation

You have two paths depending on how much autonomy you want:

### Option A: Manual, one phase at a time

Say *"Implement phase 1 of PRCR-1260-v2"* — this triggers the **`implement-phase`** skill, which:

1. Reads the plan and contracts for that phase
2. Creates the phase branch via the **`stacked-branches`** skill (`tim/PRCR-1260-v2/phase-1`)
3. Reads the existing code in all files the phase touches
4. Implements each step from the checklist
5. Runs the phase's verification commands (lint, tests)
6. Commits with the format `PRCR-1260 [Compliance] Add converted_html_key column`

Then you say *"Create PR for phase 1"* — this triggers the **`phase-pr`** skill, which:

1. Runs the **`plan-compliance-reviewer`** subagent to verify the implementation matches the acceptance criteria and contracts
2. Runs the **`security-reviewer`** subagent on the diff
3. Fixes any critical findings
4. Pushes the branch and creates a stacked PR targeting the previous phase's branch
5. PR body includes summary, changes, acceptance criteria, test plan, stack diagram, and review results

Repeat for phase 2, 3, etc.

### Option B: Autonomous, multi-phase

Say *"Run the plan for PRCR-1260-v2"* or *"Orchestrate PRCR-1260-v2 phases 1-4"* — this invokes the **`orchestrator`** subagent, which:

1. Reads the plan and checks the status of all phases (branch exists? PR open? merged?)
2. Displays a status table
3. Finds the next unblocked phase
4. Asks for your confirmation
5. **Delegates** `implement-phase` to a sub-agent via the Task tool (fresh context)
6. **Delegates** both reviewers in parallel via Task tool (plan-compliance + security)
7. **Delegates** PR creation to a sub-agent via Task tool (`phase-pr`)
8. Asks if you want to continue to the next phase
9. Repeats until all phases are done or you stop it

The orchestrator stays lightweight — it only coordinates and tracks state. All
heavy work (coding, reviewing, PR creation) runs in dedicated sub-agents with
their own context windows.

---

## Supporting Operations

You can also use the **`stacked-branches`** skill directly for git operations:

| Command | What it does |
|---------|--------------|
| *"Stack status for PRCR-1260-v2"* | Shows a table of all phase branches — which exist, commit counts, ahead/behind |
| *"Rebase stack after phase 2 changed"* | Rebases phases 3, 4, ... onto the updated phase 2 |
| *"Switch to phase 3"* | Checks out the phase-3 branch |

---

## How Everything Connects

```
You: "Plan PRCR-1300"
  └── planner-architect skill
        ├── Produces PLAN.md
        └── Produces contracts.md

You: "Run the plan" (or "Implement phase 1")
  └── orchestrator subagent (or implement-phase skill directly)
        ├── stacked-branches skill → creates tim/PRCR-1300/phase-1
        ├── implement-phase skill → codes, tests, commits
        ├── plan-compliance-reviewer subagent → verifies vs acceptance criteria
        ├── security-reviewer subagent → scans for vulnerabilities
        └── phase-pr skill → pushes branch, creates stacked PR

(repeat for each phase)
```

---

## Quick Reference

| Name | Type | Location | Trigger |
|------|------|----------|---------|
| `planner-architect` | Skill | `.cursor/skills/planner-architect/` | "plan", "architect", "create a plan" |
| `stacked-branches` | Skill | `.cursor/skills/stacked-branches/` | "create phase branch", "stack status", "rebase stack" |
| `implement-phase` | Skill | `.cursor/skills/implement-phase/` | "implement phase N", "do phase N" |
| `phase-pr` | Skill | `.cursor/skills/phase-pr/` | "create PR", "PR for phase N" |
| `orchestrator` | Subagent | `.cursor/agents/orchestrator.md` | "run the plan", "orchestrate", "implement all phases" |
| `plan-compliance-reviewer` | Subagent | `.cursor/agents/plan-compliance-reviewer.md` | Called automatically by orchestrator and phase-pr |
| `security-reviewer` | Subagent | `.cursor/agents/security-reviewer.md` | Called automatically by orchestrator and phase-pr |
