# iamlazy Review — read the run log

Show the human the last runs of the harness in a readable form.

1. Read the last 20 entries:

   ```
   tail -n 20 ~/.iamlazy/runs.jsonl
   ```

   If the file does not exist, say so plainly ("no runs recorded yet") and stop. Do not treat an
   empty read as an error.

2. **You parse the JSON, not bash.** Each line is one JSON object. Read them yourself and present
   a compact, human-readable summary — a small table or a tight list — with, per run:
   - when it ran (`timestamp`, relative if helpful)
   - what it was (`task_summary`)
   - reversibility (mark it if the human corrected it)
   - `critic_mode`, `gate_verdict`, `outcome`, and `project_md`

3. After the list, offer one or two honest observations if a pattern stands out (e.g. repeated
   `escalated` outcomes, reversibility frequently corrected, `project_md` never updated). Keep it
   to conclusions — no internal mechanics, no raw JSON dumped at the human.

4. **Sweep the evidence-gated backlog.** Read `~/.iamlazy/DELTAS.md`; if it is not there, skip
   this step silently. Every candidate carries a trigger written in terms observable in these
   runs. Check each trigger against the entries you just read and report only the ones that have
   **fired**, naming the runs that fired them. A fired trigger prompts evaluation, never
   adoption — say what fired, and stop there. If nothing fired, say so in one line.

   Two cautions, both about not manufacturing evidence:

   - **The wording is the contract.** A trigger asking for "2+ runs where X" is not fired by one.
     Do not round up, and do not treat a near-miss as a hit.
   - **Some triggers reference evidence the log does not carry** — a finding's severity, whether
     a file was created, whether a later step read it. For those, say plainly what the log can
     and cannot confirm instead of inferring. An unconfirmable trigger is not a fired trigger.
