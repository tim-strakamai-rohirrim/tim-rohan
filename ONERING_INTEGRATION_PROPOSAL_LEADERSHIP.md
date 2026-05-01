# ONERING as Engine: Integration Proposal

_A leadership-facing summary. For the full technical version with file paths, schemas, and operational details, see `ONERING_INTEGRATION_PROPOSAL.md`._

## Executive Summary

Three of our modules — **Acquisition Center**, **Answer Engine v2**, and **Compliance** — independently reinvent the same core capabilities: document ingestion, knowledge retrieval, requirement extraction, and structured generation. ONERING already provides all of these as a single, more capable engine.

**Compliance has the strongest fit and has not yet launched, making it the ideal first integration target.** Answer Engine v2 (already in production) and Acquisition Center are deferred several months while Compliance proves the engine pattern.

We don't have to start from scratch. **A working ONERING integration already exists in the codebase**, with Proposal Launch and Opportunity Discovery DAGs implemented end-to-end and running in lower environments. ONERING has not yet been deployed to production — Compliance Phase 1 will be the first production-facing workload. Phase 1 extends this in-progress path rather than building parallel infrastructure.

**Recommended sequence:**

1. **Phase 1 (plan for 6–8 weeks; 3–5 weeks is the stretch case):** Ship a thin Compliance launch on ONERING, reusing the existing infrastructure.
2. **Phase 2 (post-launch):** Expand Compliance scope (additional extraction views, response analysis, XLSX export).
3. **Phase 3 (months out):** Migrate Answer Engine v2.
4. **Phase 4 (further out):** Migrate Acquisition Center sub-features.

**On the Phase 1 timeline:** "3–5 weeks" is the optimistic end of plausible, not the middle. Once first-production cutover of the ONERING stack is in scope (which it is — Compliance is the first ONERING workload to go to prod), the realistic range is 6–8 weeks. 3–5 weeks remains achievable but only if multiple conditions hold simultaneously (see "Phase 1 timeline reality" below). The recommendation is to plan against 6–8 weeks and pair the work with hard fallback gates at weeks 1 and 2 — not to commit to 3–5 and slip.

---

## What Each Module Does Today

### Acquisition Center (Procurement Writer)
A multi-step procurement drafting workflow — Market Research, RFI Assistant, Requirements Discovery, Document Library, Template Generator, Toolkits. Each assistant has its own AI pattern wired up independently.

### Answer Engine v2
Threaded conversational Q&A with knowledge-base retrieval, deep research, file uploads, and streaming responses. Recently shipped to production.

### Compliance
Source-document compliance extraction → manual review → response-document upload → automated cross-check → reviewer adjudication. **Not yet in production.** Launch target is approximately a few weeks out, with sales eager to begin selling the module as soon as it ships.

---

## What ONERING Gives Us

ONERING is our internal AI engine. Its capabilities map cleanly onto what each module is currently building piecemeal:

| ONERING capability                        | Compliance               | AE v2                      | Acquisition Center        |
| ----------------------------------------- | ------------------------ | -------------------------- | ------------------------- |
| Document ingestion (parse, OCR, chunking) | ✅ Direct replacement    | ✅ Direct replacement      | ✅ Direct replacement     |
| Requirement extraction (shall/must)       | ✅ Direct replacement    | —                          | ✅ Replaces Reqs Discovery|
| Structure / evaluation / instructions extraction | ✅ Net-new views | —                          | ✅ Powers Template Generator |
| Compliance matrix (six-tab XLSX)          | ✅ Free export           | —                          | —                         |
| KM retrieval with query plans             | Improves response analysis | ✅ Direct replacement    | ✅ Replaces vector calls  |
| Section writer (draft → critique → revise)| Optional commentary      | ✅ Better aggregates       | ✅ Replaces one-shot LLM  |
| GOLD library (past-proposal corpus)       | —                        | Opt-in answer source       | ✅ Vendor / template suggestions |
| Render layer (DOCX/PPTX/XLSX)             | ✅ Matrix export         | ✅ Aggregate export        | ✅ Replaces existing exporter |
| Resumable, parallel orchestrator          | Per-project runs         | Resumable deep research    | ✅ Replaces JSONB state   |
| Deep research with web search             | —                        | ✅ Direct replacement      | ✅ Replaces MRA research  |
| SAM.gov discovery                         | —                        | —                          | ✅ Already wired          |

