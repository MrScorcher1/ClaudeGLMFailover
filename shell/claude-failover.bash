# --- claude-failover -------------------------------------------------------
# Explicit, persisted profile selection for the GLM-5.2 usage-limit failover.
#
# Append this to ~/.bashrc (or ~/.zshrc) and open a new terminal.
#
#   claude-failover                    use the saved profile
#   claude-failover --profile work     switch to ~/.claude-work, save it, launch
#   claude-failover --profile /opt/cfg absolute path, save it, launch
#   claude-failover --profile          print the saved profile and exit
#   claude-failover --profile x --force  skip the classifier check

_CF_STATE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-failover"
_CF_PROFILE_FILE="$_CF_STATE_DIR/profile"
_CF_ARGS_DIR="$_CF_STATE_DIR/args"
_CF_WATCHER="$HOME/claude-failover.sh"
_CF_LOCAL="$HOME/.local/bin/claude-local"

# Markers proving sessions have actually run here.
_CF_USE_MARKERS=( "projects" "history.jsonl" )

# Markers proving deliberate configuration, even with no sessions yet.
#
# CLAUDE.md is deliberately NOT in this list. It is not evidence of a
# configured profile: on the development machine ~/.claude contained nothing
# but a CLAUDE.md symlinked into a plugin marketplace, and counting it
# classified an unused directory as CONFIGURED — the exact case the classifier
# exists to refuse. Incidental markers (.credentials.json, statsig/, todos/)
# are excluded for the same reason: they appear on any launch attempt,
# including one that failed immediately.
_CF_CONF_MARKERS=( "settings.json" "commands" "agents" "plugins" )

# Echoes one of USED / CONFIGURED / EMPTY / MISSING.
# Returns 0 / 1 / 2 / 3 respectively. Filesystem only: no session, no network.
_cf_classify() {
  local d="$1" m
  [ -d "$d" ] || { echo "MISSING"; return 3; }

  # Tier 1 — real transcripts anywhere under projects/
  if [ -d "$d/projects" ] && \
     find "$d/projects" -name '*.jsonl' -type f 2>/dev/null | head -1 | grep -q .; then
    echo "USED"; return 0
  fi
  # Tier 1b — non-empty history
  if [ -s "$d/history.jsonl" ]; then echo "USED"; return 0; fi

  # Tier 2 — deliberate configuration. -s and emptiness checks matter here: a
  # zero-byte settings.json and an empty projects/ both prove nothing.
  for m in "${_CF_CONF_MARKERS[@]}"; do
    if [ -s "$d/$m" ] || { [ -d "$d/$m" ] && [ -n "$(ls -A "$d/$m" 2>/dev/null)" ]; }; then
      echo "CONFIGURED"; return 1
    fi
  done

  echo "EMPTY"; return 2
}

