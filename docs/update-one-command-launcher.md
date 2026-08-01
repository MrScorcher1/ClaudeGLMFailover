# UPDATE — apply to an existing GLM-5.2 / claude-local setup

This is a change-set, not a fresh install. It assumes a working setup and modifies it in place.

**Two things are being fixed or added:**

1. **A silent data-loss bug in the watcher.** It relaunched with a bare `claude-local --continue`, which reads `~/.claude/projects/`. Sessions started with a non-default `CLAUDE_CONFIG_DIR` store transcripts elsewhere, so the resume finds nothing and opens an **empty session** — no error, conversation gone.
2. **A new command, `claude-personal-failover`**, that starts the tmux session and the watcher together, so neither has to be done by hand.

---

## Preconditions

Verify all four before changing anything. If any fails, **stop and report** — do not attempt the update against a partial setup.

```bash
claude-local --version                          # Part 1 working
test -x "$HOME/claude-failover.sh" && echo OK   # watcher present and executable
tmux -V                                         # 2.1 or newer
type claude-personal                            # must report an alias, function, or file
```

Record what `type claude-personal` prints. Edit 3 depends on it.

---

## Idempotency

This update may already be partly applied. Check first and skip anything already done. **Do not apply an edit twice.**

```bash
grep -q 'RELAUNCH_CMD' "$HOME/claude-failover.sh" && echo "EDIT 1+2: already applied"
grep -q 'claude-personal-failover()' "$HOME/.zshrc" "$HOME/.bashrc" 2>/dev/null && echo "EDIT 3: already applied"
```

If both report applied, run the Gates and report — there is nothing to change.

---

## Edit 1 — add `RELAUNCH_CMD` to the watcher

**File:** `~/claude-failover.sh`

**Find this line** (it is the last of the config block, around line 26):

```
LOG="${LOG_FILE:-$HOME/.claude-failover.log}"
```

**Insert immediately after it:**

```bash

# What gets typed into the pane to resume on GLM. Override this if your Claude
# Code session uses a non-default CLAUDE_CONFIG_DIR — otherwise --continue looks
# in ~/.claude, finds no matching transcript, and opens an EMPTY session.
#   e.g. RELAUNCH_CMD='CLAUDE_CONFIG_DIR=$HOME/.claude-personal claude-local --continue'
RELAUNCH_CMD="${RELAUNCH_CMD:-claude-local --continue}"
```

---

## Edit 2 — use it in the swap

**File:** `~/claude-failover.sh`

**Find**, inside `swap_to_glm()`:

```bash
  # --continue loads the most recent session for the pane's current directory,
  # so this must run from the folder the session started in.
  tmux send-keys -t "$PANE" 'claude-local --continue' Enter
```

**Replace with:**

```bash
  # --continue loads the most recent session for the pane's current directory,
  # so this must run from the folder the session started in. RELAUNCH_CMD also
  # carries any CLAUDE_CONFIG_DIR the original session was started with.
  tmux send-keys -t "$PANE" "$RELAUNCH_CMD" Enter
```

**Then find:**

```bash
log "watching pane $PANE (poll ${POLL}s, scan ${SCAN} lines, cooldown ${COOLDOWN}s)"
```

**Add directly beneath it:**

```bash
log "relaunch command: $RELAUNCH_CMD"
```

This log line is the only way to confirm the fix is live, and Gate 2 depends on it.

**Finally**, if this line is present, update it — the old text hardcodes a launcher that may not be the user's:

```bash
    log "when your limit resets, exit and run: claude --continue"
```

to:

```bash
    log "when your limit resets, exit and resume with your normal launcher + --continue"
```

**Verify:** `bash -n ~/claude-failover.sh` exits clean.

---

## Edit 3 — add the launcher function

**File:** `~/.zshrc` on macOS, `~/.bashrc` on most Linux. Append at the bottom.

**Before pasting, reconcile two values with what `type claude-personal` reported.** The block below assumes the alias expands to `CLAUDE_CONFIG_DIR=$HOME/.claude-personal command claude`. If it differs:

- `CPF_BASE_CMD` must equal the alias's **expansion**, never the alias name — bash does not expand aliases inside function bodies.
- `CPF_CONFIG_DIR` must equal the `CLAUDE_CONFIG_DIR` value in that expansion. If the alias sets no config dir, set `CPF_CONFIG_DIR="$HOME/.claude"`.

These two must agree. A mismatch is the exact bug this update exists to fix.

