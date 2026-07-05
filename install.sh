#!/usr/bin/env bash
# ledger installer — bash 3.2 compatible. Zero external deps (coreutils only;
# curl is needed only for the curl|bash remote path). Idempotent via the
# `ledger-managed` marker embedded in every generated file's frontmatter.
set -eu

MARKER="ledger-managed"

CC_CMD_DIR="${HOME}/.claude/commands"
CC_AGENT_DIR="${HOME}/.claude/agents"
OC_CMD_DIR="${HOME}/.config/opencode/commands"
OC_AGENT_DIR="${HOME}/.config/opencode/agents"
LOG_DIR="${HOME}/.ledger"

# Files that make up the payload (relative to the repo root).
PAYLOAD="core/ledger.md core/ledger-review.md critic/ledger-critic.md \
templates/claude-code/command-ledger.frontmatter \
templates/claude-code/command-review.frontmatter \
templates/claude-code/agent-critic.frontmatter \
templates/opencode/primary-ledger.frontmatter \
templates/opencode/command-ledger.frontmatter \
templates/opencode/command-review.frontmatter \
templates/opencode/subagent-critic.frontmatter \
models.conf"

usage() {
  cat <<'EOF'
ledger installer
  usage: install.sh [--tool=claude|opencode|both]
  Auto-detects installed tools when --tool is omitted.
  For curl|bash installs, set LEDGER_RAW_BASE to the raw file base URL.
EOF
}

# Substitute model tokens. `|` delimiter because model ids contain `/`.
render() {
  # $1 template, $2 main model, $3 critic model
  sed -e "s|{{MAIN_MODEL}}|$2|g" -e "s|{{CRITIC_MODEL}}|$3|g" "$1"
}

# Write stdin to $1, but never clobber a pre-existing file that is not ours.
write_file() {
  dest="$1"
  tmp="$(mktemp 2>/dev/null || echo "${dest}.ldtmp.$$")"
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
    render "$SRC/templates/claude-code/command-ledger.frontmatter" "$CC_MAIN_MODEL" "$CC_CRITIC_MODEL"
    cat "$SRC/core/ledger.md"
    printf '\n\n---\n\n**Request:** $ARGUMENTS\n'
  } | write_file "$CC_CMD_DIR/ledger.md"
  {
    render "$SRC/templates/claude-code/command-review.frontmatter" "$CC_MAIN_MODEL" "$CC_CRITIC_MODEL"
    cat "$SRC/core/ledger-review.md"
  } | write_file "$CC_CMD_DIR/ledger-review.md"
  {
    render "$SRC/templates/claude-code/agent-critic.frontmatter" "$CC_MAIN_MODEL" "$CC_CRITIC_MODEL"
    cat "$SRC/critic/ledger-critic.md"
  } | write_file "$CC_AGENT_DIR/ledger-critic.md"
}

install_opencode() {
  mkdir -p "$OC_CMD_DIR" "$OC_AGENT_DIR"
  {
    render "$SRC/templates/opencode/primary-ledger.frontmatter" "$OC_MAIN_MODEL" "$OC_CRITIC_MODEL"
    cat "$SRC/core/ledger.md"
  } | write_file "$OC_AGENT_DIR/ledger.md"
  {
    render "$SRC/templates/opencode/command-ledger.frontmatter" "$OC_MAIN_MODEL" "$OC_CRITIC_MODEL"
    printf '\n$ARGUMENTS\n'
  } | write_file "$OC_CMD_DIR/ledger.md"
  {
    render "$SRC/templates/opencode/command-review.frontmatter" "$OC_MAIN_MODEL" "$OC_CRITIC_MODEL"
    cat "$SRC/core/ledger-review.md"
  } | write_file "$OC_CMD_DIR/ledger-review.md"
  {
    render "$SRC/templates/opencode/subagent-critic.frontmatter" "$OC_MAIN_MODEL" "$OC_CRITIC_MODEL"
    cat "$SRC/critic/ledger-critic.md"
  } | write_file "$OC_AGENT_DIR/ledger-critic.md"
}

# ---------- parse args ----------
TOOL="auto"
for arg in "$@"; do
  case "$arg" in
    --tool=*) TOOL="${arg#--tool=}" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ledger: unknown arg: $arg" >&2; usage; exit 1 ;;
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

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/core/ledger.md" ]; then
  SRC="$SCRIPT_DIR"
else
  RAW="${LEDGER_RAW_BASE:-}"
  if [ -z "$RAW" ]; then
    echo "ledger: run from a cloned repo, or set LEDGER_RAW_BASE for curl|bash install." >&2
    exit 1
  fi
  command -v curl >/dev/null 2>&1 || { echo "ledger: curl is required for remote install." >&2; exit 1; }
  CLEANUP_TMP="$(mktemp -d 2>/dev/null || echo "/tmp/ledger.$$")"
  mkdir -p "$CLEANUP_TMP"
  for rel in $PAYLOAD; do
    mkdir -p "$CLEANUP_TMP/$(dirname "$rel")"
    curl -fsSL "$RAW/$rel" -o "$CLEANUP_TMP/$rel" \
      || { echo "ledger: failed to fetch $rel from $RAW" >&2; exit 1; }
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
  *) echo "ledger: unknown --tool=$TOOL (use claude|opencode|both)" >&2; exit 1 ;;
esac

if [ "$do_claude" -eq 0 ] && [ "$do_opencode" -eq 0 ]; then
  echo "ledger: neither claude nor opencode detected. Force with --tool=claude|opencode|both." >&2
  exit 1
fi

# ---------- install ----------
mkdir -p "$LOG_DIR"
echo "ledger installer  (source: $SRC)"
if [ "$do_claude" -eq 1 ]; then
  echo "Claude Code -> $CC_MAIN_MODEL (main) / $CC_CRITIC_MODEL (critic)"
  install_claude
fi
if [ "$do_opencode" -eq 1 ]; then
  echo "OpenCode -> $OC_MAIN_MODEL (main) / $OC_CRITIC_MODEL (critic)"
  install_opencode
fi

echo
echo "done."
echo "  log dir:  $LOG_DIR"
echo "  commands: /ledger  /ledger-review"
if [ "$do_opencode" -eq 1 ]; then
  echo "  note: OpenCode needs a DeepSeek credential (env or opencode.json). Not configured by this installer."
fi
