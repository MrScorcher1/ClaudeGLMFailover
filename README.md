# ClaudeGLMFailover

Run Claude Code against **GLM-5.2** on NVIDIA's free hosted catalog, and automatically fail over to it — with the conversation intact — when your Claude subscription hits its usage limit.

Three pieces:

1. **`claude-local`** — a launcher that points Claude Code at GLM-5.2 through a LiteLLM translation proxy. Your normal `claude` session is untouched.
2. **`claude-failover.sh`** — a tmux watcher that detects the usage-limit notice and hot-swaps the live session onto GLM via `--continue`.
3. **`claude-failover`** — a shell function that starts a session and its watcher together, against an explicitly chosen Claude Code profile.

Part 1 works on its own. Parts 2 and 3 are the failover layer on top of it.

---

## Why a proxy is needed

Claude Code speaks the Anthropic Messages API (`/v1/messages`). NVIDIA's endpoint speaks the OpenAI dialect (`/v1/chat/completions`). LiteLLM sits between them and translates.

```
Claude Code  ──/v1/messages──>  LiteLLM :4000  ──/v1/chat/completions──>  integrate.api.nvidia.com
                                                                              z-ai/glm-5.2
```

### The non-obvious part

LiteLLM (as of 1.89.0) bridges `/v1/messages` to the upstream **OpenAI Responses API** (`/v1/responses`) by default. NVIDIA does not implement that endpoint, so every request 404s. The fix is one setting:

```yaml
litellm_settings:
  use_chat_completions_url_for_anthropic_messages: true
```

Source: `litellm/__init__.py`, `use_chat_completions_url_for_anthropic_messages`. Upgrading LiteLLM does **not** fix this — it is a routing default, not a missing feature.

---

## Requirements

