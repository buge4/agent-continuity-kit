# VERITON BUILD METHODOLOGY — the build-plan-first law (canonical)
**Standing rule, all agents, all projects, no exceptions. 2026-07-16 (Bjorn).**

We never wing it. Every project or feature goes through these 5 phases IN ORDER, each using
the FULL agent loop (4-model consensus: Haiku 4.5 / Sonnet 5 / Opus 4.8 / Fable 5):

## 1. DEEP RESEARCH (agent loop)
Read the brain FIRST (brain_meta + your agent-memory). Survey prior art, competitors,
patents, standards, and any existing internal work (e.g. Stig's Veriton-Technologies repos,
Morten's ADRs). Write findings back to the brain with `source_uri` + `source_kind` +
`confidence`. Output: a research brief.

## 2. BUILD PLAN + BLUEPRINT (agent loop + CONSENSUS)
Produce, BEFORE any code:
- a **blueprint** (architecture, components, data flow, verification points),
- **Mermaid diagrams** (system + sequence + deploy),
- a **phased build-plan** (P0…Pn, each with a clear done-criterion),
- run **4-model consensus** to score + critique the plan; revise until it passes.
No build starts until this plan is written and (for anything substantial) Bjorn-approved.

## 3. BUILD
Execute the approved plan only. **Verify-before-claim at every step** (a push isn't done
until `gh api` confirms it; a service isn't up until it answers). Heavy work on the **$0 box
rail**, never personal credits. Where relevant, verify with the **full Veriton stack**
(TVRF→ChaCha20, PCP pre-commit, DAE/CAD determinism, VeriBOX tape, VeriStamp cert, PVC,
multi-chain anchor, AICP per-inference).

## 4. FULL-SYSTEM AUDIT (agent loop)
Adversarial audit of the whole system: correctness (red-team-code), crypto
(red-team-crypto), supply-chain, plus `continuity-audit.sh` to 0 FAIL. Findings verified by
independent skeptics before they count.

## 5. FINAL REPORT
Every project ends with a report explaining what was built + the whole system: the blueprint,
the Mermaid diagrams, how a third party verifies it, and the open decisions. This is the
deliverable Bjorn reads and that gets shared.

---
**Governance:** this file is canonical in `buge4/agent-continuity-kit`. Per-project agents
(floor, qr, collab, drone, saas, arctico, …) follow it verbatim; local deltas only, never a
re-copy. Consensus gate = [[consensus-gate-standing-rule]]. Verify-before-claim =
[[kit-push-mispush-lesson]].
