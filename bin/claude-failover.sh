#!/usr/bin/env bash
# claude-failover — watch a tmux pane for Claude Code usage-limit notices and
# hot-swap the session onto GLM-5.2 by relaunching with `claude-local --continue`.
#
# Context survives the swap because Claude Code writes the transcript to disk
# continuously; --continue reloads the full message history and tool results.
#
# Usage:
#   ./claude-failover.sh %3
#
# Find your pane id with:
#   tmux list-panes -a -F '#{pane_id} #{pane_current_command} #{pane_current_path}'
#
# Normally started for you by the `claude-failover` shell function, which also
# sets RELAUNCH_CMD and the EXPECT_* guard variables so the swap resumes under
# the same profile the session ran in. Starting it by hand leaves the pre-swap
# guard disabled — see EXPECT_CONFIG_DIR below.
#
# Verified on tmux 3.6: pane_current_command reports "claude" for the
# native-installer binary, so foreground_is_claude() works unmodified.

# Deliberately no `set -e`: this is a long-running monitor and must survive
# transient tmux/grep failures rather than dying on them.
# Also no `pipefail` — see pane_tail() for why.
set -u

PANE="${1:-}"
POLL="${POLL_SECONDS:-5}"          # how often to check the pane
SCAN="${SCAN_LINES:-30}"           # only read the tail, not full scrollback
SETTLE="${SETTLE_SECONDS:-4}"      # pause after exiting Claude Code
EXIT_TIMEOUT="${EXIT_TIMEOUT:-20}"    # max wait for Claude Code to actually exit
READY_TIMEOUT="${READY_TIMEOUT:-90}"  # max wait for the new session to come up
COOLDOWN="${COOLDOWN_SECONDS:-900}"   # ignore detections for this long after a swap
IDLE_EXIT="${IDLE_EXIT_SECONDS:-120}" # quit if Claude Code stays gone this long (0 = never)
WD_COOLDOWN="${WD_COOLDOWN_SECONDS:-60}" # short throttle for the self-correcting cd case
KEY_PROMPT_TIMEOUT="${KEY_PROMPT_TIMEOUT_SECONDS:-15}" # max wait for the one-time API key prompt
CLOSE_PANE="${CLOSE_PANE_ON_EXIT:-1}"  # close the pane when the watcher gives up on it (0 = leave it)
CLOSE_PANE_DELAY="${CLOSE_PANE_DELAY_SECONDS:-3}" # let the "stopped" state be visible before the pane goes
FINAL_WARN="${FINAL_WARN_SECONDS:-10}"   # countdown turns red for the last this-many seconds
LOG="${LOG_FILE:-$HOME/.claude-failover.log}"

# Freshness window for the pre-swap guard, in MINUTES, derived from the longest
# cooldown rather than set independently. The two timers interact: a session
# refused twice has a transcript older than a fixed window, so the next attempt
# would fail freshness and log a misleading cause. Deriving it (4x the longest
# cooldown) means changing one cannot silently break the other.
FRESH_WINDOW="${FRESH_WINDOW_MINUTES:-$(( (COOLDOWN * 4 + 59) / 60 ))}"

# Set by claude-failover so the watcher can refuse a swap that would resume the
# wrong conversation. Unset means a hand-started watcher, which skips the guard
# entirely and behaves as it did before.
EXPECT_CONFIG_DIR="${EXPECT_CONFIG_DIR:-}"
EXPECT_PANE_DIR="${EXPECT_PANE_DIR:-}"

# Absolute path rather than a bare name: the relaunch is typed into the pane's
# shell, so this must not depend on that shell's PATH.
CLAUDE_LOCAL="${CLAUDE_LOCAL_BIN:-$HOME/.local/bin/claude-local}"

# What gets typed into the pane to resume on GLM. claude-failover sets this and
# includes the config dir, which is what makes --continue find the right
# transcript. The bare default below is only reached by a hand-started watcher,
# and relies on claude-local's own default config dir.
#   e.g. RELAUNCH_CMD='CLAUDE_CONFIG_DIR=$HOME/.claude-work claude-local --continue'
RELAUNCH_CMD="${RELAUNCH_CMD:-$CLAUDE_LOCAL --continue}"

