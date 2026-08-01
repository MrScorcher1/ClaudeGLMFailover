# Spec — Explicit profile selection for `claude-failover`

Replaces the runtime-detection plan. The architecture changed: detection is dropped in favour of an explicit, persisted profile.

---

## Why the change

The detection design inferred profiles from a `~/.claude*` glob, a scan of shell startup files, and a content grep of `PATH`. It worked, but every layer was inference, each carried its own failure mode, and the coverage table had permanent holes — a config dir outside `$HOME` with no launcher referencing it could not be found by any layer, and fish users lost the launcher layer entirely.

Explicit selection removes the problem rather than covering more of it. The user states which profile they want once; the tool remembers. This deletes the menu, TTY handling, decoy filtering, interactive-shell probing, the `PATH` grep, and the shell-compatibility problem — most of the previous plan's complexity and nearly all of its failure modes.

**What replaces detection is verification.** The tool no longer guesses which directory you meant, but it must still confirm the directory you named is a real Claude Code config dir. That check is the safety property this spec is built around.

---

## Behaviour

```
claude-failover                       # use the saved profile, or ~/.claude if none saved
claude-failover --profile work        # switch to ~/.claude-work, save it, launch
claude-failover --profile /opt/cfg    # absolute path, save it, launch
claude-failover --profile             # print the saved profile and exit
claude-failover --profile <x> --force # skip the classifier check
```

No menu. No prompt. The saved profile persists until `--profile` names a different one.

**Every launch prints the active profile**, e.g. `claude-failover: profile 'work' (/home/you/.claude-work)`. Persisted state that is never displayed is as opaque as silent detection; the difference is that this state was chosen deliberately, and printing it makes a wrong choice visible immediately.

---

## The safety property

**A config dir that is not a real Claude Code profile must never be launched into silently.**

This is not hypothetical. On the development machine `~/.claude` exists and is empty, while the real profiles are `~/.claude-personal` and `~/.claude-work`. A bare `claude-failover` defaulting to `~/.claude` unconditionally would open a session in an unused directory, look completely normal, and quietly diverge from where the user's work lives.

The classifier in Task 2 is what prevents this. **If it does not refuse, this spec has no safety value.**

---

## Task 1 — profile resolution

Resolution is a convention, not a lookup. There is no registry, and nothing is enumerated.

| Input | Resolves to |
|---|---|
| absolute path (`/opt/cfg`) | itself |
| `default` or `claude` | `$HOME/.claude` |
| any other name `X` | `$HOME/.claude-X` |

Reject names containing `/`, whitespace, or a leading `-`, so a mistyped flag cannot be read as a profile name. Report the resolved absolute path in the error when a name fails to resolve, so the convention is discoverable from the failure.

---

## Task 2 — the classifier

Runs before launch, on both a `--profile` argument and the saved default. Filesystem only: no session, no quota, no network.

**Three outcomes, not two.** A binary valid/invalid check would reject a legitimately new profile, which is a real workflow.

| Result | Meaning | Action |
|---|---|---|
| `USED` | Sessions have run here | proceed |
| `CONFIGURED` | Real config dir, no sessions yet | proceed, warn that failover cannot fire until a transcript exists |
| `EMPTY` | No evidence this is a Claude Code config dir | refuse |
| `MISSING` | Path does not exist | refuse |

```bash
# Markers proving sessions have actually run.
_CF_USE_MARKERS=( "projects" "history.jsonl" )
# Markers proving deliberate configuration, even with no sessions yet.
_CF_CONF_MARKERS=( "settings.json" "CLAUDE.md" "commands" "agents" "plugins" )

_cf_classify() {
  local d="$1"
  [ -d "$d" ] || { echo "MISSING"; return 3; }

  # Tier 1 — real transcripts anywhere under projects/
  if [ -d "$d/projects" ] && \
     find "$d/projects" -name '*.jsonl' -type f 2>/dev/null | head -1 | grep -q .; then
    echo "USED"; return 0
  fi
  # Tier 1b — non-empty history
  if [ -s "$d/history.jsonl" ]; then echo "USED"; return 0; fi

  # Tier 2 — deliberate configuration
  local m
  for m in "${_CF_CONF_MARKERS[@]}"; do
    if [ -s "$d/$m" ] || { [ -d "$d/$m" ] && [ -n "$(ls -A "$d/$m" 2>/dev/null)" ]; }; then
      echo "CONFIGURED"; return 1
    fi
  done

  echo "EMPTY"; return 2
}
```

