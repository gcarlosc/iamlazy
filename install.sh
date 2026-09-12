#!/usr/bin/env bash
# iamlazy installer — bash 3.2 compatible. Zero external deps (coreutils only;
# curl is needed only for the curl|bash remote path). Idempotent via the
# `iamlazy-managed` marker embedded in every generated file's frontmatter.
set -eu

MARKER="iamlazy-managed"

CC_CMD_DIR="${HOME}/.claude/commands"
CC_AGENT_DIR="${HOME}/.claude/agents"
OC_CMD_DIR="${HOME}/.config/opencode/commands"
OC_AGENT_DIR="${HOME}/.config/opencode/agents"
OC_HOOK_DIR="${HOME}/.config/opencode/iamlazy-hooks"
OC_PLUGIN_DIR="${HOME}/.config/opencode/plugins"
LOG_DIR="${HOME}/.iamlazy"
CC_HOOK_DIR="${HOME}/.claude/iamlazy-hooks"

# Files that make up the payload (relative to the repo root).
PAYLOAD="core/iamlazy.md core/iamlazy-review.md critic/iamlazy-critic.md \
hooks/lib.sh hooks/guard-agent.sh hooks/open-run.sh hooks/track-edit.sh hooks/flush-run.sh \
hooks/end-run.sh hooks/subagent-done.sh hooks/guard-critic-bash.sh hooks/host-cost.sh \
hooks/merge-settings.sh adapters/opencode/iamlazy.ts \
templates/claude-code/command-iamlazy.frontmatter \
templates/claude-code/command-review.frontmatter \
templates/claude-code/agent-critic.frontmatter \
templates/claude-code/guarantees.md templates/claude-code/gate.md \
templates/opencode/primary-iamlazy.frontmatter \
templates/opencode/command-iamlazy.frontmatter \
templates/opencode/command-review.frontmatter \
templates/opencode/subagent-critic.frontmatter \
templates/opencode/guarantees.md templates/opencode/gate.md \
models.conf prices.conf DELTAS.md"

# --------------------------------------------------------------------- check
#
# What is INSTALLED is what runs, and it drifts from the repo silently: three
# times in one day a fix was committed, the suite went green, and the machine
# kept running the previous bytes -- once leaving a run unable to close at all.
# Nothing said so. This turns the project's own principle, "verify against the
# running build, not the documentation", into a command.
#
# It reports and exits non-zero; it never repairs. Repairing is what install.sh
# is for, and a checker that silently fixes things is a checker you stop reading.
CHECK_FAIL=0
c_ok()   { echo "  ok    $1"; }
c_bad()  { echo "  BAD   $1" >&2; CHECK_FAIL=1; }
c_skip() { echo "  --    $1"; }

# c_same <repo file> <installed file> <label>
c_same() {
  if [ ! -f "$2" ]; then c_bad "$3: not installed ($2)"
  elif cmp -s "$1" "$2"; then c_ok "$3"
  else c_bad "$3: installed copy differs from this repo"; fi
}