LAST_SWAP=0
LAST_REFUSAL=0
REFUSAL_WAIT=0

usage() {
  echo "usage: $0 <tmux-pane-id>   e.g. $0 %3" >&2
  echo "find it: tmux list-panes -a -F '#{pane_id} #{pane_current_command}'" >&2
  exit 1
}

[ -z "$PANE" ] && usage
command -v tmux >/dev/null 2>&1 || { echo "tmux not found" >&2; exit 1; }
[ -x "$CLAUDE_LOCAL" ] || { echo "ERROR: $CLAUDE_LOCAL is not executable" >&2; exit 1; }

mkdir -p "$(dirname -- "$LOG")" 2>/dev/null
if ! touch "$LOG" 2>/dev/null; then
  echo "WARNING: cannot write $LOG — logging to stdout only" >&2
  LOG=/dev/null
fi

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"
}

# The six real-world limit messages documented by claude-auto-retry.
PATTERN='hour limit reached|usage limit reached|out of extra usage|hit your limit|Rate limit hit|Please try again in [0-9]+ hour'

# tmux reuses pane ids across server restarts: kill the server, start a new one,
# and %0/%1 are handed out again. So "the id still exists" is NOT proof it is the
# same pane, and a watcher left over from a previous server will happily attach
# itself to an unrelated new session. Pin the server identity too — if the
# server pid changed, our pane is gone whatever the id says.
TMUX_SERVER_PID="$(tmux display-message -p -t "$PANE" '#{pid}' 2>/dev/null)"

pane_alive() {
  if [ -n "$TMUX_SERVER_PID" ]; then
    local pid
    pid="$(tmux display-message -p '#{pid}' 2>/dev/null)"
    [ "$pid" = "$TMUX_SERVER_PID" ] || return 1
  fi
  tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -qx -- "$PANE"
}

# Only inject keys if Claude Code owns the pane. Prevents typing into vim/bash.
foreground_is_claude() {
  local cmd
  cmd="$(tmux display-message -p -t "$PANE" '#{pane_current_command}' 2>/dev/null)"
  [ "$cmd" = "node" ] || [ "$cmd" = "claude" ]
}

# Returns the visible pane tail with ANSI escapes stripped.
#
# NOTE: this deliberately writes to stdout for capture into a variable rather
# than being piped into `grep -q`. With `set -o pipefail`, grep -q exits as soon
# as it matches, which SIGPIPEs the upstream sed (exit 141) and makes pipefail
# report failure on a *successful* match — silently disabling the whole monitor.
pane_tail() {
  tmux capture-pane -p -t "$PANE" 2>/dev/null \
    | tail -n "$SCAN" \
    | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g'
}

# Wait until Claude Code has actually exited and we are back at a shell prompt.
#
# CRITICAL: without this, a failed /exit leaves Claude Code in the foreground,
# and the follow-up `clear` and `claude-local --continue` get typed into the
# chat input and submitted as prompts — burning quota and corrupting the
# transcript with junk turns.
wait_for_shell() {
  local waited=0
  while [ "$waited" -lt "$EXIT_TIMEOUT" ]; do
    if ! foreground_is_claude; then
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  return 1
}

# Wait for Claude Code to be the foreground process again after a relaunch.
wait_for_session() {
  local waited=0
  while [ "$waited" -lt "$READY_TIMEOUT" ]; do
    if foreground_is_claude; then
      return 0
    fi
    sleep 3
    waited=$((waited + 3))
  done
  return 1
}

_cf_realpath() {
  readlink -f -- "$1" 2>/dev/null || printf '%s' "$1"
}

# Reflect failover state in the status bar, so it is visible for the whole
# session rather than only in a log. Restricted to sessions claude-failover
# created (cf-*): if the user ran this inside their own tmux session, their
# status bar is theirs and we leave it alone.
STATUS_WATCHING="green:black:failover: armed"
LAST_STATUS=""