**Three deliberate choices in this logic:**

- **Incidental markers do not count.** `.credentials.json`, `statsig/`, and `todos/` appear on any launch attempt, including one that failed immediately. Counting them would classify the empty `~/.claude` as real, which is the exact case this exists to catch.
- **`-s` rather than `-f`, and emptiness checks on directories.** A zero-byte `settings.json` and an empty `projects/` both prove nothing. This is the difference between this and a mere existence test.
- **`--force` exists** so the classifier is a guard, not a wall. Log loudly when it is used.

**Calibration is required before this is trusted.** The marker list is inferred from observed Claude Code behaviour, not from documentation, and may be wrong or may change between versions. Run it against all three known directories:

```bash
for d in "$HOME/.claude" "$HOME/.claude-personal" "$HOME/.claude-work"; do
  printf '%-30s ' "$d"; _cf_classify "$d"
done
```

Expected: `EMPTY`, `USED`, `USED`. Any other result means the marker set does not match reality and must be adjusted before shipping. This is Gate 1 and it blocks.

---

## Task 3 — persistence

State lives at `${XDG_CONFIG_HOME:-$HOME/.config}/claude-failover/profile`, holding one line: the resolved absolute path.

- **Write atomically** — temp file plus `mv` — so an interrupted write cannot leave a truncated path that resolves to something unintended.
- **Persist after the classifier passes, before the tmux session is created.** The user's intent is expressed by then, and a launch that fails afterwards should not silently revert the profile.
- **Validate on read.** A saved path can go stale if the directory is moved or deleted. Re-run the classifier at every launch, not only when `--profile` is passed. `MISSING` on a saved profile must name the saved path in the error and tell the user to set a new one.
- **Last write wins** across concurrent terminals. Acceptable, but state it, because two terminals switching profiles at once will surprise someone.

---

## Task 4 — optional per-profile arguments

Without a launcher layer, the launch command is synthesized as `CLAUDE_CONFIG_DIR=<dir> command claude`, which silently drops any flags a user's own launcher would carry — `--plugin-dir`, `--mcp-config`, `--add-dir`.

Support one optional file per profile: `${XDG_CONFIG_HOME:-$HOME/.config}/claude-failover/args/<name>`, whose contents are appended to the launch command. Use a file per profile rather than variables keyed by name, since profile names may contain hyphens and would need escaping.

Absent file means no extra arguments, which is the common case. **Whatever is appended here must also be appended to the watcher's `RELAUNCH_CMD`**, or the flags are present before a swap and absent after it — the same class of asymmetry as the config dir itself.

**The contents of this file are typed into a shell**, because the detached branch builds a command string and sends it to the pane with `tmux send-keys`. A file containing `; rm -rf ~` would run. This is the user's own file on their own machine, so it is not a privilege boundary — but it becomes one the moment someone copies an args file from a README, a gist, or a teammate, which is exactly what a public repo invites.

Treat it as a bounded format rather than a command fragment:

- Read only the first line; ignore anything after it and blank or `#`-prefixed lines.
- Reject the file, with the offending character named, if it contains `;`, `|`, `&`, backtick, `$(`, `<`, `>`, or a newline mid-content.
- Apply `printf '%q'` per token when appending, exactly as user arguments are already quoted in Task 5.

Document that this file holds flags, not shell.

---

## Task 5 — `claude-failover` function

Retains everything already verified in `claude-personal-failover`: the `$TMUX` branch versus the detached-session branch, the requirement that the pane runs a shell rather than Claude directly, per-argument `printf '%q'` quoting, and the `-p`/`--print` rejection.

Changes only where the config dir comes from: resolution and the saved profile, rather than `CPF_BASE_CMD` and `CPF_CONFIG_DIR`.

**Ordering is load-bearing:**