# Resolution is a convention, not a lookup. Nothing is enumerated.
#   /abs/path        -> itself
#   default | claude -> $HOME/.claude
#   X                -> $HOME/.claude-X
_cf_resolve_profile() {
  local name="$1"
  if [ -z "$name" ]; then
    echo "claude-failover: empty profile name" >&2
    return 1
  fi
  case "$name" in
    /*) printf '%s\n' "${name%/}"; return 0 ;;
    -*) echo "claude-failover: profile name may not start with '-': $name" >&2
        echo "  (looks like a mistyped flag)" >&2
        return 1 ;;
  esac
  # Whitelist: letters, digits, dot, underscore, hyphen. Rejects '/', spaces,
  # and traversal such as ../x.
  case "$name" in
    *[!A-Za-z0-9._-]*)
      echo "claude-failover: invalid profile name: $name" >&2
      echo "  names may contain only letters, digits, '.', '_', '-'" >&2
      echo "  or give an absolute path" >&2
      return 1 ;;
  esac
  case "$name" in
    default|claude) printf '%s\n' "$HOME/.claude" ;;
    *)              printf '%s\n' "$HOME/.claude-$name" ;;
  esac
}

# Short label for the $HOME/.claude-X convention; the full path otherwise.
# Deliberately NOT the basename for unconventional paths: the label also names
# the per-profile args file, and two directories can share a basename.
_cf_label_for() {
  local d="${1%/}"
  case "$d" in
    "$HOME/.claude")   echo "default" ;;
    "$HOME/.claude-"*) echo "${d#"$HOME"/.claude-}" ;;
    *)                 echo "$d" ;;
  esac
}

# Avoids printing "profile '/long/path' (/long/path)" when the label IS the path.
_cf_print_profile() {
  local dir="$1" label
  label="$(_cf_label_for "$dir")"
  if [ "$label" = "$dir" ]; then
    printf "claude-failover: profile %s\n" "$dir"
  else
    printf "claude-failover: profile '%s' (%s)\n" "$label" "$dir"
  fi
}

# Atomic: temp file plus mv, so an interrupted write cannot leave a truncated
# path that resolves to something unintended.
_cf_save_profile() {
  local path="$1" tmp
  mkdir -p "$_CF_STATE_DIR" 2>/dev/null || return 1
  tmp="$(mktemp "$_CF_STATE_DIR/.profile.XXXXXX" 2>/dev/null)" || return 1
  if printf '%s\n' "$path" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$_CF_PROFILE_FILE" 2>/dev/null && return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

_cf_load_profile() {
  [ -r "$_CF_PROFILE_FILE" ] || return 1
  head -1 "$_CF_PROFILE_FILE" 2>/dev/null
}

# Optional per-profile flags from $_CF_ARGS_DIR/<label>.
#
# This content is typed into a shell by tmux send-keys, so it is validated as a
# bounded format rather than trusted as a command fragment. Copying an args
# file from a README or a teammate is exactly the path a public repo invites.
_cf_read_args() {
  local label="$1" f line bad tok out=""
  f="$_CF_ARGS_DIR/$label"
  [ -f "$f" ] || return 0
  line="$(grep -vE '^[[:space:]]*($|#)' "$f" 2>/dev/null | head -1)"
  [ -n "$line" ] || return 0
  for bad in ';' '|' '&' '`' '$(' '<' '>'; do
    case "$line" in
      *"$bad"*)
        echo "claude-failover: args file rejected: $f" >&2
        echo "  contains '$bad' — this file holds flags, not shell" >&2
        return 1 ;;
    esac
  done
  # Quote-aware splitting via xargs rather than bare word splitting, so an
  # argument containing spaces can be written as --plugin-dir "/a/my plugins".
  # xargs handles quoting without invoking a shell, so nothing here executes;
  # the metacharacter rejection above still applies.
  local parsed
  if ! parsed="$(printf '%s' "$line" | xargs -n1 printf '%s\n' 2>/dev/null)"; then
    echo "claude-failover: args file rejected: $f" >&2
    echo "  unmatched quote — check the quoting on that line" >&2
    return 1
  fi
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    out="$out $(printf '%q' "$tok")"
  done <<< "$parsed"
  printf '%s' "$out"
}

# Allocate a port for this session's proxy. Scanning starts at a random offset
# so two sessions launched at the same moment are unlikely to pick the same
# port; if they do, the loser's readiness check fails and claude-local reports
# it rather than silently sharing.
_CF_PORT_LO="${CLAUDE_FAILOVER_PORT_LO:-4100}"
_CF_PORT_HI="${CLAUDE_FAILOVER_PORT_HI:-4199}"

_cf_free_port() {
  local span=$(( _CF_PORT_HI - _CF_PORT_LO + 1 ))
  local start=$(( _CF_PORT_LO + RANDOM % span ))
  local i p
  for (( i = 0; i < span; i++ )); do
    p=$(( _CF_PORT_LO + ( (start - _CF_PORT_LO) + i ) % span ))
    ss -ltn 2>/dev/null | grep -q ":$p " || { printf '%s' "$p"; return 0; }
  done
  return 1
}

_cf_start_watcher() {
  local pane="$1" dir="$2" extra="$3" port="$4" pane_dir
  # Never run two watchers on the same pane. The trailing $ anchors the match:
  # without it, pane "%3" also matches a watcher running on "%30".
  if pgrep -f "claude-failover\.sh ${pane}\$" >/dev/null 2>&1; then
    return 0
  fi
  pane_dir="$(tmux display-message -p -t "$pane" '#{pane_current_path}' 2>/dev/null)"
  # RELAUNCH_CMD carries the config dir and any per-profile flags into the
  # swap. EXPECT_* let the watcher refuse a swap that would resume the wrong
  # conversation. All three must agree with what launched the session.
  # The port must be carried into the swap exactly like the config dir. If it
  # were not, the relaunch would allocate a different one, start a SECOND proxy
  # and orphan this session's.
  RELAUNCH_CMD="CLAUDE_CONFIG_DIR=$(printf '%q' "$dir") CLAUDE_LOCAL_PORT=$port $_CF_LOCAL --continue${extra}" \
  EXPECT_CONFIG_DIR="$dir" \
  EXPECT_PANE_DIR="$pane_dir" \
  SESSION_PORT="$port" \
    nohup "$_CF_WATCHER" "$pane" >/dev/null 2>&1 &
  disown 2>/dev/null
  # The watcher is silent by design — its output would scribble over the
  # session. Say it is armed here, or the only evidence is a log file the user
  # has to know exists.
  echo "claude-failover: watcher armed on pane $pane, proxy port $port — log: ${LOG_FILE:-$HOME/.claude-failover.log}"
}

claude-failover() {
  local profile_arg="" query_only=0 force=0 dir class label extra base
  local -a passthru=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --profile)
        # A missing value, or a following flag, makes this a query.
        case "${2:-}" in
          ""|-*) query_only=1; shift ;;
          *)     profile_arg="$2"; shift 2 ;;
        esac ;;
      --force) force=1; shift ;;
      -p|--print)
        echo "claude-failover: print mode is not supported here." >&2
        echo "  use: claude -p ..." >&2
        return 1 ;;
      *) passthru+=("$1"); shift ;;
    esac
  done

  # A query never launches and never persists.
  if [ "$query_only" -eq 1 ]; then
    local saved
    if saved="$(_cf_load_profile)" && [ -n "$saved" ]; then
      _cf_print_profile "$saved"
    else
      # Say what is wrong in plain terms. Classifier names (USED/EMPTY/...) are
      # internal vocabulary and do not belong in user-facing output.
      if [ "$(_cf_classify "$HOME/.claude")" = "USED" ]; then
        echo "claude-failover: no profile set — will use $HOME/.claude"
      else
        echo "claude-failover: no profile set, and nothing usable found at $HOME/.claude"
      fi
      echo "  set one with: claude-failover --profile <name|/abs/path>"
    fi
    return 0
  fi

  if [ -n "$profile_arg" ]; then
    dir="$(_cf_resolve_profile "$profile_arg")" || return 1
  else
    dir="$(_cf_load_profile)" || dir=""
    [ -n "$dir" ] || dir="$HOME/.claude"
  fi

  # Re-classify on every launch, not only when --profile is passed: a saved
  # path goes stale if the directory is moved or deleted.
  class="$(_cf_classify "$dir")"
  case "$class" in
    USED) ;;
    CONFIGURED)
      echo "claude-failover: no past sessions at $dir yet." >&2
      echo "  failover cannot kick in until you have used this profile at least once." >&2 ;;
    EMPTY|MISSING)
      if [ "$force" -eq 1 ]; then
        echo "claude-failover: WARNING — using $dir anyway because --force was given" >&2
      else
        if [ "$class" = "MISSING" ]; then
          echo "claude-failover: no such directory: $dir" >&2
          echo "  if you saved this profile earlier, it has since moved or been deleted" >&2
        else
          echo "claude-failover: nothing usable found at $dir" >&2
          echo "  no past sessions and no settings there, so it does not look like" >&2
          echo "  a Claude Code profile" >&2
        fi
        echo "  set one with: claude-failover --profile <name|/abs/path>" >&2
        echo "  or use it anyway with: --force" >&2
        return 1
      fi ;;
  esac

  # Intent is expressed by now, and a later failure should not silently revert
  # the profile. Still before any session exists.
  if ! _cf_save_profile "$dir"; then
    echo "claude-failover: could not write $_CF_PROFILE_FILE" >&2
    return 1
  fi

  label="$(_cf_label_for "$dir")"
  extra="$(_cf_read_args "$label")" || return 1
  _cf_print_profile "$dir"

  # One proxy per session. Allocated here so both the in-tmux and detached
  # branches use the same value, and so it is known before anything launches.
  local port
  if ! port="$(_cf_free_port)"; then
    echo "claude-failover: no free port in ${_CF_PORT_LO}-${_CF_PORT_HI}; falling back to the shared 4000" >&2
    port=4000
  fi

  base="CLAUDE_CONFIG_DIR=$(printf '%q' "$dir") command claude${extra}"

  if [ -n "${TMUX:-}" ]; then
    # Already inside tmux — we know our own pane from $TMUX_PANE.
    _cf_start_watcher "$TMUX_PANE" "$dir" "$extra" "$port"
    eval "$base" '"${passthru[@]}"'
    local rc=$?
    echo "claude-failover: Claude Code exited — watcher stops on its own shortly"
    return $rc
  fi

  # Not in tmux. Create a detached session running an interactive SHELL, then
  # send `claude` into it.
  #
  # IMPORTANT: the pane must run a shell, not claude directly. If claude were
  # the pane's own command, exiting it would close the pane — and the watcher
  # would have nothing to type the relaunch into. Do not "simplify" this to
  # `tmux new-session -d "claude"` — that closes the pane on exit.
  # $$ alone collides if you run this twice from the same shell.
  local session="cf-$$" n=1
  while tmux has-session -t "$session" 2>/dev/null; do
    session="cf-$$-$n"
    n=$((n + 1))
  done

  if ! tmux new-session -d -s "$session" -c "$PWD"; then
    echo "claude-failover: could not create tmux session" >&2
    return 1
  fi

  local pane
  pane="$(tmux list-panes -t "$session" -F '#{pane_id}' | head -1)"

  # Show the failover state in the status bar of the session we created. The
  # startup lines scroll away the instant tmux attaches, so without this there
  # is nothing on screen telling you the watcher is armed. Scoped with -t to
  # this session only, so a user's own tmux config is untouched and the setting
  # dies with the session.
  tmux set-option -t "$session" status-style "bg=green,fg=black" 2>/dev/null
  tmux set-option -t "$session" status-right " failover: armed   %H:%M " 2>/dev/null
  tmux set-option -t "$session" status-right-length 40 2>/dev/null

  # Quote each argument individually. A bare "$*" mangles anything containing
  # spaces, e.g. --append-system-prompt "be brief".
  local quoted="" arg
  for arg in "${passthru[@]}"; do
    quoted="$quoted $(printf '%q' "$arg")"
  done

  tmux send-keys -t "$pane" "$base$quoted" Enter
  _cf_start_watcher "$pane" "$dir" "$extra" "$port"
  tmux attach -t "$session"

  # attach returns either because the session ended or because the user
  # detached. The watcher is silent, so report which one happened — otherwise
  # the only way to know whether you are still protected is to read a log.
  if tmux has-session -t "$session" 2>/dev/null; then
    echo "claude-failover: detached from $session — watcher still running on pane $pane"
    echo "  reattach with: tmux attach -t $session"
  else
    echo "claude-failover: session ended — watcher stopped"
  fi
}

claude-personal-failover() {
  echo "claude-personal-failover is now 'claude-failover' — this name will be removed." >&2
  claude-failover "$@"
}
# ---------------------------------------------------------------------------