run_check() {
  echo "iamlazy check  (repo: $SRC)"

  echo "claude code"
  if [ -d "$CC_HOOK_DIR" ]; then
    for h in "$SRC"/hooks/*.sh; do
      c_same "$h" "$CC_HOOK_DIR/$(basename "$h")" "hook up to date: $(basename "$h")"
    done
    for h in open-run guard-agent guard-critic-bash track-edit flush-run end-run subagent-done; do
      if grep -q "iamlazy-hooks/$h.sh" "$HOME/.claude/settings.json" 2>/dev/null; then
        c_ok "registered: $h.sh"
      else c_bad "installed but NOT registered in settings.json: $h.sh"; fi
    done
    # A guarantee that can be switched off is worth saying out loud.
    if grep -q '"disableAllHooks"[[:space:]]*:[[:space:]]*true' "$HOME/.claude/settings.json" 2>/dev/null; then
      c_bad "disableAllHooks is true: Layer 0 is installed and inert"
    else c_ok "hooks are not disabled"; fi
    if [ -f "$CC_CMD_DIR/iamlazy.md" ]; then
      if grep -q '{{' "$CC_CMD_DIR/iamlazy.md"; then c_bad "installed prompt has an unfilled token"
      else c_ok "prompt composed, no unfilled token"; fi
    else c_bad "prompt not installed: $CC_CMD_DIR/iamlazy.md"; fi
  else
    c_skip "claude code: no hook directory, nothing installed"
  fi

  echo "opencode"
  if [ -d "$OC_HOOK_DIR" ]; then
    for h in "$SRC"/hooks/*.sh; do
      c_same "$h" "$OC_HOOK_DIR/$(basename "$h")" "hook up to date: $(basename "$h")"
    done
    c_same "$SRC/adapters/opencode/iamlazy.ts" "$OC_PLUGIN_DIR/iamlazy.ts" "adapter up to date"
    # The adapter is the registration on this host, and OpenCode refuses a module
    # whose exports are not all functions -- silently, into its own log.
    if [ -f "$OC_PLUGIN_DIR/iamlazy.ts" ] && grep -qE '^export (const|let|var) [A-Za-z_]+ *(:[^=]*)?= *["`0-9]' "$OC_PLUGIN_DIR/iamlazy.ts"; then
      c_bad "adapter exports a non-function: OpenCode will refuse the whole plugin"
    else c_ok "adapter exports look like functions"; fi
    # A load failure only matters if it happened to the bytes installed NOW.
    # The log keeps every past one forever, and reporting those would make this
    # check cry wolf about a bug that was already fixed -- a guarantee that
    # fires outside its domain is a defect, which is this project's own rule.
    # ISO-8601 UTC strings compare correctly as strings, so the whole thing is
    # one lexicographic comparison against the plugin's own mtime.
    oc_log="$HOME/.local/share/opencode/log/opencode.log"
    last_fail="$(grep 'failed to load plugin.*iamlazy' "$oc_log" 2>/dev/null | tail -1 \
                 | sed -n 's/^timestamp=\([^ ]*\).*/\1/p')"
    if [ -z "$last_fail" ]; then
      c_ok "opencode has never failed to load the plugin"
    else
      mtime="$(stat -f %m "$OC_PLUGIN_DIR/iamlazy.ts" 2>/dev/null || stat -c %Y "$OC_PLUGIN_DIR/iamlazy.ts" 2>/dev/null)"
      installed_at="$(date -u -r "$mtime" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$mtime" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
      if [ -n "$installed_at" ] && awk -v a="$last_fail" -v b="$installed_at" 'BEGIN{exit !(a>b)}'; then
        c_bad "opencode failed to load the plugin at $last_fail, AFTER these bytes were installed"
      else
        c_ok "no plugin load failure since this adapter was installed (last was $last_fail)"
      fi
    fi
  else
    c_skip "opencode: no hook directory, nothing installed"
  fi

  echo "state"
  if [ -f "$LOG_DIR/prices.conf" ]; then c_ok "price table present"
  else c_bad "no price table: every cost will be null ($LOG_DIR/prices.conf)"; fi
  if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
    c_ok "a JSON parser is available for the installer"
  else c_bad "no python: the installer cannot register hooks"; fi
  n_active=0
  for f in "$LOG_DIR"/active/*.json; do [ -f "$f" ] && n_active=$((n_active + 1)); done
  if [ "$n_active" -eq 0 ]; then c_ok "no run left open"
  else c_skip "$n_active run(s) currently open (fine mid-run; stale ones are swept at 24h)"; fi
  # The close-by-banner path has died three times, twice over encoding. Prove the
  # separator in the prompt still matches the pattern the hook greps for, in THIS
  # locale -- which is the one production runs in, and not CI's.
  if printf '── CIERRE · m · high ──' | grep -Eq '─[^"]{0,60}(CLOSE|CIERRE)|(CLOSE|CIERRE)[^"]{0,60}─'; then
    c_ok "close banner matches under this locale (${LC_ALL:-${LANG:-unset}})"
  else c_bad "close banner does NOT match under this locale: the close path is dead here"; fi

  echo
  if [ "$CHECK_FAIL" -eq 0 ]; then echo "all good."; else echo "PROBLEMS FOUND -- run install.sh to bring the machine back to this repo." >&2; fi
  return "$CHECK_FAIL"
}

usage() {
  cat <<'EOF'
iamlazy installer
  usage: install.sh [--tool=claude|opencode|both] [--model=<id>] [--no-hooks]
         install.sh --check
  --check compares what is INSTALLED against this repo and reports drift,
    without changing anything. Exits non-zero when something is off.
  Auto-detects installed tools when --tool is omitted.
  --model=<id> sets BOTH roles (main + critic) for a single tool, persists the
    choice to models.conf, and reinstalls. Requires a single --tool (claude or
    opencode) because their model-id namespaces differ.
  Layer 0 hooks are installed and registered BY DEFAULT. On Claude Code they
    are registered in settings.json; on OpenCode a plugin translates its events
    into the same hooks. They are what makes the harness's guarantees actual
    guarantees rather than requests, so they are not an optional extra. Your
    settings.json is backed up first, validated after, and your own hooks are
    left untouched.
  --no-hooks skips them. The harness still runs, but every guarantee degrades
    back to prose -- which is the failure mode Layer 0 exists to remove.
  For curl|bash installs, set IAMLAZY_RAW_BASE to the raw file base URL.
EOF
}

# Substitute model tokens. `|` delimiter because model ids contain `/`.
render() {
  # $1 template, $2 main model, $3 critic model
  sed -e "s|{{MAIN_MODEL}}|$2|g" -e "s|{{CRITIC_MODEL}}|$3|g" "$1"
}

# Compose the core body for ONE host: {{GUARANTEES}} and {{GATE}} are replaced
# by that host's files.
#
# Why the core is tokenised at all: its opening section used to state, flatly,
# that hooks enforce a list of things. That is true on Claude Code and false
# anywhere without Layer 0 -- so the same bytes were a description on one host
# and a lie on another. Two prompts would fix the lie and reintroduce drift,
# which this repo has already paid for three times (the A5 banner, the locale
# regex, the close firing before the review). One source, two small inserts,
# and a test that every token gets filled.
#
# $1 core body, $2 guarantees file, $3 gate file
compose_core() {
  awk -v g="$2" -v t="$3" '''
    # `<!-- hooks: ... -->` is a verification marker, not prompt text: the suite
    # compares it against the hooks merge-settings.sh actually registers, so a
    # new hook whose guarantee nobody wrote down fails the build. The model
    # never needs to read it, so it is dropped here.
    /\{\{GUARANTEES\}\}/ { while ((getline line < g) > 0) if (line !~ /^<!-- hooks:/) print line; close(g); next }
    /\{\{GATE\}\}/       { while ((getline line < t) > 0) print line; close(t); next }
    { print }
  ''' "$1"
}

# Write stdin to $1, but never clobber a pre-existing file that is not ours.
write_file() {
  dest="$1"
  tmp="$(mktemp 2>/dev/null || echo "${dest}.ilztmp.$$")"
  cat > "$tmp"
  if [ -f "$dest" ] && ! grep -q "$MARKER" "$dest" 2>/dev/null; then
    echo "  SKIP (exists, not $MARKER): $dest" >&2
    rm -f "$tmp"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  mv "$tmp" "$dest"
  echo "  wrote $dest"
}

install_claude() {
  mkdir -p "$CC_CMD_DIR" "$CC_AGENT_DIR"
  {
    render "$SRC/templates/claude-code/command-iamlazy.frontmatter" "$CC_MAIN_MODEL" "$CC_CRITIC_MODEL"
    compose_core "$SRC/core/iamlazy.md" \
      "$SRC/templates/claude-code/guarantees.md" "$SRC/templates/claude-code/gate.md"
    # shellcheck disable=SC2016  # $ARGUMENTS is Claude Code's own placeholder, not ours
    printf '\n\n---\n\n**Request:** $ARGUMENTS\n'
  } | write_file "$CC_CMD_DIR/iamlazy.md"
  {
    render "$SRC/templates/claude-code/command-review.frontmatter" "$CC_MAIN_MODEL" "$CC_CRITIC_MODEL"
    cat "$SRC/core/iamlazy-review.md"
  } | write_file "$CC_CMD_DIR/iamlazy-review.md"
  {
    render "$SRC/templates/claude-code/agent-critic.frontmatter" "$CC_MAIN_MODEL" "$CC_CRITIC_MODEL"
    cat "$SRC/critic/iamlazy-critic.md"
  } | write_file "$CC_AGENT_DIR/iamlazy-critic.md"
}

install_opencode() {
  mkdir -p "$OC_CMD_DIR" "$OC_AGENT_DIR"
  {
    render "$SRC/templates/opencode/primary-iamlazy.frontmatter" "$OC_MAIN_MODEL" "$OC_CRITIC_MODEL"
    compose_core "$SRC/core/iamlazy.md" \
      "$SRC/templates/opencode/guarantees.md" "$SRC/templates/opencode/gate.md"
  } | write_file "$OC_AGENT_DIR/iamlazy.md"
  {
    render "$SRC/templates/opencode/command-iamlazy.frontmatter" "$OC_MAIN_MODEL" "$OC_CRITIC_MODEL"
    # shellcheck disable=SC2016  # $ARGUMENTS is OpenCode's own placeholder, not ours
    printf '\n$ARGUMENTS\n'
  } | write_file "$OC_CMD_DIR/iamlazy.md"
  {
    render "$SRC/templates/opencode/command-review.frontmatter" "$OC_MAIN_MODEL" "$OC_CRITIC_MODEL"
    cat "$SRC/core/iamlazy-review.md"
  } | write_file "$OC_CMD_DIR/iamlazy-review.md"
  {
    render "$SRC/templates/opencode/subagent-critic.frontmatter" "$OC_MAIN_MODEL" "$OC_CRITIC_MODEL"
    cat "$SRC/critic/iamlazy-critic.md"
  } | write_file "$OC_AGENT_DIR/iamlazy-critic.md"
}


# copy_hooks <dir> -- every script in hooks/, globbed. A list you have to
# remember to extend is how a new hook lands in the repo and never installs.
copy_hooks() {
  mkdir -p "$1"
  for h in "$SRC"/hooks/*.sh; do
    n="$(basename "$h")"
    cp "$h" "$1/$n"
    chmod +x "$1/$n"
    echo "  wrote $1/$n"
  done
}

install_hooks() {
  copy_hooks "$CC_HOOK_DIR"
  # Registering is part of installing. A hook script nobody invokes is a file,
  # not a guarantee.
  if "$CC_HOOK_DIR/merge-settings.sh" "$HOME/.claude/settings.json" "$CC_HOOK_DIR"; then
    HOOKS_REGISTERED=1
  else
    HOOKS_REGISTERED=0
  fi
}

# OpenCode has no settings.json hooks block; it has plugins. The adapter IS the
# registration there: it translates OpenCode's events into the payloads the same
# hooks already read, so Layer 0 stays one implementation with two entry points.
install_opencode_hooks() {
  copy_hooks "$OC_HOOK_DIR"
  write_file "$OC_PLUGIN_DIR/iamlazy.ts" < "$SRC/adapters/opencode/iamlazy.ts"
}

print_hook_block() {
  if [ "$HOOKS_REGISTERED" -eq 1 ]; then
    cat <<EOF

  LAYER 0 ACTIVE. These run for you now, not on your discipline:
    - only the Critic may be spawned as a sub-agent, and its Bash cannot write
    - the run log is written, derived, at every close
    - every edit is traced to .iamlazy/journal.md
    - a run cannot close with a file outside its declared Scope, and is TOLD so
    - a run that ends without closing is logged as abandoned, not lost
    - a contract run cannot close before its review has come back
    - the harness refuses to start under a permission bypass
    - a run burning money without progress gets stopped and told to re-plan
  Run state is per SESSION, under ~/.iamlazy/active/ -- an open run in one
  session no longer changes how any other session behaves.
EOF
  else
    cat <<EOF

  LAYER 0 SCRIPTS INSTALLED, BUT NOT REGISTERED.
  No JSON parser (python3/python) was found, so settings.json was left alone.
  Add this "hooks" block to ~/.claude/settings.json by hand, or the harness
  runs with its guarantees degraded back to prose:

  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "$CC_HOOK_DIR/open-run.sh" } ] }
    ],
    "PreToolUse": [
      { "matcher": "^(Agent|Task)$",
        "hooks": [ { "type": "command", "command": "$CC_HOOK_DIR/guard-agent.sh" } ] },
      { "matcher": "^Bash\$",
        "hooks": [ { "type": "command", "command": "$CC_HOOK_DIR/guard-critic-bash.sh" } ] }
    ],
    "PostToolUse": [
      { "matcher": "^(Edit|Write|MultiEdit|NotebookEdit)\$",
        "hooks": [ { "type": "command", "command": "$CC_HOOK_DIR/track-edit.sh" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "$CC_HOOK_DIR/flush-run.sh" } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command", "command": "$CC_HOOK_DIR/end-run.sh" } ] }
    ],
    "SubagentStop": [
      { "hooks": [ { "type": "command", "command": "$CC_HOOK_DIR/subagent-done.sh" } ] }
    ]
  }
EOF
  fi
}

# ---------- parse args ----------
TOOL="auto"
MODEL_OVERRIDE=""
WITH_HOOKS=1
HOOKS_REGISTERED=0
DO_CHECK=0
for arg in "$@"; do
  case "$arg" in
    --tool=*) TOOL="${arg#--tool=}" ;;
    --model=*) MODEL_OVERRIDE="${arg#--model=}" ;;
    --with-hooks) WITH_HOOKS=1 ;;
    --no-hooks) WITH_HOOKS=0 ;;
    --check) DO_CHECK=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "iamlazy: unknown arg: $arg" >&2; usage; exit 1 ;;
  esac
done

# ---------- locate source (clone+run vs curl|bash) ----------
SCRIPT_DIR=""
case "$0" in
  */*) SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)" ;;
