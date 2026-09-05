# iamlazy Review — read the run log

Show the human the last runs of the harness in a readable form.

1. Read the last 20 entries:

   ```
   tail -n 20 ~/.iamlazy/runs.jsonl
   ```

   If the file does not exist, say so plainly ("no runs recorded yet") and stop. Do not treat an
   empty read as an error.

2. **You parse the JSON, not bash.** Each line is one JSON object.

   **The file holds four schema generations, and that is expected.** Pre-Layer-0 lines are
   self-reported (`reversibility`, `critic_mode`, `gate_verdict`, `outcome: success`); `2` is
   derived by hooks; `3` adds `base_ref`, `stage_reached`, `critic_findings`, the `abandoned`
   outcome and a per-run `human_interventions`; `4` replaces `tokens_weighted` with `cost_usd`
   plus the raw `tokens_output` / `tokens_cache_write` / `tokens_cache_read`. **Report what each
   line actually has. Never carry a field across generations, and never infer a missing one** — a
   run that predates a field did not score badly on it, it simply has no value, and those are
   different facts.

   **A line with no `base_ref` has UNRELIABLE `files_changed` and `lines_changed`.** Those runs
   measured with a bare `git diff`, which shows only unstaged work, so anything staged or
   committed during the run counted as zero. Two logged runs report `lines_changed: 0` over
   commits that added 1,774 and 69 real lines. Treat those two fields as **unmeasurable** on
   schema < 3, exactly as you would a field that does not exist — never compute cost per line
   from them, and never explain the zero. "It probably explored without writing code" is a story
   invented to fit a broken number, and it is the specific mistake this paragraph exists to stop.

   Present a compact, readable summary — a small table or tight list — with, per run: when it ran,
   what it was, how long it took, how much changed, and the cost when present.

3. After the list, offer one or two honest observations if a pattern stands out. Two worth
   watching now that cost is derived rather than estimated:
   - **cost per changed line, in dollars.** Four measured runs sit between $0.023 and $0.065,
     and the figure **falls as a run grows** — the fixed cost of reading, planning, contracting
     and reviewing does not scale with lines, so a small task is dear per line and that is
     normal, not a warning. Compare like with like before calling a run expensive.
   - **`cost_usd: null` is not zero.** It means a model in that run was missing from
     `prices.conf`; `cost_unpriced` names it. Say what is missing, never treat the run as free.
     Runs before schema 4 carry `tokens_weighted` instead — a synthetic unit that priced Sonnet
     and Opus tokens identically and excluded the Critic. **Do not compare it against `cost_usd`
     and do not convert one to the other**; report each generation in its own unit.
   - **`close_detected_via`** — `contract` means the run closed against its own ledger;
     `banner` means it closed on the weaker text signal, which is the path with no contract to
     check. A run expected to have a contract that closed via `banner` is worth a question.

   Keep it to conclusions — no internal mechanics, no raw JSON dumped at the human.

4. **Sweep the evidence-gated backlog.** Read `~/.iamlazy/DELTAS.md`; if it is not there, skip
   this step silently. Every candidate carries a trigger written in terms observable in these
   runs. Check each trigger against the entries you just read and report only the ones that have
   **fired**, naming the runs that fired them. A fired trigger prompts evaluation, never
   adoption — say what fired, and stop there. If nothing fired, say so in one line.

   Three cautions, all about not manufacturing evidence:

   - **The wording is the contract.** A trigger asking for "2+ runs where X" is not fired by one.
     Do not round up, and do not treat a near-miss as a hit.
   - **Some triggers reference evidence the log does not carry** — a finding's severity, whether
     a file was created, whether a later step read it. For those, say plainly what the log can
     and cannot confirm instead of inferring. An unconfirmable trigger is not a fired trigger.
   - **A trigger written against a field that no longer exists cannot fire.** Several candidates
     were written when `reversibility` and `critic_mode` were recorded. Say that the trigger is
     now unmeasurable rather than silently treating it as unfired — the first is a fact about the
     backlog, the second is a claim about the runs.
