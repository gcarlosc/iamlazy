# Archived decisions — iamlazy

Founding decisions from 2026-07. Settled: they are not re-litigated, and the code shows the
detail. Moved out of `PROJECT.md` on 2026-08-22 to keep that file under its ~150-line pruning
threshold. Nothing here was reversed — a decision that gets superseded stays in `PROJECT.md`,
recorded inside the entry that replaced it.

- **Artifacts, not postures** (07-04). An abandoned posture is invisible; a missing or malformed
  artifact is visible drift. Prose discipline decays with session length, a required shape does not.
- **Structure over discipline** (07-04). The gate rides native plan mode, the Critic is read-only by
  frontmatter, A2/A3 are files on disk. Prose is reduced to 5 inviolable rules plus guidance.
- **Post-diff structural floor** (07-04). Sensitive globs + >400 changed lines escalate the Critic
  deterministically. Pre-work triage stays correctable judgment; post-diff escalation is structure.
- **Pre-verified load-bearing claims** (07-04). The model runs each claim's command while composing
  A3 and pastes real output. A subagent Critic re-runs them — captured output is never trusted.
- **A2/A3 persisted verbatim post-gate** (07-04). Plan mode blocks Write, so Ground/Plan are composed
  as text, approved, then written byte-for-byte. The Critic reads them from disk, never from memory.
- **The Critic is the only sub-agent, and conditional** (07-02/04). Fresh context where in-thread
  discipline is not enough: low reversibility, or when the floor fires.
- **Marker-based idempotency + anti-clobber** (07-02). Safe re-runs; never overwrite a file that is
  not ours; uninstall reclaims only marked files.
- **Principles as design constraints + evidence backlog** (07-12). Principles are normative
  preferences, distinct from Invariants (facts); an undeclared A3 deviation is an automatic Critic
  finding. Ideas evaluated but not adopted live in `DELTAS.md` behind observable triggers. Distilled
  from spec-kit's constitution.
- **Rendering discipline** (07-20). A3 steps carry a time estimate; A5 closes with the single most
  concrete next action. From i-have-adhd; the rest of its rules were gated or rejected.
