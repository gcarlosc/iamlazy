# iamlazy Review — read the run log

Show the human the last runs of the harness in a readable form.

1. Read the last 20 entries:

   ```
   tail -n 20 ~/.iamlazy/runs.jsonl
   ```

   If the file does not exist, say so plainly ("no runs recorded yet") and stop. Do not treat an
   empty read as an error.

2. **You parse the JSON, not bash.** Each line is one JSON object.

   **The file holds more than one schema generation, and that is expected.** Lines written before
   Layer 0 landed carry self-reported fields (`reversibility`, `critic_mode`, `gate_verdict`,
   `outcome: success`); lines with `"schema_version": 2` are derived by hooks and carry
   `task_summary`, `duration_seconds`, `files_changed`, `lines_changed`, `tokens_weighted`,
   `project_md` and `close_detected_via`. **Report what each line actually has. Never carry a
   field across generations, and never infer a missing one** — a run that predates a field did not
   score badly on it, it simply has no value, and those are different facts.

   Present a compact, readable summary — a small table or tight list — with, per run: when it ran,
   what it was, how long it took, how much changed, and the cost when present.

3. After the list, offer one or two honest observations if a pattern stands out. Two worth
   watching now that cost is derived rather than estimated:
   - **cost per changed line** — healthy runs sit around 3,000–5,500 weighted tokens per line. A
     run far above that spent its budget on attempts, not progress.
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