# Colour the WHOLE bar, not just the right segment. status-right alone leaves
# most of the bar tmux's default green, which reads as "fine" while the right
# hand end says the opposite.
#   arg: "<bg>:<fg>:<text>"
_cf_status() {
  [ "$1" = "$LAST_STATUS" ] && return 0     # skip redundant tmux calls
  local sess bg fg text
  sess="$(tmux display-message -p -t "$PANE" '#{session_name}' 2>/dev/null)"
  case "$sess" in
    cf-*) ;;
    *) return 0 ;;
  esac
  bg="${1%%:*}"
  fg="${1#*:}"; fg="${fg%%:*}"
  text="${1#*:*:}"
  tmux set-option -t "$sess" status-style "bg=$bg,fg=$fg" 2>/dev/null
  tmux set-option -t "$sess" status-right " $text   %H:%M " 2>/dev/null
  LAST_STATUS="$1"
}

# The pane deliberately outlives Claude Code so a swap has somewhere to type the
# relaunch. Once this watcher gives up, that reason is gone and an empty tmux
# session is just clutter — so close it.
#
# ONLY when the shell is sitting idle. After quitting Claude Code the user may
# well be using that shell; if an editor, a build, or any command is running
# there, closing the pane would destroy their work. In that case leave it and
# say so.
close_pane_if_idle() {
  [ "$CLOSE_PANE" = "1" ] || return 0
  local cmd
  cmd="$(tmux display-message -p -t "$PANE" '#{pane_current_command}' 2>/dev/null)"
  case "$cmd" in
    bash|zsh|sh|dash|fish|ksh)
      log "closing pane $PANE — shell is idle"
      # The caller has just turned the status bar red. Without a pause the pane
      # dies in the same instant and the session vanishes with no visible
      # explanation — the change has to last long enough to be read.
      tmux display-message -t "$PANE" -d 2500 \
        "claude-failover: watcher stopped — closing this pane" 2>/dev/null
      sleep "$CLOSE_PANE_DELAY"
      tmux kill-pane -t "$PANE" 2>/dev/null
      ;;
    "")
      : ;;   # pane already gone
    *)
      log "leaving pane $PANE open — '$cmd' is still running there"
      ;;
  esac
}

# Freshness, not name derivation. Deriving the project directory by replacing
# '/' with '-' is lossy — /a/my-project and /a/my/project encode identically —
# and because the result would feed a hard refusal, a collision means every
# swap on that project fails permanently. The session that just hit its limit
# was writing its transcript seconds ago, which is a stronger signal and needs
# no knowledge of the encoding.
_cf_recent_transcript() {
  local dir="$1" window="${2:-30}"   # minutes
  [ -d "$dir/projects" ] || return 1
  find "$dir/projects" -name '*.jsonl' -type f -mmin "-$window" 2>/dev/null \
    | head -1 | grep -q .
}

# Refusals must be visible in the pane, not only in a log the user is not
# reading. display-message targets the status line rather than the input
# buffer, which is why it is safe with Claude Code in the foreground, where
# send-keys would type into the chat.
_cf_notify() {
  tmux display-message -t "$PANE" -d 5000 \
    "claude-failover: refused to swap — $1" 2>/dev/null
}

# Runs BEFORE anything is typed into the pane. The spec placed this immediately
# before the relaunch send-keys, but by that point C-c, /exit and clear have
# already run — refusing there would kill the session and decline to restore
# it. This check is filesystem-only, so it costs nothing to do first.
swap_guard_ok() {
  [ -n "$EXPECT_CONFIG_DIR" ] || return 0

  if ! _cf_recent_transcript "$EXPECT_CONFIG_DIR" "$FRESH_WINDOW"; then
    log "REFUSING SWAP: no transcript written under $EXPECT_CONFIG_DIR in the last ${FRESH_WINDOW}m."
    log "  Resuming would open an EMPTY session. Nothing was typed; your session is untouched."
    log "  Check the active profile with: claude-failover --profile"
    _cf_notify "no recent transcript in $EXPECT_CONFIG_DIR"
    LAST_REFUSAL="$(date +%s)"
    REFUSAL_WAIT="$COOLDOWN"        # cannot self-correct
    return 1
  fi

  if [ -n "$EXPECT_PANE_DIR" ]; then
    local now_dir
    now_dir="$(tmux display-message -p -t "$PANE" '#{pane_current_path}' 2>/dev/null)"
    # Compare resolved paths, or a symlinked project dir refuses spuriously.
    if [ "$(_cf_realpath "$now_dir")" != "$(_cf_realpath "$EXPECT_PANE_DIR")" ]; then
      log "REFUSING SWAP: working directory changed since session start."
      log "  was: $EXPECT_PANE_DIR"
      log "  now: $now_dir"
      log "  --continue is directory-scoped and would resume a different conversation."
      log "  cd back and the next attempt will proceed."
      _cf_notify "working directory changed — cd back to $EXPECT_PANE_DIR"
      LAST_REFUSAL="$(date +%s)"
      REFUSAL_WAIT="$WD_COOLDOWN"   # self-correcting, so throttle briefly
      return 1
    fi
  fi

  return 0
}