| | |
|---|---|
| OS | Linux, macOS, or WSL2. Not portable to PowerShell/CMD. |
| Claude Code | Installed **inside** the same environment as the proxy |
| Python | 3.10+ with `litellm[proxy]` |
| tmux | 2.1 or newer (failover only) |
| `curl` | Proxy readiness check — hard dependency |
| `ss` or `lsof` | Port allocation and proxy shutdown. `ss` (iproute2) on Linux, `lsof` on macOS; either is enough. |
| NVIDIA API key | Free from [build.nvidia.com](https://build.nvidia.com), no card required |

---

## Install

### 1. API key

Add to `~/.bashrc`. **Place it above any non-interactive guard** — the stock Ubuntu `~/.bashrc` returns early for non-interactive shells at around line 6, and anything below that line is invisible to scripts:

```bash
export NVIDIA_API_KEY="nvapi-..."
```

Avoid putting the key on a command line — `/proc/<pid>/cmdline` is world-readable, so a key passed as an argument to `sed` or `echo` is visible to `ps` for as long as that process lives. `read` and `printf` are both shell builtins, so this version never creates a process that holds the key:

```bash
read -rs -p "Key: " K
{ printf 'export NVIDIA_API_KEY="%s"\n' "$K"; cat ~/.bashrc; } > ~/.bashrc.new \
  && mv ~/.bashrc.new ~/.bashrc
unset K
```

It also does not echo the key or leave it in shell history.

### 2. LiteLLM

```bash
pip install "litellm[proxy]"          # or: uv tool install litellm
```

On PEP 668 systems (Ubuntu 23.04+, Homebrew Python) a global `pip install` is refused. Use `uv tool`, `pipx`, or a venv — and if you use a venv, point `LITELLM` in `bin/claude-local` at its binary.

### 3. Files

```bash
mkdir -p ~/glm-proxy ~/.local/bin
cp proxy/config.yaml       ~/glm-proxy/config.yaml
cp bin/claude-local        ~/.local/bin/claude-local
cp bin/claude-failover.sh  ~/claude-failover.sh
chmod +x ~/.local/bin/claude-local ~/claude-failover.sh
```

Ensure `~/.local/bin` is on `PATH`.

**One value to check in `bin/claude-local`.** `DEFAULT_CONFIG_DIR` is the config dir used when you run `claude-local` directly, and it ships set to `$HOME/.claude-personal` — the author's profile. On a stock single-profile install change it to `$HOME/.claude`, or export `CLAUDE_LOCAL_CONFIG_DIR`. This only affects direct runs: `claude-failover` always passes a config dir in, and an inherited value always wins.

### 4. One-command launcher (optional)

Append `shell/claude-failover.bash` to `~/.bashrc`, then open a new terminal:

```bash
cat shell/claude-failover.bash >> ~/.bashrc
```

No values to reconcile — the profile is stated explicitly and remembered.

---

## Usage

```bash
claude-local                     # Claude Code on GLM-5.2, one-off
claude-failover                  # Claude on your subscription + watcher armed
claude-failover --profile work   # switch profile, save it, launch
claude-failover --profile        # print the saved profile and exit
```

Your normal launcher is unaffected. `claude-local` sets its environment inside its own process and `exec`s, so nothing leaks into your shell — verify with `env | grep ANTHROPIC`, which should return nothing.

`claude-personal-failover` still exists as a deprecation shim that prints a notice and forwards to `claude-failover`. It will be removed.

When the limit fires, the watcher exits the session and relaunches it with `--continue` on GLM. Going back is manual and deliberate:

```bash
claude --continue            # or your profile-specific launcher
```

It is not automatic because every hop discards the prompt cache, so an automatic return would re-read the full context against the quota that just reset.

### Proxy lifetime

**A `claude-failover` session gets its own proxy** on a port allocated from 4100–4199, and the watcher stops it on the way out, so nothing lingers. The port is normally that session's alone; the one case where it is not is covered below.

The proxy starts **lazily, at swap time** — while you are on your subscription no proxy is needed, so none is started.

The port is carried into the swap alongside `CLAUDE_CONFIG_DIR`:

```
relaunch command: CLAUDE_CONFIG_DIR=/home/you/.claude-personal CLAUDE_LOCAL_PORT=4169 ~/.local/bin/claude-local --continue
```

That matters: if the port did not survive, the relaunch would allocate a different one, start a **second** proxy, and orphan the session's. Each proxy also writes its own `~/glm-proxy/litellm-<port>.log`, since a shared path would be truncated by whichever started last.

**A watcher only stops a proxy its own session started.** Ports are allocated at launch, but the proxy is not started until swap time — so in that window a second session can be handed the same port, and when both swap, the second `claude-local` finds a healthy proxy there and reuses it rather than starting one. Two sessions then share a proxy, and a watcher that stopped "whatever is on my port" would pull it out from under the other session.

`claude-local` writes `~/glm-proxy/litellm-<port>.pid` **only when it actually starts a proxy**, never when it reuses one. The watcher stops the proxy only if that file exists and names the pid currently listening. Otherwise it logs why it left it alone. The sharing itself is harmless — one proxy serves both fine.

**A bare `claude-local` still uses the shared port 4000** and is never stopped automatically — it has no owning session, and another terminal may be using it. Stop it by hand when you want the memory back:

```bash
kill "$(ss -ltnp | grep ':4000' | grep -o 'pid=[0-9]*' | cut -d= -f2)"   # Linux
kill "$(lsof -nP -tiTCP:4000 -sTCP:LISTEN)"                              # macOS
```

Kill by port rather than `pkill -f litellm`. That pattern would take down any unrelated LiteLLM instance — and, since proxies are now per session, every other session's proxy along with it.

### The proxy is loopback-only, deliberately

`claude-local` starts LiteLLM with `--host 127.0.0.1`. **Do not remove that flag.** LiteLLM's CLI defaults to `0.0.0.0`, and this proxy holds your NVIDIA key while accepting requests with no authentication — no `master_key` is set, because Claude Code sends the placeholder `ANTHROPIC_API_KEY=dummy-not-used`. Bound to `0.0.0.0`, anything that can route to this machine could spend your key.

Verify at any time while a session is up:

```bash
ss -ltn | grep 41   # expect 127.0.0.1:<port>, never 0.0.0.0:<port>
```

If you do need the proxy reachable from another host, set a `master_key` in `proxy/config.yaml` and pass it as `ANTHROPIC_API_KEY` in `claude-local` before you widen the bind — not after.

---

## Profiles

Claude Code stores transcripts under `CLAUDE_CONFIG_DIR`. If the failover resumes against the wrong directory it finds no transcript and opens an **empty session**, silently losing the conversation it exists to protect. So the directory is stated explicitly rather than inferred.

**Resolution is a convention, not a lookup.** Nothing is enumerated:

| `--profile` value | Resolves to |
|---|---|
| `work` | `~/.claude-work` |
| `default` or `claude` | `~/.claude` |
| `/opt/cfg` (absolute) | itself |

Names may contain only letters, digits, `.`, `_`, `-`. A leading `-` is rejected so a mistyped flag can't be read as a profile name.

**The short name is sugar for one common layout; the absolute path is the general form.** If your profiles are `~/.claude_work`, `~/claude-profiles/team`, or `/opt/shared/cfg`, name the path once:

```bash
claude-failover --profile /opt/shared/cfg
```

The resolved absolute path is what gets saved, so bare `claude-failover` uses it from then on — you type it once, not every time. There is deliberately no registry and no directory scanning: a lookup table would need maintaining, and scanning would mean guessing, which is the failure this design exists to remove. When a short name resolves to nothing, the error names the resolved path, so the convention is discoverable from the failure.

The choice persists to `${XDG_CONFIG_HOME:-~/.config}/claude-failover/profile` and every launch prints which profile is active.

### The classifier

Before launching, the directory is checked — filesystem only, no session, no quota:

| Result | Meaning | Action |
|---|---|---|
| `USED` | transcripts exist | proceed |
| `CONFIGURED` | real config dir, no sessions yet | proceed, warn that failover can't fire yet |
| `EMPTY` | no evidence this is a Claude Code config dir | **refuse** |
| `MISSING` | path doesn't exist | **refuse** |

This runs on every launch, not only when `--profile` is passed, because a saved path goes stale if the directory is moved. `--force` overrides a refusal and logs loudly.

`CLAUDE.md` is deliberately **not** treated as evidence of a configured profile. A stray or symlinked `CLAUDE.md` in an otherwise-unused `~/.claude` would otherwise classify it as real — the exact case the classifier exists to catch. Incidental files (`.credentials.json`, `statsig/`, `todos/`) are excluded for the same reason: they appear on any launch attempt, including one that failed immediately.

### Per-profile flags (optional)

`${XDG_CONFIG_HOME:-~/.config}/claude-failover/args/<profile>` — one line of flags appended to both the launch command **and** the watcher's relaunch, so they survive a swap.

This file is typed into a shell, so it's validated as a bounded format rather than trusted: only the first non-comment line is read, and it's rejected if it contains `;`, `|`, `&`, backtick, `$(`, `<`, or `>`. **It holds flags, not shell.**

Tokens are split quote-aware, so an argument containing spaces works:

```
--plugin-dir "/home/me/my plugins" --add-dir /tmp/x
```

Splitting is done by `xargs`, which understands quoting without invoking a shell, and each resulting token is `printf '%q'`-quoted before use. An unmatched quote is reported rather than silently mangled.

---

## Configuration

`claude-failover.sh` reads these from the environment:

| Variable | Default | Purpose |
|---|---|---|
| `RELAUNCH_CMD` | `~/.local/bin/claude-local --continue` | What gets typed to resume. `claude-failover` sets this and prefixes `CLAUDE_CONFIG_DIR`. |
| `CLAUDE_LOCAL_BIN` | `~/.local/bin/claude-local` | Path to the launcher used in the relaunch |
| `POLL_SECONDS` | 5 | Pane check interval |
| `SCAN_LINES` | 30 | How much pane tail to read |
| `SETTLE_SECONDS` | 4 | Pause after `/exit` |
| `EXIT_TIMEOUT` | 20 | Max wait for Claude Code to exit |
| `READY_TIMEOUT` | 90 | Max wait for the new session |
| `COOLDOWN_SECONDS` | 900 | Ignore detections after a swap |
| `IDLE_EXIT_SECONDS` | 120 | Quit if Claude Code stays gone this long (`0` = never) |
| `WD_COOLDOWN_SECONDS` | 60 | Short throttle after a working-directory refusal |
| `KEY_PROMPT_TIMEOUT_SECONDS` | 15 | Max wait for the one-time API-key approval prompt |
| `CLOSE_PANE_ON_EXIT` | 1 | Close the pane when the watcher gives up on it (`0` = leave it) |
| `CLOSE_PANE_DELAY_SECONDS` | 3 | Pause before closing, so the stopped state is readable |
| `FINAL_WARN_SECONDS` | 10 | Countdown turns from yellow to red for the last this many seconds |
| `FRESH_WINDOW_MINUTES` | 4× cooldown | Transcript freshness window for the pre-swap guard |
| `EXPECT_CONFIG_DIR` | unset | Profile the guard checks. Unset disables the guard. |
| `EXPECT_PANE_DIR` | unset | Directory the session started in |
| `SESSION_PORT` | unset | Proxy port this session owns; stopped on exit. Unset means the shared 4000, never stopped. |
| `CLAUDE_LOCAL_PORT` | 4000 | Port `claude-local` runs the proxy on |
| `LITELLM_BIN` | `~/.local/bin/litellm` | Path to the LiteLLM binary. Point it at a venv or pipx install. |
| `CLAUDE_FAILOVER_PORT_LO` / `_HI` | 4100 / 4199 | Range per-session ports are allocated from |
| `LOG_FILE` | `~/.claude-failover.log` | Log destination |

---

## Design notes

**Detection is text matching.** The watcher greps the pane tail for known limit wordings. Anthropic's phrasing changes over time — if yours differs, add it to `PATTERN` in `claude-failover.sh`. A silent non-match is this tool's most likely failure, and the log is how you tell.

**The pane must run a shell, not Claude directly.** If Claude Code were the pane's own command, exiting it would close the pane and leave nowhere to type the relaunch.

**The swap is guarded, and refuses before touching anything.** Two checks run at the top of the swap, before `/exit` is sent: a transcript must have been written under the expected profile recently, and the pane's working directory must still match where the session started (`--continue` is directory-scoped). On failure the watcher refuses, logs the specific cause, and shows it on the tmux status line — leaving the session running rather than exiting it and then declining to restore it.

Freshness is checked rather than reconstructing the transcript filename. Claude Code encodes project paths by replacing `/` with `-`, which is lossy — `/a/my-project` and `/a/my/project` collide — and since the check feeds a hard refusal, a collision would make every swap on that project fail permanently.

The two throttles differ by cause: a profile mismatch can't self-correct, so it waits out the full cooldown; a changed working directory can, so it retries after `WD_COOLDOWN_SECONDS`. The freshness window is derived from the longest cooldown rather than set independently, so a twice-refused session can't fail freshness for reasons unrelated to the original cause.

**A pane id is not an identity.** tmux hands out `%0`, `%1`, … again after a server restart, so "that id still exists" doesn't mean it's the same pane. The watcher pins the tmux server pid at startup and exits if it changes — otherwise a leftover watcher re-attaches to an unrelated new session and can act on it with stale expectations.

**It tells you what it is doing.** The launcher prints the active profile, that the watcher is armed and where its log is, and on the way out whether the session ended or you merely detached. The watcher itself is silent by design — its output would scribble over the session — so without those lines the only evidence it exists is a log file you would have to know to read.

Those printed lines scroll away the moment tmux attaches, so the state also lives in the status bar of the session `claude-failover` creates:

| Bar | Meaning |
|---|---|
| green **failover: armed** | watching, subscription session |
| blue **failover: on GLM-5.2** | swapped |
| yellow **failover: stopping in Ns** | Claude Code has exited; counting down to give up |
| red **failover: stopping in Ns** | last `FINAL_WARN_SECONDS` (default 10) before it does |
| red **failover: off** | watcher stopped |

Green, yellow and red form one ramp about the watcher's lifecycle. The swapped state sits deliberately outside it in blue, because which backend you are on is not a severity — putting it in the warm ramp implied an urgency it does not have, and left it easy to confuse with the countdown at a glance.

The whole bar carries the colour, not just its right-hand segment, and the countdown ticks once a second. While Claude is gone there is nothing to detect and a swap is impossible, so that branch runs at 1s and skips pane scanning entirely — detection still runs at `POLL_SECONDS` while Claude is actually running, which is the only time it matters.

The countdown starts the moment Claude Code exits, so the idle window is visible rather than a silent wait, and it returns to green if you start Claude again in that pane before it expires. It is set with `-t <session>`, so it applies only to sessions this tool created and dies with them — if you run `claude-failover` inside your own tmux session, your status bar is left alone.

**The pane closes once the watcher gives up on it**, so an empty tmux session does not linger. Only when the shell is idle: if an editor, a build, or any command is running there, closing the pane would destroy that work, so it is left open and the log says why.

**The watcher exits when Claude Code does.** The pane deliberately outlives Claude Code — it runs a shell so the relaunch has somewhere to be typed — so pane death alone never fires on a normal `/exit`. Without an idle timeout the watcher would survive every clean exit, and a stale one blocks a new watcher on the same pane, leaving a later session silently unwatched.

**It answers exactly one prompt, and only that one.** The first swap under a new profile stops at Claude Code's "Detected a custom API key" approval, which is stored per config dir. The watcher answers it, but the conditions are deliberately narrow: it fires only from inside a swap it started, only while both the prompt's title *and* its footer are on screen, and only when Claude Code's input bar is absent. That last check matters because `--continue` replays the transcript — a conversation that merely *discussed* the prompt would otherwise put its text back on screen and get "1" typed into the chat as a message. It selects *Yes* explicitly rather than pressing Enter, because the highlighted default is *No*.

**The watcher refuses to type into a live prompt.** It confirms Claude Code actually exited before sending anything. If `/exit` doesn't take, it aborts and tells you to swap manually rather than submitting shell commands as chat messages.

**No `pipefail`.** `grep -q` exits on first match and SIGPIPEs the upstream `sed` (exit 141), which under `pipefail` reports failure on a *successful* match — silently disabling the monitor.

**`--continue` is directory-scoped.** It loads the most recent session for the pane's current folder, so the relaunch must happen where the session started.

---

## Known limits

- **~40 requests/minute** on the NVIDIA free tier. Agent loops are request-dense — a trivial write-then-read task costs about four. Expect 429s on wide operations. A 200 RPM increase is available through NVIDIA's developer program.
- **Oversized transcripts cannot fail over.** If the conversation exceeds what GLM can usefully hold, the resume fails, and you cannot compact your way out — compaction costs a model call you no longer have. Run `/compact` *before* approaching your cap. This is the one failure with no recovery.
- **Failover is one-way** and tmux-only. Sessions outside tmux are not watched.
- **The first swap under a new profile hits a one-time approval prompt**, because Claude Code stores per config dir whether to use the `ANTHROPIC_API_KEY` it finds. The watcher answers it automatically — but only while that exact prompt is on screen, and by selecting *Yes* explicitly. The highlighted default is *No*, so a blind Enter would decline the proxy.
- **Subscription and proxy auth are mutually exclusive.** Claude Code is either on your subscription or pointed at the proxy; `ANTHROPIC_BASE_URL` is read once at startup. This is why failover restarts the session instead of switching models in place, and why `--fallback-model` cannot reach GLM.

---

## Verification status

Verified end to end on WSL2 (Ubuntu, tmux 3.6, Claude Code 2.1.220, LiteLLM 1.89.0):

- Upstream streaming tool calls on `z-ai/glm-5.2` — clean `tool_calls` deltas and `finish_reason`
- Anthropic-shaped responses through the proxy, including streaming + tool use with `stop_reason: tool_use`
- Multi-turn agentic tool loop under Claude Code
- Full swap: detection to a running GLM session in ~9 seconds, with the model answering from transferred conversation history
- Swap under a **non-default** profile, resuming that profile's conversation — the case that exposed `claude-local` overwriting an inherited `CLAUDE_CONFIG_DIR`
- Both guard paths: refusal on a profile with no recent transcript, and on a changed working directory, each leaving the session running
- Cause-based throttling: a working-directory refusal retried after 61s, a profile mismatch held for the full cooldown
- The one-time API-key prompt answered automatically, and *not* answered when the same text appears in replayed history
- Args files: shell metacharacters rejected, injection attempt produced no side effect, quoted paths containing spaces survive as one argument
- Status bar across a full lifecycle: armed → countdown → stopped, with the pane closed only when the shell was idle and left alone when a command was still running
- Reaction time: bar turns over within 1s of Claude Code exiting
- Stale-watcher fix: a watcher no longer survives a tmux server restart onto a recycled pane id
- A profile at a path fitting no naming convention, given as an absolute path
- Shell isolation: no `ANTHROPIC_*` leakage
- Proxy bind: `127.0.0.1:<port>` only, with the same request refused when sent to the machine's LAN address. Confirmed the pre-fix behaviour too — without `--host`, that request returned 200 with no auth header.
- Pre-flight honesty: with the watcher script or `claude-local` missing, the launcher says **NOT armed** and names the missing file rather than reporting armed. Both cases previously printed "watcher armed" and started nothing.
- Clean-install walkthrough in a throwaway `HOME`, following the Install section literally: profile detected, watcher armed and actually running, choice persisted and remembered, watcher exited with its pane, no key in the log
- Startup pre-flight: a missing `~/glm-proxy`, a missing `config.yaml`, and a missing `litellm` binary each fail in under a second naming the cause. Previously all three waited 60s and then pointed at a log file that was never created.
- Shared-port safety: a session that reused another's proxy declined to stop it and the proxy kept serving; the session that started it stopped it and cleaned up its pidfile; a stale pidfile naming a different pid produced a refusal rather than a wrong kill
- macOS code paths exercised on Linux behind a `PATH` shim hiding `ss`: port-busy detection, free-port selection, and a real proxy identified and stopped through `lsof`
- Per-session proxy lifecycle: started by `claude-local` on the session's port, stopped by the watcher on idle exit, port released

**Not verifiable in advance:** whether your real usage-limit message matches `PATTERN`. Until you hit a genuine limit and confirm the swap fired, treat the failover half as provisional.

---

## Layout

```
bin/claude-local                     launcher — proxy lifecycle + scoped env
bin/claude-failover.sh               tmux watcher
proxy/config.yaml                    LiteLLM model + routing config
shell/claude-failover.bash           one-command launcher + profile selection
docs/                                specs, gates, and failure modes
  spec-explicit-profiles.md          current design for profile handling
  setup-and-failover-spec.md         original build spec (historical)
  update-one-command-launcher.md     superseded launcher design (historical)
```

Credentials are read from the environment only. Nothing in this repo contains a key.

---

## License

MIT — see [LICENSE](LICENSE).