```
parse args
  └─ --profile with no value → print saved profile → exit 0, launch nothing
resolve name → absolute path
classify
  └─ EMPTY or MISSING, and --force absent → refuse → exit non-zero, launch nothing
  └─ EMPTY or MISSING, and --force present → log the override loudly → continue
  └─ CONFIGURED → warn that failover cannot fire until a transcript exists → continue
persist (atomic)
print active profile
create tmux session
start watcher
```

Two properties follow from this order, and both are worth stating because they are easy to break:

- **Every exit path that refuses runs before any session or watcher exists**, so a refusal or an abort leaves nothing behind — no tmux session, no orphaned watcher, no partial state.
- **`--profile` with no value never launches and never persists.** It is a query, not a switch. Placing it anywhere later in the chain would make an inspection command mutate state.

`_cf_start_watcher` passes the resolved directory to the watcher as `EXPECT_CONFIG_DIR`, alongside `RELAUNCH_CMD` and the new `EXPECT_PANE_DIR` (Task 7).

**Rename the session prefix** from `cpf-` to `cf-`, and update anything matching on it.

---

## Task 6 — pre-swap freshness guard

In `swap_to_glm`, immediately before the `tmux send-keys "$RELAUNCH_CMD"` line.

**Do not derive the project directory name from the path.** The encoding — replacing `/` with `-` — is lossy and undocumented:

```
/home/you/my-project   ->  -home-you-my-project
/home/you/my/project   ->  -home-you-my-project
```

Two distinct projects, one encoded name. A rule verified against two paths containing no hyphens cannot detect this. Because the derived name feeds a hard refusal, a wrong encoding means *every* swap fails permanently on that project, with the only signal in a log file — trading silent data loss for silent total failure.

**Check freshness instead.** The session that just hit its limit was writing its transcript seconds ago, which is a stronger signal than a reconstructed filename and needs no knowledge of the encoding:

```bash
_cf_recent_transcript() {
  local dir="$1" window="${2:-30}"   # minutes
  [ -d "$dir/projects" ] || return 1
  find "$dir/projects" -name '*.jsonl' -type f -mmin "-$window" 2>/dev/null \
    | head -1 | grep -q .
}
```

Name derivation may be kept as a *secondary* signal that can never veto alone. If freshness passes and name-matching fails, proceed and log the discrepancy — that combination means the encoding rule is wrong, which is exactly what should be reported rather than enforced.

Skip the check entirely when `EXPECT_CONFIG_DIR` is unset, so a hand-started watcher behaves as it does today.

**On the window value:** thirty minutes is a starting point, not a verified figure. The real gap should be seconds. See Task 8 for how it must relate to the refusal cooldown.

---

## Task 7 — working-directory guard

The freshness check confirms *a* transcript is being written; it does not confirm it is the *right* one. If the user `cd`s mid-session, `--continue` is directory-scoped and would resume a different conversation — one that legitimately exists, so freshness passes.

Record the pane's directory when the watcher starts:

```bash
EXPECT_PANE_DIR="$(tmux display-message -p -t "$pane" '#{pane_current_path}')"
```

Compare at swap time. **Compare resolved paths**, not raw strings, or a symlinked project directory produces a spurious refusal.

On mismatch, refuse with a message naming this specific cause — "working directory changed since session start; `--continue` would resume a different conversation" — because the remedy differs from the config-dir case. The user should `cd` back and retry.

---

## Task 8 — refusal must be visible, and throttled by cause

**Visible.** On refusal the guard currently logs and returns, leaving the user at a rate-limited session believing failover is armed. The guard's purpose is converting a silent failure into a loud one; as written it converts silent data loss into silent inaction.

```bash
tmux display-message -t "$PANE" -d 5000 \
  "claude-failover: refused to swap — <specific reason>"
```

`display-message` targets the status line rather than the input buffer, which is why it is safe with Claude Code in the foreground where `send-keys` would type into the chat. **Confirm this on a real terminal before relying on it** — it is untested, and a message landing in the chat input would be worse than none.

**Throttled by cause.** The original set `LAST_SWAP` on every refusal, justified by the condition being unable to self-correct. That stops holding once Task 7 exists: the working-directory case *can* self-correct, and a uniform fifteen-minute throttle would ignore the fix for up to fifteen minutes after the user applies it.

