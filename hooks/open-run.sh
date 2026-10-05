#!/usr/bin/env bash
# iamlazy Layer 0 — Guarantee 7: the run is identified by real data, not by a
# heuristic. Also lays the ground for Guarantee 2 (the log exists), and is the
# one place the model is told what the harness currently knows about its run.
#
# Fires on UserPromptSubmit. SessionStart cannot do this job: it fires before
# the human has typed anything, so it cannot know this session will invoke
# /iamlazy. UserPromptSubmit sees the raw prompt (slash-command expansion is a
# separate, later event per the hooks doc), so matching "/iamlazy" here is the
# earliest point where "a run is starting" is a fact, not a guess.
set -u
# shellcheck source=hooks/lib.sh
. "$(dirname "$0")/lib.sh"
hk_crash_guard

payload=$(cat)

ev=$(hk_field "$payload" "hook_event_name")
[ "$ev" = "UserPromptSubmit" ] || hk_allow

sid=$(hk_field "$payload" "session_id")
tpath=$(hk_field "$payload" "transcript_path")
cwd=$(hk_field "$payload" "cwd")

# Prefix check only -- never fully extract the free-text prompt field, it may
# contain escaped quotes lib.sh's naive parser cannot handle safely.
is_iamlazy=0
case "$payload" in
  *'"prompt":"/iamlazy '*|*'"prompt":"/iamlazy"'*) is_iamlazy=1 ;;
esac

# A client that INLINES the skill instead of sending /iamlazy. MonoCode 0.7.0,
# measured 2026-10-05: the prompt is its own preamble ("The user invoked
# skill(s) with /name...", "## /iamlazy"), then the installed SKILL.md pasted
# whole, frontmatter included, with $ARGUMENTS left unreplaced. No /iamlazy
# prefix, so no run opened, and the model followed the whole protocol with
# every guarantee off and nothing said. Recognised by OUR OWN frontmatter, not
# the client's wording: the skill's name line (exactly `iamlazy`, so the review
# skill does not match) together with the marker only this installer writes.
# In the payload the prompt is a JSON string, so a newline is the two
# characters backslash-n, matched literally here.
if [ "$is_iamlazy" = 0 ]; then
  case "$payload" in
    *'name: iamlazy\n'*'# iamlazy-managed'*) is_iamlazy=1 ;;
  esac
fi

# Runs whose session died without SessionEnd, and the pre-2026-09-05 global
# run file, are reclaimed here. Cheap: a listing of a small directory.
mkdir -p "$HK_ACTIVE_DIR"
hk_sweep_stale

# ---------------------------------------------------------- active run status
# During a run, one line of context per turn. This is the channel that was
# missing: the scope gate and the group ledger could block a close, and the
# model was never told -- flush-run.sh returned exit 0 with no output, so the
# run simply would not end and nothing said why. UserPromptSubmit stdout is
# added to the model's context (hooks reference), so this is where the state
# stops being invisible. One line, and only while a run is open.
if [ -n "$sid" ]; then
  run_file=$(hk_run_file "$sid")
  if [ -f "$run_file" ] && [ "$is_iamlazy" = "0" ]; then
    hk_close_idle_gap "$run_file"
    hk_adopt_contract "$run_file" "$cwd"
    root=$(hk_project_root "$run_file" "$cwd")
    base=$(hk_field_file "$run_file" "base_ref")
    ubase=$(hk_untracked_file "$run_file")
    contract="${root}/.iamlazy/contract.md"
    # Three states, said plainly, and only about a contract THIS run owns.
    # A contract counts once its base is pinned; one left by a previous run
    # was described here as "complete and in scope" while the real run had
    # written none (sperant, 2026-10-03). And open groups mid-run are the plan
    # working, not an alarm: only a file outside ## Scope earns "NO puede
    # cerrar", because only that needs a decision from the model.
    if [ -z "$base" ] || [ ! -f "$contract" ]; then
      printf 'iamlazy: corrida activa en %s. Esta corrida todavia no escribio su contrato: cuando se apruebe el plan, guardalo tal cual en .iamlazy/contract.md.\n' "$root"
    else
      viol=$(hk_scope_violations "$root" "$contract" "$base" "$ubase" | tr '\n' ' ')
      open_groups=$(grep -c -- '- \[ \]' "$contract" 2>/dev/null | tr -d ' ')
      if [ -n "$viol" ]; then
        printf 'iamlazy: corrida activa en %s (base %s). NO puede cerrar: archivos fuera del ## Scope declarado: %s Declara el desvio en ## Scope del contrato o revierte el archivo.\n' \
          "$root" "$base" "$viol"
      elif [ "${open_groups:-0}" -gt 0 ] 2>/dev/null; then
        printf 'iamlazy: corrida activa en %s (base %s). Grupos sin marcar: %s. Marca cada uno con - [x] cuando su comando de aceptacion pase.\n' \
          "$root" "$base" "$open_groups"
      else
        printf 'iamlazy: corrida activa en %s (base %s). El contrato esta completo y todo lo cambiado cae dentro del ## Scope declarado.\n' \
          "$root" "$base"
      fi
    fi
    hk_allow
  fi