esac

CLEANUP_TMP=""
cleanup() { [ -n "$CLEANUP_TMP" ] && rm -rf "$CLEANUP_TMP"; return 0; }
trap cleanup EXIT

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/core/iamlazy.md" ]; then
  SRC="$SCRIPT_DIR"
else
  RAW="${IAMLAZY_RAW_BASE:-}"
  if [ -z "$RAW" ]; then
    echo "iamlazy: run from a cloned repo, or set IAMLAZY_RAW_BASE for curl|bash install." >&2
    exit 1
  fi
  command -v curl >/dev/null 2>&1 || { echo "iamlazy: curl is required for remote install." >&2; exit 1; }
  CLEANUP_TMP="$(mktemp -d 2>/dev/null || echo "/tmp/iamlazy.$$")"
  mkdir -p "$CLEANUP_TMP"
  for rel in $PAYLOAD; do
    mkdir -p "$CLEANUP_TMP/$(dirname "$rel")"
    curl -fsSL "$RAW/$rel" -o "$CLEANUP_TMP/$rel" \
      || { echo "iamlazy: failed to fetch $rel from $RAW" >&2; exit 1; }
  done
  SRC="$CLEANUP_TMP"
fi

# --check reads only; it must run before anything decides to write.
if [ "$DO_CHECK" -eq 1 ]; then
  run_check
  exit $?