The engine pattern reduces duplicated AI plumbing across the product and gives every module access to the same audit trail, evidence anchoring, and high-quality structured generation.

---

## Architecture Target

```
┌──────────────────────────────────────────────────┐
│ rohan_ui (Angular)                               │
│   compliance / answer-engine-v2 / acquisition    │
└────────────────────┬─────────────────────────────┘
                     │
┌────────────────────▼─────────────────────────────┐
│ rohan_api (NestJS) — orchestration shell         │
│   Owns: projects, threads, items, RBAC, review   │
└──────────┬─────────────────────────┬─────────────┘
           │                         │
   Long async work          Fast inline work
   (full extractions,       (KM retrieval,
    proposal generation)    single-section writes)
           │                         │
┌──────────▼──────────┐   ┌──────────▼─────────────┐
│ Airflow on AKS      │   │ Python wrapper API     │
│ Already in prod     │   │ Built in Phase 3       │
└──────────┬──────────┘   └──────────┬─────────────┘
           │                         │
           └────────────┬────────────┘
                        │
┌───────────────────────▼──────────────────────────┐
│ ONERING engine                                   │
│   CLI + library + DAGs + Helm chart              │
└──────────────────────────────────────────────────┘
```

**Two transport paths, each suited to its workload:**

- **Airflow** for long batch work (full extractions, proposal generation). Already proven in production. **Compliance Phase 1 uses this path.**
- **Python wrapper API** for fast inline operations (knowledge retrieval, single-section writes). Doesn't exist yet — built in Phase 3 for Answer Engine v2.

---

## What's Already Built

This proposal leans on infrastructure already implemented and exercised in lower environments. Phase 1 is mostly an extension exercise rather than a build-from-scratch — but **first production cutover is still ahead of us**, and Compliance will be that cutover.

**Already implemented (running in dev / staging, not yet prod):**

- A full ONERING integration namespace in our API (seven controllers, eleven services, ~8,300 lines of code).
- An Airflow deployment recipe on AKS with a Helm chart (including a `values-prod.yaml`), hot-reload local dev, and per-task pod resource profiles.
- Run-tracking infrastructure (database table, status polling, artifact retrieval, error mapping).
- Two DAGs implemented end-to-end — Proposal Launch and Opportunity Discovery.
- Established conventions for tenancy, authentication, and per-org access control.

**Recent commit history shows the team is actively converging on the patterns this proposal recommends.** Adding Compliance lines up with that direction rather than fighting it.

**What this means for Phase 1:** the engineering surface is mature, but Compliance is taking on the additional responsibility of being the **first production deployment** of the ONERING stack. The "first production use" risk is real and should be planned for explicitly, not assumed away.

---

## Phase 1 — Compliance Launch (plan for 6–8 weeks)

### Scope

Ship a thin Compliance launch as a new Airflow DAG following the same pattern as our existing Proposal Launch DAG.

**In scope:**

- New Compliance DAG that ingests source documents and extracts compliance items (the shall/must statements that drive compliance reviews).
- API endpoints to trigger the DAG and surface its results.
- UI adaptation so Compliance items flow from the new pipeline. The recently-shipped tag UI work is preserved unchanged.
- Status polling and result materialization in the API.
- Schema validation and a dev-mode mock so most engineers don't need to run Airflow locally.

**Out of scope (deferred to Phase 2):**

- Five additional extraction views (structure, evaluation, instructions, attachments, metadata).
- Compliance matrix XLSX export.
- Response analysis (compare a response document against extracted requirements). Genuinely new ONERING capability — concentrates the production-scale unknowns and benefits from launch-period learnings.
- The Python wrapper API (Phase 3 work).

### What sales can demo at launch

> "AI extracts compliance requirements from your RFP, your team reviews and adjudicates them, and automated response analysis is coming next quarter."

### Operational decisions already made

The technical details are pinned down in the full proposal. At a leadership level, the relevant points:

- **Tenancy.** Reuses the established per-org access-control patterns — no new design work.
- **Run completion.** Polling-based, reusing our existing reconciliation service. Simple and proven.
- **Engine version stability.** ONERING is evolving fast. We pin to a tagged release, validate artifact contracts via JSON schema, and run a CI cross-check. Updates are deliberate, not ambient.
- **Capacity planning.** Pre-launch bump to Airflow's shared AI pools so Compliance doesn't starve existing workloads.
- **Audit trail.** Every LLM call is persisted per-run; we can deep-link from the UI to the audit-trail browser for any extracted item. Material debuggability and compliance-story win.
- **Local dev.** A fixture-driven mock for UI engineers who don't need the full Airflow stack — keeps onboarding light.

