# ClaudeGLMFailover

Run Claude Code against **GLM-5.2** on NVIDIA's free hosted catalog, and automatically fail over to it — with the conversation intact — when your Claude subscription hits its usage limit.

Two independent pieces:

1. **`claude-local`** — a launcher that points Claude Code at GLM-5.2 through a LiteLLM translation proxy. Your normal `claude` session is untouched.
2. **`claude-failover.sh`** — a tmux watcher that detects the usage-limit notice and hot-swaps the live session onto GLM via `--continue`.

Plus **`claude-personal-failover`**, a shell function that starts both with one command.

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
| NVIDIA API key | Free from [build.nvidia.com](https://build.nvidia.com), no card required |

---

## Install

### 1. API key

Add to `~/.bashrc`. **Place it above any non-interactive guard** — the stock Ubuntu `~/.bashrc` returns early for non-interactive shells at around line 6, and anything below that line is invisible to scripts:

```bash
export NVIDIA_API_KEY="nvapi-..."
```

Avoid putting the key on a command line. This writes it without echoing or entering shell history:

```bash
read -rs -p "Key: " K; sed -i "1i export NVIDIA_API_KEY=\"$K\"" ~/.bashrc; unset K
```

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

### 4. One-command launcher (optional)

Append `shell/claude-personal-failover.bash` to `~/.bashrc`, then open a new terminal:

```bash
cat shell/claude-personal-failover.bash >> ~/.bashrc
```

**Reconcile two values first.** `CPF_BASE_CMD` must be the *expansion* of however you normally start Claude Code — bash does not expand aliases inside function bodies, so the alias name will not work. `CPF_CONFIG_DIR` must match the `CLAUDE_CONFIG_DIR` in that expansion, or `~/.claude` if you don't set one.

If those two disagree, the failover resumes against the wrong directory, finds no transcript, and opens an **empty session** — losing the conversation it exists to protect.

---

## Usage

```bash
claude-local                 # Claude Code on GLM-5.2, one-off
claude-personal-failover     # Claude on your subscription + watcher armed
```

Your normal launcher is unaffected. `claude-local` sets its environment inside its own process and `exec`s, so nothing leaks into your shell — verify with `env | grep ANTHROPIC`, which should return nothing.

When the limit fires, the watcher exits the session and relaunches it with `--continue` on GLM. Going back is manual and deliberate:

```bash
claude --continue            # or your profile-specific launcher
```

It is not automatic because every hop discards the prompt cache, so an automatic return would re-read the full context against the quota that just reset.

---

## Configuration

`claude-failover.sh` reads these from the environment:

| Variable | Default | Purpose |
|---|---|---|
| `RELAUNCH_CMD` | `claude-local --continue` | What gets typed to resume. Carries `CLAUDE_CONFIG_DIR`. |
| `POLL_SECONDS` | 5 | Pane check interval |
| `SCAN_LINES` | 30 | How much pane tail to read |
| `SETTLE_SECONDS` | 4 | Pause after `/exit` |
| `EXIT_TIMEOUT` | 20 | Max wait for Claude Code to exit |
| `READY_TIMEOUT` | 90 | Max wait for the new session |
| `COOLDOWN_SECONDS` | 900 | Ignore detections after a swap |
| `IDLE_EXIT_SECONDS` | 120 | Quit if Claude Code stays gone this long (`0` = never) |
| `LOG_FILE` | `~/.claude-failover.log` | Log destination |

---

## Design notes

**Detection is text matching.** The watcher greps the pane tail for known limit wordings. Anthropic's phrasing changes over time — if yours differs, add it to `PATTERN` in `claude-failover.sh`. A silent non-match is this tool's most likely failure, and the log is how you tell.

**The pane must run a shell, not Claude directly.** If Claude Code were the pane's own command, exiting it would close the pane and leave nowhere to type the relaunch.

**The watcher exits when Claude Code does.** The pane deliberately outlives Claude Code — it runs a shell so the relaunch has somewhere to be typed — so pane death alone never fires on a normal `/exit`. Without an idle timeout the watcher would survive every clean exit, and a stale one blocks a new watcher on the same pane, leaving a later session silently unwatched.

**The watcher refuses to type into a live prompt.** It confirms Claude Code actually exited before sending anything. If `/exit` doesn't take, it aborts and tells you to swap manually rather than submitting shell commands as chat messages.

**No `pipefail`.** `grep -q` exits on first match and SIGPIPEs the upstream `sed` (exit 141), which under `pipefail` reports failure on a *successful* match — silently disabling the monitor.

**`--continue` is directory-scoped.** It loads the most recent session for the pane's current folder, so the relaunch must happen where the session started.

---

## Known limits

- **~40 requests/minute** on the NVIDIA free tier. Agent loops are request-dense — a trivial write-then-read task costs about four. Expect 429s on wide operations. A 200 RPM increase is available through NVIDIA's developer program.
- **Oversized transcripts cannot fail over.** If the conversation exceeds what GLM can usefully hold, the resume fails, and you cannot compact your way out — compaction costs a model call you no longer have. Run `/compact` *before* approaching your cap. This is the one failure with no recovery.
- **Failover is one-way** and tmux-only. Sessions outside tmux are not watched.
- **Subscription and proxy auth are mutually exclusive.** Claude Code is either on your subscription or pointed at the proxy; `ANTHROPIC_BASE_URL` is read once at startup. This is why failover restarts the session instead of switching models in place, and why `--fallback-model` cannot reach GLM.

---

## Verification status

Verified end to end on WSL2 (Ubuntu, tmux 3.6, Claude Code 2.1.220, LiteLLM 1.89.0):

- Upstream streaming tool calls on `z-ai/glm-5.2` — clean `tool_calls` deltas and `finish_reason`
- Anthropic-shaped responses through the proxy, including streaming + tool use with `stop_reason: tool_use`
- Multi-turn agentic tool loop under Claude Code
- Full swap: detection to a running GLM session in ~9 seconds, with the model answering from transferred conversation history
- Shell isolation: no `ANTHROPIC_*` leakage

**Not verifiable in advance:** whether your real usage-limit message matches `PATTERN`. Until you hit a genuine limit and confirm the swap fired, treat the failover half as provisional.

---

## Layout

```
bin/claude-local                     launcher — proxy lifecycle + scoped env
bin/claude-failover.sh               tmux watcher
proxy/config.yaml                    LiteLLM model + routing config
shell/claude-personal-failover.bash  one-command launcher function
docs/                                full spec, gates, and failure modes
```

Credentials are read from the environment only. Nothing in this repo contains a key.

---

## License

MIT — see [LICENSE](LICENSE).