- Config-dir mismatch and `EMPTY`/`MISSING`: full cooldown. Cannot self-correct.
- Working-directory mismatch: short cooldown, around sixty seconds. Enough to avoid log spam, short enough that a `cd` takes effect on the next poll.

**The two timers interact.** With a fifteen-minute throttle and a thirty-minute freshness window, a twice-refused session has a transcript older than the window, so the third attempt fails *freshness* and logs a misleading cause. Derive the window from the longest cooldown — at least four times — rather than fixing both independently, and document the relationship so changing one cannot silently break the other.

---

## Task 9 — keep the old command working

`claude-personal-failover` is replaced by `claude-failover`. Removing a working command with no notice is a regression for the only current user.

```bash
claude-personal-failover() {
  echo "claude-personal-failover is now 'claude-failover' — this name will be removed." >&2
  claude-failover "$@"
}
```

Remove the old block fully — no orphaned `CPF_BASE_CMD` or `CPF_CONFIG_DIR` left behind, since a stale definition does nothing and misleads anyone reading the file.

---

## Files

| File | Change |
|---|---|
| `~/.bashrc` | replace the `# --- claude-personal-failover` block with the new one plus the shim |
| `~/claude-failover.sh` | add the freshness guard, the working-directory guard, and cause-based throttling |
| `~/ClaudeGLMFailover/bin/claude-failover.sh` | sync |
| `~/ClaudeGLMFailover/shell/claude-personal-failover.bash` | `git mv` to `shell/claude-failover.bash`, new contents |
| `~/ClaudeGLMFailover/README.md` | document `--profile`, the convention, the classifier's three outcomes, `--force`, and the guards; remove the `CPF_BASE_CMD`/`CPF_CONFIG_DIR` reconciliation section |

Back up `~/.bashrc` and `~/claude-failover.sh` first, using new suffixed names rather than overwriting the existing `.bak-cpf` and `.bak` files from prior rounds. Commit before starting, so `git checkout -- .` covers the tracked files.

---

## Verification

Blocking items marked **[B]**.

1. **[B]** Classifier calibration: `~/.claude` → `EMPTY`, `~/.claude-personal` → `USED`, `~/.claude-work` → `USED`. Any deviation means the marker set is wrong and blocks everything downstream.
2. **[B]** Bare `claude-failover` with no saved profile refuses, naming `~/.claude` and pointing at `--profile`. It must not launch.
3. `--profile work` launches under `~/.claude-work` and prints the active profile.
4. Persistence: a subsequent bare `claude-failover` uses `~/.claude-work` without being told again.
5. `--profile` with no argument prints the saved profile and exits without launching.
6. `--profile /absolute/path` is accepted; `--profile ../x`, `--profile "a b"`, and `--profile -x` are rejected.
7. Stale saved profile: delete the saved directory, run bare, confirm a `MISSING` refusal naming the saved path.
8. `--force` overrides an `EMPTY` classification and logs that it was used.
9. `CONFIGURED` case: a directory with only a populated `settings.json` launches, with a warning that failover cannot fire until a transcript exists.
10. **[B]** Guard negative: watcher with `EXPECT_CONFIG_DIR` pointed at the wrong profile refuses, logs, leaves the pane untouched, and shows a status-line message.
11. Guard positive: correct dir, swap completes, resumed session answers a context-dependent question.
12. **[B]** Guard passes for a project path containing a hyphen — the case the old encoding rule could not handle.
13. `cd` away, trigger detection, confirm refusal names the working-directory cause; `cd` back and confirm the next swap succeeds within about a minute rather than waiting out the full cooldown.
14. Symlinked project directory does not produce a spurious refusal.
15. Per-profile args file: flags present in the initial session are still present after a swap.
16. **[B]** Watcher regressions: `bash -n` clean; `^IDLE=0$`, `IDLE_EXIT" -gt 0`, and `while true; do` each exactly 1.
17. Watcher still self-exits about 120s after Claude Code exits.
18. `type claude`, `type claude-personal`, `type claude-work` unchanged; `claude-failover` defined; `claude-personal-failover` forwards with a deprecation notice.
19. Atomic write: interrupt a profile switch and confirm the state file is either the old value or the new one, never truncated.
20. **[B]** Refusal leaves nothing behind: force an `EMPTY` refusal and confirm no tmux session exists, no watcher process is running, and the saved profile is unchanged.
21. `--profile` with no value neither launches nor persists: run it, then confirm the saved profile and `tmux ls` are both unchanged.
22. **[B]** Args file rejection: place `--plugin-dir /x; touch /tmp/pwned` in an args file, launch, and confirm the file is rejected naming `;` and that `/tmp/pwned` does not exist.