fi

# ---------- models ----------
# shellcheck source=models.conf
. "$SRC/models.conf"

# ---------- pick tools ----------
do_claude=0
do_opencode=0
case "$TOOL" in
  claude) do_claude=1 ;;
  opencode) do_opencode=1 ;;
  both) do_claude=1; do_opencode=1 ;;
  auto)
    if command -v claude >/dev/null 2>&1 || [ -d "$HOME/.claude" ]; then do_claude=1; fi
    if command -v opencode >/dev/null 2>&1 || [ -d "$HOME/.config/opencode" ]; then do_opencode=1; fi
    ;;
  *) echo "iamlazy: unknown --tool=$TOOL (use claude|opencode|both)" >&2; exit 1 ;;
esac

if [ "$do_claude" -eq 0 ] && [ "$do_opencode" -eq 0 ]; then
  echo "iamlazy: neither claude nor opencode detected. Force with --tool=claude|opencode|both." >&2
  exit 1
fi

# ---------- --model override (both roles, single tool) ----------
# Rewrite two models.conf lines portably (sed -> tmp -> mv; no `sed -i`, macOS bash 3.2).
persist_model() {
  # $1 main-var name, $2 critic-var name, $3 value, $4 conf path
  ptmp="$(mktemp 2>/dev/null || echo "$4.ilztmp.$$")"
  sed -e "s|^$1=.*|$1=\"$3\"|" -e "s|^$2=.*|$2=\"$3\"|" "$4" > "$ptmp" \
    && mv "$ptmp" "$4"
}