fi

[ "$is_iamlazy" = "1" ] || hk_allow

# Guarantee 6: never under a permission bypass.
# PROJECT.md declares "iamlazy must not be run under
# --dangerously-skip-permissions" as an invariant, but nothing ever enforced
# it -- it was a written wish. The gate's whole strength on Claude Code comes
# from native plan mode, and a bypass removes it, so a run that starts this
# way is a run without its one structural guarantee. Refusing to OPEN is the
# honest response: better no run than a run that silently is not the harness.
# UserPromptSubmit cannot emit permissionDecision (PreToolUse only), so this
# blocks with exit 2, which is that event's documented blocking channel.
if printf '%s' "$payload" | grep -q '"permission_mode":"bypassPermissions"'; then
  echo "iamlazy: no se arranca con los permisos en bypass. La puerta de aprobacion se apoya en el plan mode nativo; saltarse los permisos elimina la unica garantia estructural que tiene el harness. Reinicia sin --dangerously-skip-permissions." >&2
  exit 2
fi

# Only the session id is required. transcript_path is EMPTY on hosts that have
# no Claude-style transcript (OpenCode keeps sessions in SQLite and hands cost
# over in a sidecar instead -- see hk_cost_file). Everything that reads the
# transcript degrades on its own: cost_priced=0, start_interventions=0. Found by
# the first test that opened a run as an OpenCode adapter would: this line used
# to refuse it as malformed, and no run could ever have opened there.
[ -n "$sid" ] || hk_allow  # malformed payload: do nothing, never guess

RUN_FILE=$(hk_run_file "$sid")

# A second /iamlazy in the same session closes the book on the first one. It
# never reached its own close, so it is abandoned, not incomplete -- and it
# gets a real log line saying which stage it died at.
[ -f "$RUN_FILE" ] && hk_flush_abandoned "$RUN_FILE"