Then sync to the repo, rerun the staged-diff secret scan, commit, and push.

---

## Failure Modes

### A — Classifier rejects a real profile
**Cause:** The marker set does not match this Claude Code version's layout.
**Fix:** Run the calibration loop and compare against a directory known to work. Adjust `_CF_CONF_MARKERS`. Use `--force` as a stopgap, but treat a calibration failure as a blocker for anyone else installing this — it means the check is wrong for everyone, not just here.

### B — Classifier accepts a decoy
**Symptom:** A bare directory classifies as `CONFIGURED` or `USED`.
**Cause:** An incidental marker was added to the tier-2 list, or an existence test replaced an emptiness test.
**Fix:** Confirm `-s` is used for files and non-empty checks for directories, and that `.credentials.json`, `statsig/`, and `todos/` appear in neither list.

### C — Saved profile points somewhere stale
**Symptom:** `MISSING` refusal on a bare launch.
**Cause:** The directory was moved or deleted after being saved.
**Fix:** Correct behaviour. Set a new one with `--profile`. The error must name the saved path, or the user cannot tell which value is stale.

### D — Guard refuses a legitimate swap
**Cause:** Freshness window too short, clock skew, or a slow or network-mounted config dir.
**Fix:** Check the window before suspecting the config dir. See Task 8 for the relationship with the cooldown; a twice-refused session can fail freshness for reasons unrelated to the original cause.

### E — Guard passes an illegitimate swap
**Symptom:** The resumed session contains a different conversation.
**Cause:** The working-directory guard is absent or comparing unresolved paths.
**Fix:** Task 7. Verify with a symlinked project directory, which is where raw string comparison fails.

### F — Flags present before a swap, absent after
**Cause:** Per-profile args were added to the launch command but not to `RELAUNCH_CMD`.
**Fix:** Task 4. Both must be built from the same source.

### G — Args file executes shell rather than passing flags
**Symptom:** Something in an args file ran as a command.
**Cause:** The file was interpolated into the launch string without validation.
**Fix:** Task 4. Validate before use and quote per token. Treat an args file obtained from anywhere other than the user's own hand as untrusted input, since a public repo makes copying one the normal path.

### H — Two watchers on one pane
**Cause:** The `pgrep` guard pattern was not updated alongside the `cpf-` to `cf-` rename.
**Fix:** Confirm the pattern still matches the installed script path, anchored so pane `%3` cannot match a watcher on `%30`.

### I — Status-line message lands in the chat input
**Symptom:** The refusal text appears in Claude Code's prompt.
**Cause:** `display-message` behaved differently than assumed, or `send-keys` was used.
**Fix:** This is the untested assumption in Task 8. If it occurs, fall back to log-only plus having the watcher exit, on the grounds that a watcher which can never succeed is worse than no watcher.

---

## Rollback

1. Restore `~/.bashrc` and `~/claude-failover.sh` from the new suffixed backups.
2. Delete `${XDG_CONFIG_HOME:-$HOME/.config}/claude-failover/` — this lives outside the repo, so `git checkout` does not remove it.
3. Open a new terminal and confirm `type claude-personal-failover` resolves to the original function.
4. In the repo, `git checkout -- .` against the checkpoint commit.

---

## Out of scope

**Detection of any kind.** No `~/.claude*` glob, no shell-startup scan, no `PATH` content grep, no interactive-shell probing. Explicit selection replaces all of it.

**The install-time probe.** Runtime classification plus the pre-swap guard covers the same failure without spending a session start, and the guard additionally catches staleness a one-time probe cannot.

**Enumeration.** There is no registry of profiles because profiles are not a Claude Code concept — `CLAUDE_CONFIG_DIR` is an input to each invocation, so nothing can list directories the user has not named. `--profile` with no argument printing the saved value, plus the documented naming convention, is the whole discovery story.