### Phase 1 timeline reality

The "3–5 weeks" figure is the optimistic end of plausible, not the middle of the distribution.

| Scenario | Timeline | Conditions |
| -------- | -------- | ---------- |
| **Stretch (3–5 weeks)** | Optimistic | Requires **all** of: deep `/onering` context already on the team, same-day ONERING-repo PR reviews, green cost/latency spike (no thin step factory needed), prod-readiness staffed in parallel by SRE without competing for the integration team's time, no major engine refactor lands in window. |
| **Realistic (6–8 weeks)** | Plan against this | Standard 60–70% engineer utilization, normal review cadence, at least one of the stretch conditions failing. |
| **Pessimistic (9+ weeks)** | Watch out for | Thin step factory becomes necessary, ONERING-repo cadence is slow, or prod-readiness surfaces a blocker requiring cross-team coordination (network policy, Key Vault wiring). |

**Plan against 6–8 weeks; track 3–5 as a stretch.** If sales urgency is fixed at a tighter window, that is a forcing constraint to be paired with explicit fallback gates — not evidence that the work is smaller than estimated.

### Phase 1 fallback gates

Two checkpoints, not one. Each gate is a clear continue/fall-back decision.

**Week 1 gate** — catches "we don't know how to start." Required by end of week 1:
1. **DAG running locally end-to-end** with sample data.
2. **Cost & latency spike done.** Real numbers on a representative RFP. Decides between full extraction graph and thin step factory.
3. **End-to-end completion handling.** Trigger the DAG, poll, materialize items.
4. **Prod-readiness checklist drafted with named owners.** Not done — drafted. SLO target, on-call rotation, alerting, runbook, capacity, secrets, image registry, ingress, network policy, observability dashboard.

**Week 2 gate** — catches "we started but the ground is shifting." Required by end of week 2:
1. **Cost & latency decision committed.** Full graph or thin step factory chosen and scoped.
2. **ONERING-repo PR open and progressing.** Reviewers identified, no surprise blockers.
3. **Integration code merged behind feature flag** in our API. Reviewable, not yet production-clean.
4. **Prod-readiness progressing.** SLO and on-call decided. Security review of secrets and network policy underway.
5. **No engine-side breaking change** in the requirements pipeline since the pinned tag.

**If either gate fails:** launch Compliance on the current architecture and treat the ONERING migration as Phase 2 work. Pre-production status keeps the fallback cheap. The week-2 gate exists because slipping a 6–8-week project at week 4 is much more expensive than slipping at week 2.

---

## Phase 2 — Compliance Expansion

Once Phase 1 is live and stable:

- **Five additional extraction views.** Each is independently shippable, mostly UI work. ~1 engineer-week each.
- **Compliance matrix XLSX export.** ONERING already produces a styled six-tab workbook. ~1–2 weeks to surface.
- **Response analysis DAG.** Net-new ONERING capability. The biggest chunk of Phase 2 — 8–12 weeks for design, prompt engineering, evidence retrieval, and production hardening.

## Phase 3 — Answer Engine v2 Migration (months out)

This is where the **Python wrapper API** becomes worth building. KM retrieval needs to be fast and inline; AE v2 streams responses; aggregates are interactive. Airflow doesn't fit this workload.

Major workstreams:

- Build the Python wrapper for fast inline operations.
- Replace AE v2's KM workflow with engine-backed retrieval.
- Replace ad-hoc aggregates and summaries with the engine's section writer (draft / critique / revise).
- Add the GOLD library as an opt-in past-proposal answer source. Requires resolving partitioning model first — a product decision, not just plumbing.
- Defer deep-research consolidation; both paths are functionally similar today.

**Behavioral parity is harder than feature parity.** AE v2 just shipped — disrupting it again in a few months risks user fatigue. Phase 3 timing should account for this.

## Phase 4 — Acquisition Center Sub-Feature Migration (further out)