now_epoch=$(date +%s)
now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Another session with a run open in this same directory. Both would share
# .iamlazy/contract.md and journal.md, so the second overwrites the first's
# contract and the close gate reads whichever is on disk. Said, not blocked:
# the human may know the other session is dead, and the 24h sweep reclaims it.
other_sid=""
for of in "$HK_ACTIVE_DIR"/*.json; do
  [ -f "$of" ] || continue
  [ "$of" = "$RUN_FILE" ] && continue
  if [ "$(hk_project_root "$of" "$(hk_field_file "$of" "cwd")")" = "$cwd" ]; then
    other_sid=$(hk_field_file "$of" "session_id")
    break
  fi
done

# The previous run's contract and journal are archived, not left in place.
# Left in place, the journal grew across runs and was handed whole to every
# Critic (316 lines in sperant since August), and the stale contract was read
# as this run's by the per-turn status line and by task_summary. Never while
# another run is live here: those files are its own, mid-run.
if [ -z "$other_sid" ] && [ -n "$cwd" ] && \
   { [ -f "$cwd/.iamlazy/contract.md" ] || [ -f "$cwd/.iamlazy/journal.md" ]; }; then
  arch="$cwd/.iamlazy/history/$(date -u +%Y%m%dT%H%M%SZ)"
  [ -e "$arch" ] && arch="${arch}-$$"
  if mkdir -p "$arch" 2>/dev/null; then
    for af in contract.md journal.md; do
      [ -f "$cwd/.iamlazy/$af" ] && mv "$cwd/.iamlazy/$af" "$arch/$af"
    done
  fi
fi

# The transcript accumulates the WHOLE session, not this run. Recording the
# baseline at open lets the close measure the delta -- otherwise a second
# /iamlazy in the same session would inherit the first one's cost and the drift
# check would fire on the wrong run. Verified on the 2026-09-05 run: the
# /iamlazy-review typed afterwards added $0.90 that correctly stayed out.
#
# cost_priced records whether the baseline could be priced at all. If a model in
# the transcript is missing from prices.conf there is no baseline, and a delta
# taken against a missing baseline would silently bill this run for the whole
# session. The close reports null instead.
#
# An ABSENT transcript is not an unknown price -- it means nothing has been
# spent yet, so the baseline is genuinely zero. Claude Code creates the file
# lazily and UserPromptSubmit can fire first: verified 2026-09-06, the file was
# born in the same second the run opened and the hook got there first. Treating
# the two cases alike made every run started as the first prompt of a fresh
# session report `cost_usd: null` with nothing in `cost_unpriced` to explain it
# -- a null with no reason, which is the one thing this field exists to prevent.
# An EXISTING transcript with no usage lines already priced as 0; only a missing
# file failed.
if [ -n "$tpath" ] && [ ! -f "$tpath" ]; then
  start_cost=0; cost_priced=1
  start_out=0; start_cw=0; start_cr=0
  start_models=""
else
  # One pass instead of three (hk_cost_micro + hk_token_components +
  # hk_models_run all walked the same "usage":{ lines) -- see
  # hk_transcript_scan in lib.sh.
  scan_out=$(hk_transcript_scan "$tpath")
  scan_cost=$(printf '%s\n' "$scan_out" | sed -n '1p')
  scan_tok=$(printf '%s\n' "$scan_out" | sed -n '2p')

  # Same baseline, for the same reason, applied to WHICH models answered: the
  # close reports what this run added, not every model the session ever used.
  # Semantic rather than positional (a count per model, not a line offset) so a
  # compaction that rewrites the transcript cannot silently shift the window.
  start_models=$(printf '%s\n' "$scan_out" | sed -n '3p')

  if [ "$scan_cost" != "NULL" ] && [ -n "$scan_cost" ]; then
    cost_priced=1; start_cost=$scan_cost
  else
    cost_priced=0; start_cost=0
  fi

  # shellcheck disable=SC2086  # word splitting is the point: "N N N" into $1 $2 $3
  set -- $scan_tok
  start_out="${1:-0}"; start_cw="${2:-0}"; start_cr="${3:-0}"
fi

# Same reasoning for interruptions: the marker accumulates over the session, so
# the close subtracts this baseline instead of reporting the session's total.
# The field audit of 2026-08-21 found human_interventions undercounting; it was
# then derived from the transcript marker but never made a delta.
start_interventions=0
if [ -n "$tpath" ] && [ -f "$tpath" ]; then
  start_interventions=$(grep -c 'Request interrupted by user' "$tpath" 2>/dev/null | tr -d ' ')
fi

# Which host is running this. Claude Code's real payload carries no such field,
# so its absence means Claude Code; a host adapter (OpenCode's plugin) adds
# "host" to the payload it synthesises. Recorded so runs.jsonl can tell the two
# apart once both write to it -- the review must never average across hosts.
host=$(hk_field "$payload" "host")
[ -n "$host" ] || host="claude-code"

# The repository as it stood when the run opened: HEAD, and the files already
# untracked. The base used to be taken only when the contract was written
# through Edit/Write, so a contract written any other way left the run with no
# base at all (see hk_adopt_contract). Taken here, before any work, it is also
# the honest baseline: nothing the run creates can be mistaken for something
# that was already there. hk_set_base reuses it when the contract lands in this
# same directory.
open_ref=$( (cd "$cwd" 2>/dev/null && git rev-parse HEAD) 2>/dev/null )
[ -n "$open_ref" ] || open_ref="$HK_EMPTY_TREE"

printf '{"schema_version":5,"host":"%s","session_id":"%s","transcript_path":"%s","cwd":"%s","start_epoch":%s,"start_cost":%s,"cost_priced":%s,"start_out":%s,"start_cw":%s,"start_cr":%s,"start_interventions":%s,"start_models":"%s","open_ref":"%s","opened_at":"%s","outcome":"incomplete"}' \
  "$(hk_json_esc "$host")" "$(hk_json_esc "$sid")" "$(hk_json_esc "$tpath")" "$(hk_json_esc "$cwd")" \
  "$now_epoch" "$start_cost" "$cost_priced" "$start_out" "$start_cw" "$start_cr" \
  "${start_interventions:-0}" "$(hk_json_esc "$start_models")" "$open_ref" "$now_iso" > "$RUN_FILE"

(cd "$cwd" 2>/dev/null && git ls-files --others --exclude-standard 2>/dev/null) \
  > "$(hk_untracked_file "$RUN_FILE")" 2>/dev/null || : > "$(hk_untracked_file "$RUN_FILE")"
: > "$(hk_opened_file "$RUN_FILE")"

if [ -n "$other_sid" ]; then
  # systemMessage reaches the human; additionalContext reaches the model. On
  # OpenCode the adapters ignore stdout at the open, so this is Claude Code's.
  two_msg="iamlazy: otra sesion ($(hk_json_esc "$other_sid")) ya tiene una corrida abierta en $(hk_json_esc "$cwd"). Las dos comparten .iamlazy/contract.md y .iamlazy/journal.md, asi que la segunda pisa el contrato de la primera. Termina o cierra una antes de seguir con la otra."
  printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}\n' "$two_msg" "$two_msg"
fi

hk_allow