```bash
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
    echo "  fix: chmod +x $watcher" >&2
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
  RELAUNCH_CMD="CLAUDE_CONFIG_DIR=$CPF_CONFIG_DIR claude-local --continue" \
    nohup "$HOME/claude-failover.sh" "$pane" >/dev/null 2>&1 &
  disown 2>/dev/null
}
# ---------------------------------------------------------------------------
```

Then reload: `source ~/.zshrc` (or `~/.bashrc`).

---

## Gates

Blocking. Do not proceed past a failure — go to the referenced failure mode.

**Gate 1 — syntax.** `bash -n ~/claude-failover.sh` exits 0. `type claude-personal-failover` reports a shell function. If the second fails, see Failure Mode C.

**Gate 2 — the fix is live.** Start a session with `claude-personal-failover`, then:

```bash
grep "relaunch command" ~/.claude-failover.log
```

It must show the config dir, e.g. `CLAUDE_CONFIG_DIR=/Users/you/.claude-personal claude-local --continue`. If it shows only `claude-local --continue`, the function is not passing `RELAUNCH_CMD` — see Failure Mode A.

**Gate 3 — transcripts are where assumed.** From inside that session, send one message, exit, then:

```bash
ls -t "$CPF_CONFIG_DIR"/projects/*/*.jsonl 2>/dev/null | head -1
```

A recent file must appear. If it is empty but `~/.claude/projects/` has a new file, `CPF_CONFIG_DIR` is wrong — see Failure Mode B.

**Gate 4 — nothing else broke.** `type claude` and `type claude-personal` report exactly what they did before this update. This update adds a name; it must not shadow anything.

**Gate 5 — the swap (human, deferred).** Only closeable at a real limit event. When it fires, confirm the relaunched session **contains the prior conversation**. An empty session that otherwise works is Failure Mode B.

---

## Failure Modes

### A — Log shows the relaunch command without a config dir
**Cause:** `_cpf_start_watcher` is not exporting `RELAUNCH_CMD`, or the watcher was started by hand rather than through the function.
**Fix:** Confirm the `RELAUNCH_CMD=... nohup ...` line in `_cpf_start_watcher` is intact, including the trailing backslash continuation. Restart the session so a fresh watcher picks it up — an already-running watcher keeps its old value.

### B — Session resumes empty
**Symptom:** The swap runs cleanly and the conversation is gone. No error.
**Cause:** `CPF_CONFIG_DIR` does not match where transcripts actually live.
**Fix:** Find the real location — `ls -td ~/.claude*/projects 2>/dev/null` — set `CPF_CONFIG_DIR` to the directory containing `projects/`, reload the shell, and start a new session. Existing watchers must be restarted.

### C — `claude-personal-failover` not found after reload
**Cause:** Either the rc file was not re-sourced, or the shell rejected the hyphens in the function name.
**Fix:** Open a new terminal first. If still absent, rename the function to `claude_personal_failover` and add `alias claude-personal-failover='claude_personal_failover'` **after** the definition.

### D — Guard rejects a valid `CPF_BASE_CMD`
**Symptom:** "does not resolve here", even though the command works when typed.
**Cause:** The guard skips leading `VAR=value` tokens to find the command word. An unusual form may confuse it.
**Fix:** Prefix the command with `command`, e.g. `CPF_BASE_CMD="CLAUDE_CONFIG_DIR=$HOME/.claude-personal command claude"`. The guard skips its check when the resolved word is `command`.

### E — Watcher was already running from before the update
**Symptom:** Gate 2 passes for new sessions but an existing session still swaps wrongly.
**Cause:** A running watcher holds the `RELAUNCH_CMD` from when it started.
**Fix:** `pkill -f claude-failover`, then start a fresh session.

---

## Rollback

Fully reversible.

1. Remove the block between the `# --- claude-personal-failover` markers from the rc file.
2. In `~/claude-failover.sh`, revert Edits 1 and 2 — delete the `RELAUNCH_CMD` declaration and the `relaunch command` log line, and set the send-keys line back to `tmux send-keys -t "$PANE" 'claude-local --continue' Enter`.
3. Open a new terminal.

`claude`, `claude-personal`, and `claude-local` are untouched throughout.

---

## Final report

1. Which edits were applied versus already present (per the idempotency check).
2. The exact output of `type claude-personal`, and the `CPF_BASE_CMD` / `CPF_CONFIG_DIR` values chosen from it.
3. Pass/fail for Gates 1–4.
4. The `grep "relaunch command"` line, quoted verbatim.
5. Confirmation that Gate 5 is outstanding and the setup is provisional until a real limit event closes it.