| Sub-feature              | Migration                                                       |
| ------------------------ | --------------------------------------------------------------- |
| Market Research Assistant| Custom Airflow DAG: discovery → deep research → vendor research |
| RFI Assistant            | Section writer via Phase 3 wrapper                              |
| Requirements Discovery   | Direct call to ONERING requirements extraction                  |
| Document Library         | Phase 3 ingestion endpoint                                      |
| Template Generator       | ONERING structure pipeline reverse-engineers templates          |
| Toolkits                 | No engine work; storage feature stays as-is                     |
| Vector DB calls          | Phase 3 KM retrieval endpoint                                   |

The current multi-step state model shrinks to a thin pointer to ONERING run IDs — the engine's orchestrator does the heavy lifting.

---

## Timeline & Effort Estimate

Assumes 2–3 engineers split across the three repos, with at least one engineer fluent in our existing Airflow + ONERING setup.

| Phase     | Calendar time     | Engineer-weeks |
| --------- | ----------------- | -------------- |
| Phase 1   | 6–8 weeks (3–5 stretch) | 8–12 integration + 3–5 prod-readiness in parallel |
| Phase 2   | 2–3 months        | 14–19          |
| Phase 3   | 3–5 months        | 18–30          |
| Phase 4   | 3–4 months        | 18–26          |

**Sequential execution:** 8–14 calendar months for the full four-phase plan with 2–3 engineers.
**With overlap:** 6–10 calendar months.

**Note on Phase 1 engineer-weeks.** Integration work is 8–12 ew. Prod-readiness (SLO, on-call, alerting, Helm prod cutover, security review, observability dashboard) is a separate 3–5 ew pool that runs in parallel — not folded into the integration estimate. It needs distinct staffing (ideally SRE/DevOps), or it competes with the integration team and stretches calendar time.

### If forced to commit to point estimates

- **Phase 1: 7 weeks** as the planning number, with hard fallback gates at week 1 and week 2. 4 weeks is the stretch target only if all conditions in "Phase 1 timeline reality" hold.
- **Phase 1 + Phase 2: 4 months** for 2–3 engineers (revised up from 3.5 to reflect realistic Phase 1).
- **Full four-phase plan: 9–10 months** for 2–3 engineers, with overlap.

A 3-month / 2–3 engineer budget is tight for Phases 1–2 once Phase 1 is sized realistically. It works only if Phase 1 lands in the stretch range; at 6–8 weeks it pushes into 4 months. It is **not** enough for the full four-phase plan including AE v2 and Acquisition Center under any sizing.

### What drives variance

- Engineer ramp on the existing namespace and Airflow patterns. Faster if someone already knows them.
- GOLD / KM partitioning complexity (Phase 3 only). If per-proposal access control is needed, expand 2–4 weeks.
- First production deployment of the ONERING stack — expect 2–3 weeks of post-launch stabilization, since this is both a new DAG and the first prod cutover of the engine.
- Coordination cadence with the team that owns the ONERING repo.
- Cross-team coordination (sales scoping, launch-date negotiation).

---

## Tradeoffs: Should This Happen Now?

The plan above is what _could_ be done. Whether it should be done _at this point in time_ is a separate question. The current context is unusually favorable, and there are real costs.

### Pros

1. **Pre-production Compliance status is the cheapest possible moment to commit to ONERING.** No user data, no edits to migrate, no launch promises to break, no behavioral parity bar. Launching on the current architecture and refactoring later is double-work.

2. **Sales urgency is the forcing function.** This work has a deadline and a why.

3. **The existing infrastructure is already mature in lower environments.** Phase 1 is mostly extending patterns we've already built and exercised — much lower risk than greenfield. The Proposal Launch and Discovery DAGs running in staging are the proof points.

4. **Phase 1 ships features.** Sales can sell on engine-backed capabilities (line-numbered evidence, audit trail, future-ready response analysis) rather than retrofitting that story later.

5. **Audit trail and debuggability are real wins.** Per-call artifact persistence plus Airflow's per-task UI is dramatically more debuggable than what the existing modules have. This matters more once Compliance ships to actual customers.

6. **The compounding duplication tax stops growing.** Establishing the engine pattern with Compliance creates the pull for AE v2 and Acquisition Center to follow.

7. **Strategic narrative.** "ONERING as engine" reframes the product from "three modules that happen to use AI" to "an AI engine for proposal/acquisition/compliance workflows with surfaces tailored to each."