if [ -n "$MODEL_OVERRIDE" ]; then
  if [ "$do_claude" -eq 1 ] && [ "$do_opencode" -eq 1 ]; then
    echo "iamlazy: --model requires a single --tool=claude|opencode (namespaces differ)." >&2
    exit 1
  fi
  if [ "$do_claude" -eq 1 ]; then
    CC_MAIN_MODEL="$MODEL_OVERRIDE"; CC_CRITIC_MODEL="$MODEL_OVERRIDE"
    if [ -n "$SCRIPT_DIR" ]; then persist_model CC_MAIN_MODEL CC_CRITIC_MODEL "$MODEL_OVERRIDE" "$SRC/models.conf"; fi
  else
    OC_MAIN_MODEL="$MODEL_OVERRIDE"; OC_CRITIC_MODEL="$MODEL_OVERRIDE"
    if [ -n "$SCRIPT_DIR" ]; then persist_model OC_MAIN_MODEL OC_CRITIC_MODEL "$MODEL_OVERRIDE" "$SRC/models.conf"; fi
  fi
fi

# ---------- install ----------
mkdir -p "$LOG_DIR"
# /iamlazy-review sweeps the backlog's triggers against the run log, so the candidates have to
# be readable from any project. The repo copy stays the source of truth; this one is a mirror.
if [ -f "$SRC/DELTAS.md" ]; then cp "$SRC/DELTAS.md" "$LOG_DIR/DELTAS.md"; fi
# The price table is CONFIG, not a generated mirror: never clobber it. Prices
# change and the human edits this file; overwriting their edit on every install
# is how a cost figure goes quietly wrong.
if [ -f "$SRC/prices.conf" ] && [ ! -f "$LOG_DIR/prices.conf" ]; then
  cp "$SRC/prices.conf" "$LOG_DIR/prices.conf"
  echo "  wrote $LOG_DIR/prices.conf"
