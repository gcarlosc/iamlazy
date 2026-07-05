# Ledger Review — read the run log

Show the human the last runs of the harness in a readable form.

1. Read the last 20 entries:

   ```
   tail -n 20 ~/.ledger/runs.jsonl
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