### Cons

1. **Timeline is tighter than 3–5 weeks reads.** The realistic range is 6–8 weeks once first-prod cutover is in scope; 3–5 requires multiple favorable conditions to hold simultaneously. The risk isn't "we don't know how" — it's that the team commits to the optimistic number, hits any single friction point, and slips past the launch window without an early-enough fallback. The two-gate structure (week 1, week 2) exists to make slips cheap.

2. **First production deployment of the ONERING stack.** Compliance is the cutover. Even though the integration runs in dev and staging today, prod surfaces its own issues (capacity, networking, secrets rotation, on-call). Plan for 2–3 weeks of post-launch stabilization, not just 1–2.

3. **Cross-repo coordination overhead.** Phase 1 spans the ONERING repo and our API. Two PRs need to merge in coordination; production cutover requires both deployed and validated together.

4. **Streaming and state-model decisions still need design for Phase 3.** Easy to make pragmatic Phase 1 choices that hurt Phase 3.

5. **Engine-side engineering capacity.** "ONERING is a high priority" should include the engine itself, not just integration work. Phase 2's response analysis pipeline and Phase 3's streaming hooks need engine-side capacity.

6. **ONERING is still evolving fast.** Engine code is changing on a weekly cadence. Building on a young codebase means every refactor cascades. We mitigate via pinning + schema contracts, but expect a steady tax of "engine version bumps with smoke validation."

7. **Modules lose iteration independence over time.** Once multiple modules share an engine, prompt and pipeline changes need cross-module regression testing.

8. **AE v2 disruption risk** — it just shipped, and Phase 3 will disrupt it again. User fatigue is real.

### Honest summary

The plan is technically sound and the timing is unusually favorable. Pre-production Compliance + sales urgency + AE v2 / Acquisition Center deferral + ONERING priority + integration infrastructure already mature in lower environments is roughly the best window this team will get for an engine consolidation. The honest caveat: Compliance Phase 1 is also the first production deployment of the ONERING stack, so we are doing two firsts at once — first Compliance launch and first ONERING prod cutover.

---

## Open Questions for Stakeholders

These need explicit answers before committing.

1. **Is the few-weeks launch date hard or soft?** "Sales wants to sell" is real urgency but may not be a fixed deadline. The honest planning number is 6–8 weeks; getting sales to that window up front is materially safer than committing to 3–5 and slipping. **This is the single most leveraged conversation to have before Phase 1 starts.**

2. **What does sales actually need to demo?** If "AI extracts requirements, your team reviews, response analysis is coming next quarter" is enough, the thin scope works. If sales needs response analysis at launch, scope and timeline both shift.

3. **Does the team that owns the ONERING repo have capacity** to review and merge the new Compliance DAG within the launch window? **This is the single biggest external dependency.**

4. **Production Airflow readiness.** ONERING's Airflow stack has not yet been deployed to production — Compliance Phase 1 will be the first prod cutover. We need an explicit prod-readiness checklist (SLO target, on-call rotation, alerting, runbook, capacity headroom, secrets and Key Vault wiring) signed off before launch. This is more work than "extend existing prod infra" implies.

5. **Azure Government feasibility.** If any current customer or near-term sales prospect is on a `.us` endpoint, we need a feasibility spike in Phase 1 week 1. Otherwise we gate the Compliance feature flag off for Gov orgs and address in Phase 2.

6. **GOLD / KM partitioning model** (Phase 3 prerequisite). Per-org folders, shared corpus with tags, or hybrid? This is product work, not plumbing — needs a decision before Phase 3 starts.

---

## Recommendation

**Proceed with Phase 1 as scoped, but plan against 6–8 weeks (not 3–5), with hard fallback gates at weeks 1 and 2 and an explicit prod-readiness checklist as a launch gate.** The integration path is well-exercised in lower environments, but production introduces issues that staging won't surface, and Compliance is the first workload making that jump. Negotiating sales to the realistic window up front is materially safer than committing to the optimistic one and slipping.

The Compliance launch is a feature delivery and a strategic bet at the same time. Pre-production Compliance status makes the bet cheap; sales urgency makes it concrete; the integration work already done in lower environments makes it achievable. The cost we accept is doing two firsts at once — first Compliance launch and first ONERING prod cutover — and that cost is what makes 6–8 weeks the honest plan.
