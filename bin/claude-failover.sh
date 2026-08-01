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
# LOCAL NOTES (this machine):
#   * Start the watched session with `claude-personal`, NOT plain `claude`.
#     Plain `claude` is aliased to a reminder message here and starts nothing.
#   * `claude-personal` and `claude-local` both use CLAUDE_CONFIG_DIR=
#     $HOME/.claude-personal, so they share a session store and --continue
#     resolves correctly across the swap. A session started with `claude-work`
#     will NOT be found by claude-local.
#   * Verified on tmux 3.6: pane_current_command reports "claude" for the
#     native-installer binary, so foreground_is_claude() works unmodified.

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
LOG="${LOG_FILE:-$HOME/.claude-failover.log}"

# Absolute path rather than a bare name (Part 2, Failure Mode D). claude-local
# is a real executable on PATH here, so the bare name would resolve — but the
# absolute path removes any dependence on the pane shell's PATH.
CLAUDE_LOCAL="$HOME/.local/bin/claude-local"

# What gets typed into the pane to resume on GLM. Override this if your Claude
# Code session uses a non-default CLAUDE_CONFIG_DIR — otherwise --continue looks
# in ~/.claude, finds no matching transcript, and opens an EMPTY session.
#   e.g. RELAUNCH_CMD='CLAUDE_CONFIG_DIR=$HOME/.claude-personal claude-local --continue'
#
# NOTE (this machine): claude-local already exports
# CLAUDE_CONFIG_DIR=$HOME/.claude-personal internally, so the bare default is
# not actually broken here. Setting it explicitly removes the dependence on
# that launcher internal, which is the point of the override.
RELAUNCH_CMD="${RELAUNCH_CMD:-$CLAUDE_LOCAL --continue}"

LAST_SWAP=0

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

pane_alive() {
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

swap_to_glm() {
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
    LAST_SWAP="$(date +%s)"
    log "relaunched via claude-local --continue — now on GLM-5.2"
    log "when your limit resets, exit and run: claude-personal --continue"
    return 0
  fi

  log "ERROR: session did not come back up within ${READY_TIMEOUT}s."
  log "Check the pane manually. Common causes: claude-local not on PATH,"
  log "NVIDIA_API_KEY unset, or the LiteLLM proxy failing to start."
  # Do not set LAST_SWAP — leave the monitor free to retry.
  return 1
}

log "watching pane $PANE (poll ${POLL}s, scan ${SCAN} lines, cooldown ${COOLDOWN}s)"
log "relaunch command: $RELAUNCH_CMD"
log "logging to $LOG"

trap 'log "monitor stopped"; exit 0' INT TERM

while true; do
  if ! pane_alive; then
    log "pane $PANE is gone — exiting"
    exit 0
  fi

  now="$(date +%s)"
  if [ $((now - LAST_SWAP)) -ge "$COOLDOWN" ]; then
    tail_text="$(pane_tail)"
    if grep -Eqi -- "$PATTERN" <<< "$tail_text"; then
      if foreground_is_claude; then
        swap_to_glm
      else
        log "limit text seen but Claude is not the foreground process — skipping"
      fi
    fi
  fi

  sleep "$POLL"
done
