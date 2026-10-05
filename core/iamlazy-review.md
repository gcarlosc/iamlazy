# iamlazy Review — read the run log

Show the human the last runs of the harness in a readable form.

1. Read the last 20 entries:

   ```
   tail -n 20 ~/.iamlazy/runs.jsonl
   ```

   If the file does not exist, say so plainly ("no runs recorded yet") and stop. Do not treat an
   empty read as an error.

2. **You parse the JSON, not bash.** Each line is one JSON object.

   **The file holds several schema generations, and that is expected.** Pre-Layer-0 lines are
   self-reported (`reversibility`, `critic_mode`, `gate_verdict`, `outcome: success`); `2` is
   derived by hooks; `3` adds `base_ref`, `stage_reached`, `critic_findings`, the `abandoned`
   outcome and a per-run `human_interventions`; `4` replaces `tokens_weighted` with `cost_usd`
   plus the raw `tokens_output` / `tokens_cache_write` / `tokens_cache_read`, and names the `host`;
   `5` adds `drift_thresholds` — the breaker's settings as `microUSD-per-line/min-lines/min-cost`,
   logged because a breaker that did not fire is only interpretable against what it measured; `6`
   adds `drift_fired`, whether it actually stopped that run. **Report how many runs it fired on,
   and against which thresholds.** Its numbers rest on four runs from two projects, so that count
   is the evidence for keeping or moving them — and a run it fired on that turned out fine means
   the threshold is wrong, not the run. `7` adds `models_seen` — which models answered the run and
   how many messages each one wrote, commonest first, the Critic's own included. `8` adds
   `hooks_version` — the git SHA (or content fingerprint, on a `curl|bash` install with no `.git`)
   of the enforcement code that wrote this line, stamped once at install time. Useful for exactly
   one question: was this run before or after a given fix landed. Empty on any install that
   predates this field — not a bug, that install simply never stamped one. `9` adds `drift_reason` —
   which ceiling stopped the run (`ratio`, `duration`, `cost`), empty when none did. `10` adds
   `idle_seconds` — time the run sat waiting for the human between a finished turn and the next
   prompt. The duration ceiling measures `duration_seconds` minus it, so a run longer than an hour
   that did not fire is explained by its own line.
   **Report what each line actually has. Never carry a field across generations, and never infer a
   missing one** — a run that predates a field did not score badly on it, it simply has no value,
   and those are different facts. An `abandoned` line carries only the subset a run that never
   closed can honestly fill; its missing fields are not zeros.

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
   - **`human_interventions: null` is not zero either.** The count comes from the session
     transcript, which only Claude Code has; on any other host it is unknowable, not absent
     because nothing happened. Never read a null as a calm run.
   - **`close_detected_via`** — `contract` means the run closed against its own ledger;
     `banner` means it closed on the weaker text signal, which is the path with no contract to
     check. A run expected to have a contract that closed via `banner` is worth a question.
   - **`models_seen` answers "what actually ran", which is not what the config says.** It reads
     `model:messages`, commonest first. A model split that was configured and did not happen is
     visible here and nowhere else — the case that produced this field was a planner pinned to one
     model and answering on another. Report it when the mix is surprising for the host, and say
     nothing when it is not; an empty value means the host offers no way to know, never that one
     model ran.

   Keep it to conclusions — no internal mechanics, no raw JSON dumped at the human.

4. **Sweep the evidence-gated backlog.** Read `~/.iamlazy/DELTAS.md`; if it is not there, skip
   this step silently. Every candidate carries a trigger written in terms observable in these
   runs. Check each trigger against the entries you just read and report only the ones that have
   **fired**, naming the runs that fired them. A fired trigger prompts evaluation, never
   adoption — say what fired, and stop there. If nothing fired, say so in one line.

   **Every trigger declares how it is checked, and that governs what you do with it:**

   - `[log]` — derivable from these runs. Check it. Report fired or not fired.
   - `[human]` — needs a person to have noticed. **Do not try to derive it, and do not explain
     that you could not.** List it in one line and move on. Explaining the unconfirmable once per
     candidate per run is how this step grew to outweigh the report it belongs to.
   - A trigger marked **blocked** names the field it is waiting on. Say it is still blocked; that
     is a fact about the backlog, not a claim about the runs.

   And one caution that outranks all three: **the wording is the contract.** A trigger asking for
   "2+ runs where X" is not fired by one. Do not round up, and do not treat a near-miss as a hit.