# Claude Code asks whether to use the ANTHROPIC_API_KEY that claude-local sets,
# and stores the answer per config dir — so the first swap under a NEW profile
# stops here, with the session otherwise healthy.
#
# This answers it, but only while that exact prompt is on screen. It is not a
# blind keypress: the highlighted default is "No (recommended)", which would
# decline the proxy and leave the session unusable. Selecting "1" is the
# verified Yes. If the prompt never appears (profile already approved) this
# costs a few seconds and does nothing.
# Whole visible pane, not just the tail. After a relaunch the screen has been
# cleared, so a freshly-drawn prompt sits at the TOP with blank lines beneath —
# pane_tail's `tail -n $SCAN` would discard it entirely.
pane_full() {
  tmux capture-pane -p -t "$PANE" 2>/dev/null \
    | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g'
}

_cf_answer_key_prompt() {
  local waited=0 tail_text
  # wait_for_session returns as soon as the process name is "claude", which is
  # several seconds before the UI renders — so this must outlast that gap. It
  # exits early either way: on the prompt, or once the normal UI is up.
  while [ "$waited" -lt "$KEY_PROMPT_TIMEOUT" ]; do
    tail_text="$(pane_full)"

    # Normal input bar is showing, so no modal is up. Checked FIRST and on its
    # own: --continue replays the transcript, so a conversation that merely
    # discussed this prompt can put its text back on screen. In that case the
    # input bar is also present, and typing "1" would send a chat message.
    # A real modal hides the input bar, so these are mutually exclusive.
    # Status-line text varies with configuration — a custom statusline can omit
    # "for shortcuts" entirely — so match a few known variants. A missed match
    # only costs the remaining timeout; it never causes a wrong keystroke.
    if grep -qE 'for shortcuts|manual mode|esc to interrupt' <<< "$tail_text"; then
      return 0
    fi

    # Require the modal's footer as well as its title. Both must be present,
    # so quoted prose about the prompt cannot trigger it on its own.
    if grep -q 'Detected a custom API key' <<< "$tail_text" && \
       grep -q 'Enter to confirm' <<< "$tail_text"; then
      log "answering one-time API key approval for this profile (selecting Yes)"
      tmux send-keys -t "$PANE" '1'
      sleep 1
      tmux send-keys -t "$PANE" Enter
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  return 0
}

swap_to_glm() {
  if ! swap_guard_ok; then
    return 1
  fi

  log "usage limit detected — swapping to GLM-5.2"

  # Ctrl-C first: after a limit error the input line may hold a partial prompt
  # or be in a confirmation state, in which case a bare /exit is just typed text.
  tmux send-keys -t "$PANE" C-c
  sleep 1
  tmux send-keys -t "$PANE" '/exit' Enter
  sleep "$SETTLE"

  # Abort rather than risk typing shell commands into a live chat prompt.
  if ! wait_for_shell; then
    log "ERROR: Claude Code did not exit within ${EXIT_TIMEOUT}s — aborting swap."
    log "Nothing was typed into the session. Exit it manually, then run:"
    log "  claude-local --continue"
    return 1
  fi

  # Clear both the visible pane and tmux's scrollback, so the limit notice
  # cannot re-trigger detection on the next poll.
  tmux send-keys -t "$PANE" 'clear' Enter
  tmux clear-history -t "$PANE" 2>/dev/null
  sleep 1

  # --continue loads the most recent session for the pane's current directory,
  # so this must run from the folder the session started in. RELAUNCH_CMD also
  # carries any CLAUDE_CONFIG_DIR the original session was started with.
  tmux send-keys -t "$PANE" "$RELAUNCH_CMD" Enter

  if wait_for_session; then
    _cf_answer_key_prompt
    LAST_SWAP="$(date +%s)"
    STATUS_WATCHING="colour33:white:failover: on GLM-5.2"
    _cf_status "$STATUS_WATCHING"
    log "relaunched via claude-local --continue — now on GLM-5.2"
    log "when your limit resets, exit and resume with your normal launcher + --continue"
    return 0
  fi

  log "ERROR: session did not come back up within ${READY_TIMEOUT}s."
  log "Check the pane manually. Common causes: claude-local not on PATH,"
  log "NVIDIA_API_KEY unset, or the LiteLLM proxy failing to start."
  # Do not set LAST_SWAP — leave the monitor free to retry.
  return 1
}