elif [ -f "$LOG_DIR/prices.conf" ]; then
  echo "  kept  $LOG_DIR/prices.conf (yours; not overwritten)"
fi
echo "iamlazy installer  (source: $SRC)"
if [ "$do_claude" -eq 1 ]; then
  echo "Claude Code -> $CC_MAIN_MODEL (main) / $CC_CRITIC_MODEL (critic)"
  install_claude
fi
if [ "$do_opencode" -eq 1 ]; then
  echo "OpenCode -> $OC_MAIN_MODEL (main) / $OC_CRITIC_MODEL (critic)"
  install_opencode
fi
if [ "$WITH_HOOKS" -eq 1 ] && [ "$do_claude" -eq 1 ]; then
  install_hooks
fi
if [ "$WITH_HOOKS" -eq 1 ] && [ "$do_opencode" -eq 1 ]; then
  install_opencode_hooks
fi

if [ "$WITH_HOOKS" -eq 1 ] && [ "$do_claude" -eq 1 ]; then
  print_hook_block
fi
if [ "$WITH_HOOKS" -eq 1 ] && [ "$do_opencode" -eq 1 ]; then
  cat <<EOF

  LAYER 0 ON OPENCODE: $OC_PLUGIN_DIR/iamlazy.ts translates OpenCode's events
  into the same hooks, now in $OC_HOOK_DIR. Plugins load at startup, so restart
  any running OpenCode. Cost comes from OpenCode's own per-message pricing. There
  is no permission-bypass refusal: OpenCode has no such mode.
