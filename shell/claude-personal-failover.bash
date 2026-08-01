
# --- claude-personal-failover ----------------------------------------------
# The command this wraps. This is `claude-personal` expanded inline, because
# bash does not expand aliases inside function bodies, so the alias NAME
# will not work here — this must be the expansion.
# If your alias ever changes, update this to match `type claude-personal`.
CPF_BASE_CMD="${CPF_BASE_CMD:-CLAUDE_CONFIG_DIR=$HOME/.claude-personal command claude}"

# The config dir the session runs under. The watcher must relaunch with the
# SAME value, or `--continue` looks in ~/.claude, finds no transcript, and
# opens an empty session — silently losing the conversation it exists to save.
CPF_CONFIG_DIR="${CPF_CONFIG_DIR:-$HOME/.claude-personal}"

claude-personal-failover() {
  local watcher="$HOME/claude-failover.sh"

  # Verify the base command exists before building a session around it.
  # Skip over any leading VAR=value assignments (e.g. CLAUDE_CONFIG_DIR=...)
  # to find the actual command word.
  local base_name="" tok
  for tok in $CPF_BASE_CMD; do
    case "$tok" in
      *=*) continue ;;
      *)   base_name="$tok"; break ;;
    esac
  done
  if [ "$base_name" != "command" ] && ! type "$base_name" >/dev/null 2>&1; then
    echo "claude-personal-failover: CPF_BASE_CMD is set to '$CPF_BASE_CMD'," >&2
    echo "  but '$base_name' does not resolve here." >&2
    echo "  Run: type $base_name" >&2
    echo "  If it is an alias, set CPF_BASE_CMD to what the alias expands to," >&2
    echo "  not the alias name — bash does not expand aliases inside functions." >&2
    return 1
  fi

  if [ ! -x "$watcher" ]; then
    echo "claude-personal-failover: watcher not found or not executable at $watcher" >&2
    echo "  fix: make it executable with chmod +x $watcher" >&2
    return 1
  fi

  # This command is for interactive sessions only. For scripted use, call
  # `claude -p` directly — it has nothing to do with failover.
  local a
  for a in "$@"; do
    case "$a" in
      -p|--print)
        echo "claude-personal-failover: print mode is not supported here." >&2
        echo "  use: claude -p ..." >&2
        return 1
        ;;
    esac
  done

  if [ -n "${TMUX:-}" ]; then
    # Already inside tmux — we know our own pane from $TMUX_PANE.
    _cpf_start_watcher "$TMUX_PANE"
    eval "$CPF_BASE_CMD" '"$@"'
    return $?
  fi

  # Not in tmux. Create a detached session running an interactive SHELL,
  # then send `claude` into it.
  #
  # IMPORTANT: the pane must run a shell, not claude directly. If claude were
  # the pane's own command, exiting it would close the pane — and the watcher
  # would have nothing to type the relaunch into. Do not "simplify" this to
  # `tmux new-session -d "claude"` — that closes the pane on exit.
  # $$ alone collides if you run this twice from the same shell.
  local session="cpf-$$" n=1
  while tmux has-session -t "$session" 2>/dev/null; do
    session="cpf-$$-$n"
    n=$((n + 1))
  done

  if ! tmux new-session -d -s "$session" -c "$PWD"; then
    echo "claude-personal-failover: could not create tmux session" >&2
    return 1
  fi

  local pane
  pane="$(tmux list-panes -t "$session" -F '#{pane_id}' | head -1)"

  # Quote each argument individually. A bare "$*" mangles anything containing
  # spaces, e.g. --append-system-prompt "be brief".
  local quoted="" arg
  for arg in "$@"; do
    quoted="$quoted $(printf '%q' "$arg")"
  done

  tmux send-keys -t "$pane" "$CPF_BASE_CMD$quoted" Enter
  _cpf_start_watcher "$pane"
  tmux attach -t "$session"
}

_cpf_start_watcher() {
  local pane="$1"
  # Never run two watchers on the same pane. The trailing $ anchors the match:
  # without it, pane "%3" also matches a watcher running on "%30".
  if pgrep -f "claude-failover\.sh ${pane}\$" >/dev/null 2>&1; then
    return 0
  fi
  # RELAUNCH_CMD carries the config dir into the swap. Without it the watcher
  # resumes against ~/.claude and finds nothing. This is the single most
  # important line in this file.
  RELAUNCH_CMD="CLAUDE_CONFIG_DIR=$CPF_CONFIG_DIR $HOME/.local/bin/claude-local --continue" \
    nohup "$HOME/claude-failover.sh" "$pane" >/dev/null 2>&1 &
  disown 2>/dev/null
}
# ---------------------------------------------------------------------------
