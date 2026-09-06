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
LOG_DIR="${HOME}/.iamlazy"
CC_HOOK_DIR="${HOME}/.claude/iamlazy-hooks"

# Files that make up the payload (relative to the repo root).
PAYLOAD="core/iamlazy.md core/iamlazy-review.md critic/iamlazy-critic.md \
hooks/lib.sh hooks/guard-agent.sh hooks/open-run.sh hooks/track-edit.sh hooks/flush-run.sh \
hooks/end-run.sh hooks/subagent-done.sh hooks/guard-critic-bash.sh hooks/merge-settings.sh \
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

usage() {
  cat <<'EOF'
iamlazy installer
  usage: install.sh [--tool=claude|opencode|both] [--model=<id>] [--no-hooks]
  Auto-detects installed tools when --tool is omitted.
  --model=<id> sets BOTH roles (main + critic) for a single tool, persists the
    choice to models.conf, and reinstalls. Requires a single --tool (claude or
    opencode) because their model-id namespaces differ.
  Layer 0 hooks are installed and registered BY DEFAULT (Claude Code only).
    They are what makes the harness's guarantees actual guarantees rather than
    requests, so they are not an optional extra. Your settings.json is backed
    up first, validated after, and your own hooks are left untouched.
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


install_hooks() {
  mkdir -p "$CC_HOOK_DIR"
  for h in lib.sh guard-agent.sh guard-critic-bash.sh open-run.sh track-edit.sh flush-run.sh end-run.sh subagent-done.sh merge-settings.sh; do
    if [ -f "$SRC/hooks/$h" ]; then
      cp "$SRC/hooks/$h" "$CC_HOOK_DIR/$h"
      chmod +x "$CC_HOOK_DIR/$h"
      echo "  wrote $CC_HOOK_DIR/$h"
    fi
  done
  # Registering is part of installing. A hook script nobody invokes is a file,
  # not a guarantee.
  if "$CC_HOOK_DIR/merge-settings.sh" "$HOME/.claude/settings.json" "$CC_HOOK_DIR"; then
    HOOKS_REGISTERED=1
  else
    HOOKS_REGISTERED=0
  fi
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
for arg in "$@"; do
  case "$arg" in
    --tool=*) TOOL="${arg#--tool=}" ;;
    --model=*) MODEL_OVERRIDE="${arg#--model=}" ;;
    --with-hooks) WITH_HOOKS=1 ;;
    --no-hooks) WITH_HOOKS=0 ;;
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

# ---------- models ----------
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

if [ "$WITH_HOOKS" -eq 1 ] && [ "$do_claude" -eq 1 ]; then
  print_hook_block
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
  echo "  note: OpenCode needs a DeepSeek credential (env or opencode.json). Not configured by this installer."
fi