EOF
fi

# The version that WROTE a run's log line, not the version the repo currently
# is: stamped once here, read back by flush-run.sh at every close. `--check`
# already catches drift byte-for-byte, which is strictly more precise than a
# version string could be -- this is for the question `--check` cannot answer,
# which came up twice tonight: "was this weird run before or after the fix?"
# Prefer the git SHA (a clone+run install, so $SRC/.git is real and the SHA
# names an exact, inspectable commit); a curl|bash install has no .git, so
# fall back to a content fingerprint (cksum, POSIX and on every platform this
# project targets, unlike shasum/sha1sum's macOS-vs-Linux naming split) of
# every file that enforces something -- the hooks AND the OpenCode adapter,
# since both are Layer 0.
if [ "$WITH_HOOKS" -eq 1 ]; then
  mkdir -p "$LOG_DIR"
  if [ -d "$SRC/.git" ] && command -v git >/dev/null 2>&1 \
     && ver="$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null)" && [ -n "$ver" ]; then
    printf '%s\n' "$ver" > "$LOG_DIR/hooks_version"
  else
    cat "$SRC"/hooks/*.sh "$SRC/adapters/opencode/iamlazy.ts" 2>/dev/null \
      | cksum | awk '{print $1}' > "$LOG_DIR/hooks_version"
  fi
fi

echo
echo "done."
echo "  log dir:  $LOG_DIR"
echo "  commands: /iamlazy  /iamlazy-review"
if [ "$do_claude" -eq 1 ]; then
  echo
  echo "  MODEL SCOPE: '$CC_MAIN_MODEL' covers the planner turn ONLY. A command's model:"
  echo "  frontmatter expires at your next prompt -- and the gate IS a prompt -- so the"
  echo "  builder (A4-A5) runs on your SESSION model, never on models.conf."
  if grep -q '"model"' "$HOME/.claude/settings.json" 2>/dev/null; then
    echo "  OK: ~/.claude/settings.json pins a session model, so the build is deterministic."
  else
    echo "  No session model is pinned in ~/.claude/settings.json, so the build runs on"
    echo "  whatever the session happens to default to. To pin it, add one of:"
    echo "    \"model\": \"claude-opus-5\"   one model the whole way"
    echo "    \"model\": \"opusplan\"          Opus in plan mode, Sonnet on execution"
    echo "  A project .claude/settings.json works too, and takes precedence."
  fi
  if [ -n "${CLAUDE_CODE_SUBAGENT_MODEL:-}" ]; then
    echo "  WARNING: CLAUDE_CODE_SUBAGENT_MODEL='$CLAUDE_CODE_SUBAGENT_MODEL' is set and"
    echo "  overrides CC_CRITIC_MODEL ('$CC_CRITIC_MODEL'). Unset it to use the value above."
  fi
fi
if [ "$do_opencode" -eq 1 ]; then
  echo "  note: OpenCode needs a credential for its provider (env or opencode.json). Not configured by this installer."
  echo "  Analysis runs on OpenCode's built-in 'plan' agent, which pins no model and inherits the"
  echo "  LIVE SESSION model -- the one entering 'iamlazy' just set. So the planner runs on"
  echo "  $OC_MAIN_MODEL too, and your OpenCode default does not change that. To split them, pin"
  echo "  it in your own opencode.json:  \"agent\": { \"plan\": { \"model\": \"...\" } }"
fi