log "watching pane $PANE (poll ${POLL}s, scan ${SCAN} lines, cooldown ${COOLDOWN}s, idle-exit ${IDLE_EXIT}s)"
log "relaunch command: $RELAUNCH_CMD"
if [ -n "$EXPECT_CONFIG_DIR" ]; then
  log "guard: config dir $EXPECT_CONFIG_DIR, pane dir ${EXPECT_PANE_DIR:-<unset>}, freshness ${FRESH_WINDOW}m"
else
  log "guard: disabled (EXPECT_CONFIG_DIR unset — hand-started watcher)"
fi
log "logging to $LOG"

trap '_cf_status "red:white:failover: off"; log "monitor stopped"; exit 0' INT TERM

IDLE=0

while true; do
  if ! pane_alive; then
    log "pane $PANE is gone — exiting"
    exit 0
  fi

  # The pane deliberately outlives Claude Code — it runs a shell so the swap
  # has somewhere to type the relaunch — so pane death alone never fires on a
  # normal /exit or Ctrl-C. Without this the watcher would survive every clean
  # exit forever, and a stale watcher blocks a new one on the same pane,
  # leaving a later session silently unwatched.
  #
  # While Claude is gone there is nothing to detect and a swap is impossible,
  # so this branch ticks once a SECOND rather than once per POLL. The detection
  # rate only matters while Claude is actually running, and a countdown that
  # jumps five seconds at a time reads as broken.
  if ! foreground_is_claude; then
    IDLE=$((IDLE + 1))
    if [ "$IDLE_EXIT" -gt 0 ]; then
      if [ "$IDLE" -ge "$IDLE_EXIT" ]; then
        log "Claude Code gone for ${IDLE}s — exiting"
        _cf_status "red:white:failover: off"
        close_pane_if_idle
        exit 0
      fi
      REMAINING=$((IDLE_EXIT - IDLE))
      # Yellow while there is still time to come back, red only once it is
      # nearly gone. A countdown that is red throughout is just noise.
      if [ "$REMAINING" -le "$FINAL_WARN" ]; then
        _cf_status "red:white:failover: stopping in ${REMAINING}s"
      else
        _cf_status "colour226:black:failover: stopping in ${REMAINING}s"
      fi
      sleep 1
    else
      sleep "$POLL"          # no idle exit configured: nothing to count down
    fi
    continue
  fi

  # Claude Code is running in the pane.
  IDLE=0
  # Restore whichever "watching" state applies. After a swap that is the GLM
  # one, not the original.
  _cf_status "$STATUS_WATCHING"

  now="$(date +%s)"
  if [ $((now - LAST_SWAP)) -ge "$COOLDOWN" ] && \
     [ $((now - LAST_REFUSAL)) -ge "$REFUSAL_WAIT" ]; then
    tail_text="$(pane_tail)"
    if grep -Eqi -- "$PATTERN" <<< "$tail_text"; then
      swap_to_glm
      # swap_to_glm runs synchronously, so no polling happens while Claude is
      # intentionally absent. Reset so a slow swap cannot trip the idle exit.
      IDLE=0
    fi
  fi

  # Sleep in one-second slices, breaking out as soon as Claude Code leaves the
  # foreground. Otherwise an exit is not noticed until the current POLL
  # interval ends, and the bar sits on "armed" for up to POLL seconds after the
  # session is already gone. The pane is still only scanned once per POLL --
  # this just costs one cheap foreground check per second.
  slept=0
  while [ "$slept" -lt "$POLL" ]; do
    sleep 1
    slept=$((slept + 1))
    foreground_is_claude || break
  done
done
