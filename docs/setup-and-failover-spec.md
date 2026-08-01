> **Historical — superseded in part.** This is the original build spec (Parts 1-3)
> and remains accurate for how the gates were run.
> **Part 3's inline watcher script is out of date** — the shipped watcher is
> `bin/claude-failover.sh`, which since gained a pre-swap guard, an idle exit,
> and API-key prompt handling. Copy from `bin/`, never from this document.
> Profile handling described here is superseded by `spec-explicit-profiles.md`.
> The proxy launch commands below have been corrected to pass
> `--host 127.0.0.1`; the original text omitted it, and LiteLLM's default bind
> is `0.0.0.0`, which exposes an unauthenticated proxy holding your NVIDIA key
> to anything that can route to the machine. See "The proxy is loopback-only"
> in the README.

# GLM-5.2 on Claude Code — Complete Setup and Failover

One document covering both halves of this build:

- **Part 1** points Claude Code at GLM-5.2 on NVIDIA's free tier via a LiteLLM proxy, behind a single `claude-local` command.
- **Part 2** adds a tmux monitor that detects your Claude usage limit and hot-swaps the live session onto GLM with context intact.
- **Part 3** is the monitor script itself.

Do Part 1 first. Part 2 is a layer on top of it and is useless without it.

---

## How to read this

**Gates** are blocking checks. Do not proceed past a failed gate — go to the referenced failure mode, apply the fix, re-run the gate.

**Failure modes** are lettered within each part. Part 1 has A–P, Part 2 has A–N. A reference like "Failure Mode K" always means *within the current part*; cross-part references say so explicitly.

**Anything with no recovery path is flagged.** Each part has exactly one such case: Part 1's is the streaming tool-call defect, Part 2's is oversized-transcript resume. Both are called out in their own sections.

---

# Part 1 — GLM-5.2 as the Claude Code backend

**Target executor:** A Claude Code agent, running one shot.
**Objective:** Route Claude Code to `z-ai/glm-5.2` on NVIDIA's free hosted catalog, through a LiteLLM translation proxy, with tool calling working end to end.

---

### Design principle for the executing agent

Every value below that could drift is **discovered and asserted at runtime**, not assumed. Each phase ends in a verification gate. **Do not proceed past a failed gate** — jump to the matching entry in the Failure Modes appendix, apply the fix, and re-run the gate.

Do not silently substitute values. If a gate fails and no listed remedy applies, stop and report rather than improvising.

#### What has no backup fix

Most failures below have a documented recovery. **One does not.** If Gate 0.3 fails and disabling streaming doesn't fix it (Failure Mode B), the approach is finished for this model — a transport-level defect can't be worked around from the client side. That gate is a go/no-go decision, not an obstacle to push through. An agent that keeps trying past it is wasting the session.

Everything else has a documented path forward.

---

### The end result

One command, one terminal:

```bash
claude-local
```

That starts the translator if it isn't already running, waits for it to be ready, and drops you into Claude Code on GLM-5.2. Plain `claude` in the same terminal still uses your subscription as normal — the two never collide.

---

### Who does what (setup)

**The agent does:** Phases 0 through 4 — verifying the model, testing NVIDIA directly, installing LiteLLM, writing the config, and building the `claude-local` launcher.

**You do:** steps 1–4 below before starting the agent, then Phase 5 afterwards (plus optional step 6). Phase 5 is the only thing the agent can't do: it means typing into an interactive Claude Code session, and an agent running inside Claude Code can't open a second one and drive it.

---

### Your steps (setup)

#### Before you start the agent

**1. Make a free NVIDIA account.**
Go to `build.nvidia.com` and sign up. Free, no credit card, but it does require verifying a phone number. Only you can do this.

**2. Get your API key.**
Once signed in, generate an API key from the catalog. It starts with `nvapi-`. Copy it somewhere safe — you usually can't view it again after closing the page.

**3. Put the key in your shell profile so it's always available.**

Open `~/.zshrc` (Mac default) or `~/.bashrc` (most Linux) and add this line at the bottom:

```bash
export NVIDIA_API_KEY="nvapi-paste-yours-here"
```

Then either restart your terminal or run `source ~/.zshrc`.

This one is safe to put in your profile — it's an NVIDIA key, and it has no effect on regular Claude Code. The variables that *would* interfere all live inside the launcher script instead, which is what keeps plain `claude` on your subscription.

**4. Check you have Python and Claude Code.**

```bash
python3 --version   # need 3.10 or higher
claude --version    # should print a version
```

Install whichever is missing before continuing.

**Checkpoint:** run `echo ${NVIDIA_API_KEY:0:5}`. It should print `nvapi`. If it prints nothing, step 3 didn't take.

#### After the agent finishes

**5. Run `claude-local` and do the Phase 5 test.** The agent will tell you exactly what to type.

**6. Optional — ask for more capacity.**
The free tier allows roughly 40 requests per minute and normal agent work will hit it. You can apply through the NVIDIA developer program for a 200 RPM increase. That's a form only you can submit.

You do **not** need to keep any terminal open or manually start anything. The launcher handles the translator on every run.

---

### Phase 0 — Preflight: prove the upstream works before building anything

This phase exists to isolate NVIDIA-side failures from proxy-side failures. Skipping it is the single biggest cause of unfixable debugging later.

**0.1 — Confirm the model ID exists in the account's catalog.**

```bash
curl -s https://integrate.api.nvidia.com/v1/models \
  -H "Authorization: Bearer $NVIDIA_API_KEY" \
  | grep -i "glm"
```

Expect a line containing `z-ai/glm-5.2`.

**Gate 0.1:** The exact string `z-ai/glm-5.2` appears. If a different GLM-5.2 identifier appears instead, **use that string verbatim everywhere below** and note the substitution in the final report. If nothing appears, see Failure Mode A.

**0.2 — Confirm a plain completion works.**

```bash
curl -s -w "\nHTTP_STATUS:%{http_code}\n" \
  https://integrate.api.nvidia.com/v1/chat/completions \
  -H "Authorization: Bearer $NVIDIA_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"z-ai/glm-5.2","messages":[{"role":"user","content":"Reply with the single word: ok"}],"max_tokens":16}'
```

**Gate 0.2:** `HTTP_STATUS:200` with a text completion in the body. `401` means a bad or unset key; `404` means a wrong model string.

**0.3 — Confirm tool calling works upstream. This is the critical gate.**

Claude Code cannot function without tool calling, and there is a known NVIDIA forum report of streaming tool calls failing to continue on this endpoint for some models while others on the same endpoint work. Verify it directly for this model, with streaming on, because that is the failing configuration in the report.

```bash
curl -s https://integrate.api.nvidia.com/v1/chat/completions \
  -H "Authorization: Bearer $NVIDIA_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model":"z-ai/glm-5.2",
    "stream":true,
    "messages":[{"role":"user","content":"What is the weather in Paris? Use the tool."}],
    "tools":[{"type":"function","function":{
      "name":"get_weather",
      "description":"Get current weather for a city",
      "parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}
    }}]
  }'
```

**Gate 0.3:** The stream contains `tool_calls` deltas naming `get_weather`, and the stream terminates cleanly with a `finish_reason` of `tool_calls`. If tool call deltas appear but the stream hangs or never reaches a finish reason, see Failure Mode B.

**Do not build the proxy until Gate 0.3 passes.** A failure here is fatal to the whole approach and no proxy configuration can repair it.

---

### Phase 1 — Install LiteLLM

```bash
pip install "litellm[proxy]"
litellm --version
```

**Gate 1:** `litellm --version` returns a version string.

---

### Phase 2 — Write the proxy config

Create the directory first, then the file:

```bash
mkdir -p ~/glm-proxy
```

Then write `~/glm-proxy/config.yaml`:

```yaml
model_list:
  - model_name: glm-5.2
    litellm_params:
      model: openai/z-ai/glm-5.2
      api_base: https://integrate.api.nvidia.com/v1
      api_key: os.environ/NVIDIA_API_KEY

litellm_settings:
  drop_params: true
```

Three details that are load-bearing:

- The `openai/` prefix on `model:` tells LiteLLM to speak the OpenAI dialect upstream. Without it LiteLLM cannot infer the provider and will error at startup.
- `model_name: glm-5.2` is the **client-facing** alias. Every model reference in Phase 4 must match this string exactly, not the upstream `z-ai/glm-5.2`.
- `drop_params: true` silently discards parameters the upstream rejects. Claude Code sends Anthropic-specific fields that NVIDIA does not accept; without this you get `UnsupportedParamsError` on fields such as `web_search_options`.

---

### Phase 3 — Start the proxy and verify translation

Start it in the background so this phase can continue in the same shell, then poll until it answers rather than guessing at a fixed wait:

```bash
cd ~/glm-proxy
nohup litellm --config config.yaml --host 127.0.0.1 --port 4000 > ~/glm-proxy/litellm.log 2>&1 &

for _ in $(seq 1 30); do
  curl -sf --max-time 2 http://127.0.0.1:4000/v1/models >/dev/null 2>&1 && break
  sleep 1
done
```

The `-f` flag matters: without it, curl exits 0 even on a 401 or 500, so the poll would report success against a proxy that rejects everything.

If the loop finishes without the proxy answering successfully, read `~/glm-proxy/litellm.log` and see Failure Mode K before continuing.

This is only for verification. Once Phase 4 is built, the launcher manages the proxy and you never start it by hand again.

**3.1 — Verify the OpenAI route through the proxy:**

```bash
curl -s -w "\nHTTP_STATUS:%{http_code}\n" \
  http://127.0.0.1:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"glm-5.2","messages":[{"role":"user","content":"Reply with: ok"}],"max_tokens":16}'
```

**3.2 — Verify the Anthropic route. This is the whole reason the proxy exists.**

```bash
curl -s -w "\nHTTP_STATUS:%{http_code}\n" \
  http://127.0.0.1:4000/v1/messages \
  -H "Content-Type: application/json" \
  -H "anthropic-version: 2023-06-01" \
  -d '{"model":"glm-5.2","max_tokens":64,"messages":[{"role":"user","content":"Reply with: ok"}]}'
```

**Gate 3:** Both report `HTTP_STATUS:200`. Response 3.2 must be in **Anthropic shape** — a top-level `content` array of typed blocks with `"type":"text"`, plus a `stop_reason` — not an OpenAI `choices` array. If 3.2 returns 404, see Failure Mode C.

Use `127.0.0.1` rather than `localhost` throughout. On some systems `localhost` resolves to IPv6 `::1` first, while LiteLLM binds IPv4 only — producing connection refused errors that look like the proxy is down when it is running fine.

---

### Phase 4 — Build the `claude-local` launcher

Write this to `~/.local/bin/claude-local`:

```bash
#!/usr/bin/env bash
set -euo pipefail

PROXY_DIR="$HOME/glm-proxy"
PORT=4000
MODEL="glm-5.2"
LOG="$PROXY_DIR/litellm.log"

# 1. Refuse to start without the upstream key.
if [ -z "${NVIDIA_API_KEY:-}" ]; then
  echo "ERROR: NVIDIA_API_KEY is not set." >&2
  echo "Add this to ~/.zshrc or ~/.bashrc, then restart your terminal:" >&2
  echo '  export NVIDIA_API_KEY="nvapi-..."' >&2
  exit 1
fi

# 2. Reuse a healthy proxy; only start one if nothing is answering.
#    -f makes curl fail on 4xx/5xx. Without it, a 401 counts as "ready"
#    and Claude Code gets handed a proxy that rejects every request.
if curl -sf --max-time 2 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; then
  echo "[claude-local] translator already running on :$PORT"
else
  echo "[claude-local] starting translator on :$PORT ..."
  nohup litellm --config "$PROXY_DIR/config.yaml" --host 127.0.0.1 --port "$PORT" > "$LOG" 2>&1 &

  # 3. Block until it answers successfully. Never hand off to a cold proxy.
  ready=0
  for _ in $(seq 1 30); do
    if curl -sf --max-time 2 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  if [ "$ready" -ne 1 ]; then
    echo "ERROR: translator did not come up within 30s, or is returning errors." >&2
    echo "Check the log: $LOG" >&2
    exit 1
  fi
  echo "[claude-local] translator ready"
fi

# 4. Scoped environment. These exist only inside this script's process —
#    they are never exported into your shell, so plain `claude` is unaffected.
export ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT"
export ANTHROPIC_API_KEY="dummy-not-used"
export ANTHROPIC_CUSTOM_MODEL_OPTION="$MODEL"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$MODEL"
export ANTHROPIC_DEFAULT_OPUS_MODEL="$MODEL"
export ANTHROPIC_DEFAULT_SONNET_MODEL="$MODEL"
export CLAUDE_CODE_SUBAGENT_MODEL="$MODEL"

# 5. Replace this process with Claude Code, passing through any arguments.
exec claude "$@"
```

Then make it executable and reachable:

```bash
mkdir -p "$HOME/.local/bin"
chmod +x "$HOME/.local/bin/claude-local"
```

**If `~/.local/bin` is not already on PATH** (check with `echo $PATH`), add an alias to `~/.zshrc` or `~/.bashrc` instead:

```bash
alias claude-local="$HOME/.local/bin/claude-local"
```

**Gate 4:** `command -v claude-local` resolves. Running `claude-local --version` prints a Claude Code version and exits without error.

Note that `claude-local --version` runs the full script, so it will start the proxy as a side effect before printing. That is expected — Phase 5 shuts it down again.

#### Why each piece matters

- **Scoped exports (step 4).** This is the design's core. Because the variables live in the script's process and `exec` replaces that process with Claude Code, they reach Claude Code but never touch your shell. That's what lets `claude` and `claude-local` coexist in one terminal.
- **`ANTHROPIC_BASE_URL`** — bare host and port. **No `/v1`, no `/anthropic` suffix.** Claude Code appends the path itself; a suffix produces a 401 or 404 that looks like an auth failure.
- **`ANTHROPIC_API_KEY`** — Claude Code demands a non-empty value here regardless of what the backend does with it. **No Anthropic key is used anywhere in this setup.** LiteLLM's default local behaviour is to accept unauthenticated requests, but this is version-dependent: if a `master_key` is set in `config.yaml` or the environment, the proxy will reject `dummy-not-used`. Gate 3 is what proves it either way — if 3.1 and 3.2 returned 200 without an auth header, any string works here. If they returned 401, set this variable to the proxy's master key instead.
- **`ANTHROPIC_CUSTOM_MODEL_OPTION`** — adds a menu entry only; it does **not** replace built-in aliases.
- **The three `DEFAULT_*` aliases** — required. Without them, `haiku`, `sonnet`, and `opus` still resolve to Anthropic model names the proxy can't map, and internal calls requesting `haiku` will 400.
- **`CLAUDE_CODE_SUBAGENT_MODEL`** — routes spawned subagents. Omit it and agent work silently falls back.
- **The readiness loop (step 3)** — LiteLLM takes several seconds to bind. Launching Claude Code against a cold proxy produces connection errors that look like configuration bugs.
- **`exec` with `"$@"`** — passes your arguments through, so `claude-local --help` and similar behave normally.

All five model values use the `model_name` from Phase 2 (`glm-5.2`), **not** the upstream `z-ai/glm-5.2`.

---

### Phase 5 — Acceptance test

**Agent's final action.** Before reporting and handing off, stop the verification proxy started in Phase 3, so the human's test exercises the launcher's own cold-start path rather than a proxy that is already warm:

```bash
kill "$(ss -ltnp | grep ':4000' | grep -o 'pid=[0-9]*' | cut -d= -f2)" 2>/dev/null || true
```

(Scoped to the verification port. A broad `pkill -f litellm` would now also stop any per-session proxy on 4100-4199.)

That is the agent's last step. Everything below is the human's.

---

**YOU RUN THIS.** In any terminal:

```bash
claude-local
```

You should see the translator start, report ready, and Claude Code open. Now type a task that forces a multi-step tool loop:

> Create a file `hello.txt` containing the word `hello`, then read it back and tell me its contents.

**Gate 5 — all must hold:**
1. The launcher started the translator and reported ready, with no manual steps.
2. A file write tool is invoked and succeeds.
3. A file read tool is invoked afterward, in a **second** turn — this proves the tool loop continues rather than stalling after one call.
4. The final response reports the contents correctly.
5. `~/glm-proxy/litellm.log` shows requests arriving on `/v1/messages`.

If step 2 succeeds but step 3 never fires, see Failure Mode B — that is the streaming tool-call stall, surfacing at the agent layer.

**Isolation check.** Exit Claude Code, then in the same terminal run `claude`. It should start on your normal subscription with no trace of GLM-5.2. If it doesn't, see Failure Mode I.

---

### Failure Modes — setup

#### A — Model not present in `/v1/models`
**Symptom:** Gate 0.1 empty, or 404 on Gate 0.2.
**Cause:** Catalog IDs change; the account may not have access.
**Fix:** Open the GLM-5.2 page at `build.nvidia.com` and copy the model string from its code sample. Substitute everywhere. If the model is absent entirely, fall back to another confirmed tool-calling NIM model and report the substitution.

#### B — Streaming tool calls stall (highest-risk failure)
**Symptom:** First tool call fires, then the loop hangs or ends prematurely.
**Cause:** Documented NVIDIA-side defect affecting some models on this endpoint under streaming. Model-specific, not universal.
**Fix, in order:**
1. Disable streaming between the proxy and NVIDIA. **The exact config key for this varies by LiteLLM version — look it up in the LiteLLM proxy docs for your installed version rather than guessing.** As of writing, the relevant setting lives under `litellm_params` for the model entry. Verify the key exists before editing; an unrecognised key will fail silently or refuse to start. After editing, restart the proxy and re-run the Gate 0.3 tool-calling request against `http://127.0.0.1:4000/v1/chat/completions` with `"model":"glm-5.2"` — the proxy alias, not the upstream string, and no auth header needed locally.
2. If still failing, the model is unusable for agentic work on this endpoint. Do not attempt prompt workarounds — this is a transport defect, not a model behaviour you can steer. Report and switch models.

#### C — `/v1/messages` returns 404 through the proxy
**Symptom:** Gate 3.2 fails while 3.1 passes.
**Cause:** LiteLLM version predates Anthropic passthrough support.
**Fix:** Upgrade LiteLLM and restart. Use the same Python that installed it — `pip install --upgrade "litellm[proxy]"` for a global install, or `~/glm-proxy/venv/bin/pip install --upgrade "litellm[proxy]"` if you took the venv route in Failure Mode M. Upgrading the wrong interpreter is a silent no-op and will look like the upgrade didn't help.

If still 404, substitute a purpose-built adapter — `zhangrr/claude-nvidia-proxy` or `emrcaca/nvidia-anthropic-adapter` both expose `/v1/messages` and translate to `/v1/chat/completions`. Note that some adapters read `ANTHROPIC_AUTH_TOKEN` rather than `ANTHROPIC_API_KEY`; match whichever the chosen adapter documents, and update the launcher's start line to run the adapter instead of LiteLLM.

#### D — 401 from Claude Code, but curl works
**Cause:** Almost always a malformed `ANTHROPIC_BASE_URL`.
**Fix:** Confirm it is exactly `http://127.0.0.1:4000` — no trailing slash, no `/v1`, no `/anthropic`. Match whatever `PORT` is set to in the launcher.

#### E — `UnsupportedParamsError`
**Cause:** Claude Code sent an Anthropic-only field upstream.
**Fix:** Confirm `drop_params: true` is present under `litellm_settings` and that the proxy was restarted after the edit.

#### F — 429 rate limiting
**Cause:** The free tier is ~40 RPM. Agentic loops are request-dense and will hit this during normal work.
**Fix:** This is a quota ceiling, not a bug. Reduce parallel subagents, avoid wide multi-file operations, and apply for the 200 RPM upgrade through the developer program. Expect it to recur.

#### G — Model alias errors mentioning `sonnet`, `opus`, or `haiku`
**Cause:** One of the five model variables is missing from the launcher script.
**Fix:** Open `~/.local/bin/claude-local` and confirm all five are present and set to the same value: `ANTHROPIC_CUSTOM_MODEL_OPTION`, `ANTHROPIC_DEFAULT_HAIKU_MODEL`, `ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_SONNET_MODEL`, `CLAUDE_CODE_SUBAGENT_MODEL`. All must equal the `model_name` from `config.yaml` (`glm-5.2`), not the upstream `z-ai/glm-5.2`. Do not fix this by exporting them in your shell — that breaks isolation and causes Failure Mode I.

#### H — Context shorter than expected
**Note:** NVIDIA's model card specifies 1,000,000 input tokens for this model, so the window is genuinely large. But Claude Code manages its own context and compacts independently, and the free tier's real constraint is request rate, not window size. Do not tune for 1M context; tune for 40 RPM.

#### I — Plain `claude` also uses GLM-5.2 (isolation broken)
**Symptom:** After running `claude-local`, a normal `claude` in the same terminal is still on GLM-5.2.
**Cause:** `ANTHROPIC_*` variables leaked into your shell — almost always because someone pasted the export block into `~/.zshrc` or `~/.bashrc` rather than leaving them inside the script.
**Fix:** Remove any `ANTHROPIC_*` lines from your shell profile. Only `NVIDIA_API_KEY` belongs there. Restart the terminal and confirm with `env | grep ANTHROPIC` — it should return nothing.

#### J — `claude-local: command not found`
**Cause:** `~/.local/bin` isn't on PATH.
**Fix:** Add the alias line from Phase 4 to your shell profile and restart the terminal. Verify with `command -v claude-local`.

#### K — Launcher exits with "translator did not come up within 30s"
**Cause:** LiteLLM failed at startup — usually a malformed `config.yaml` or a port already occupied by an unrelated process.
**Fix:** Read `~/glm-proxy/litellm.log`; the error is at the end. If the port is taken, change `PORT` in the launcher and `--port` consistently. On slow machines, raise the loop from 30 to 60.

#### L — Launcher reports "already running" but requests fail
**Cause:** A stale or wedged LiteLLM process is holding the port and answering `/v1/models` while otherwise broken.
**Fix:** Kill only the process holding that port, then re-run `claude-local`:

```bash
kill "$(ss -ltnp | grep ':4000' | grep -o 'pid=[0-9]*' | cut -d= -f2)"
```

Do **not** use `pkill -f "litellm --config"` here. Since per-session proxies were introduced, several LiteLLM instances may be running at once on ports 4100-4199, and that pattern would take down every other session's proxy along with the wedged one.

#### M — `pip install` fails with "externally-managed-environment"
**Symptom:** Phase 1 aborts before LiteLLM installs.
**Cause:** PEP 668. Common on Ubuntu 23.04+ and Homebrew Python — the system Python refuses global installs.
**Fix, preferred:** use an isolated environment.
```bash
python3 -m venv ~/glm-proxy/venv
~/glm-proxy/venv/bin/pip install "litellm[proxy]"
```
Then change the launcher's start line to call the venv binary directly:
```bash
nohup "$HOME/glm-proxy/venv/bin/litellm" --config "$PROXY_DIR/config.yaml" --host 127.0.0.1 --port "$PORT" > "$LOG" 2>&1 &
```
Alternatively `pipx install litellm`, or `pip install --break-system-packages` as a last resort. If you use a venv, Gate 1 must be run as `~/glm-proxy/venv/bin/litellm --version`.

#### N — Non-Unix shell (Windows without WSL)
**Symptom:** Phase 4's script fails immediately, or `chmod`, `nohup`, `pkill`, and `exec` are unrecognised.
**Cause:** This entire plan assumes bash or zsh on macOS or Linux. It is not portable to PowerShell or CMD.
**Fix:** Run everything inside WSL2, and install Claude Code inside WSL too — a Windows-side Claude Code cannot reach a proxy bound to `127.0.0.1` inside WSL without extra port forwarding. Don't partially translate the script; keep the whole chain in one environment.

#### O — Claude Code ignores the model variables entirely
**Symptom:** `claude-local` opens normally, the proxy log stays empty, and responses look like ordinary Claude.
**Cause:** The `ANTHROPIC_CUSTOM_MODEL_OPTION` and `CLAUDE_CODE_SUBAGENT_MODEL` variable names are version-dependent and may differ in your Claude Code build.
**Fix:** Watch `~/glm-proxy/litellm.log` while sending one message. If nothing arrives, `ANTHROPIC_BASE_URL` isn't taking effect — check the current variable names in the Claude Code docs for your installed version and update the launcher. An empty proxy log is the diagnostic that separates this from every model-side failure.

#### P — `exec claude` fails inside the launcher
**Symptom:** The proxy starts and reports ready, then the script exits with "command not found".
**Cause:** `claude` resolves in your interactive shell but not in the script's environment — common when Claude Code was installed through a version manager that only initialises for interactive shells.
**Fix:** Replace the last line with an absolute path. Get it from `command -v claude` in your normal terminal and hardcode it.

---

### Final report the agent should produce

1. Confirmed model string used, and whether it matched `z-ai/glm-5.2`.
2. Pass/fail for each gate: 0.1, 0.2, 0.3, 1, 3, 4.
3. Whether streaming had to be disabled (Failure Mode B), and which config key was used.
4. Whether LiteLLM was installed globally or into a venv (Failure Mode M). If a venv, state the launcher's start line as written.
5. Which proxy ended up in use — LiteLLM, or a substituted adapter (Failure Mode C).
6. Any value substituted from this plan, and why.
7. The exact command the user should run first, and the Phase 5 test prompt to type.

Gate 5 is not the agent's to report — it is the human's acceptance test.

---

# Part 2 — Automatic failover on usage limit

Everything in this part assumes Part 1 is complete and `claude-local` works.

---

### What it does

Watches a tmux pane for Claude Code's usage-limit notice. When it fires, it exits the session and relaunches it with `claude-local --continue`, putting you on GLM-5.2 with the full conversation intact. Context survives because Claude Code writes the transcript to disk continuously — `--continue` reloads message history and tool results.

It is **one-way by design**. Going back to Claude is manual: `claude --continue`. See Failure Mode N for why that's deliberate.

---

### Who does what (failover)

The two roles interleave — this is not a clean agent-then-human handoff.

**Agent, first:** steps 1–3 — verifying prerequisites, installing tmux, making the script executable. Closes **Gate 1**. Note that installing tmux needs sudo on system package managers, so an agent without it should report and stop rather than working around it.

**You, then:** step 4 — starting Claude Code in tmux. An agent running inside Claude Code can't open and drive a second interactive session, and **nothing after this point can proceed until the session exists**: Gate 2 needs a live pane to resolve, and step 5 needs a pane id to watch.

**Either, after that:** step 5 and **Gates 2–3**. An agent can do this once you've confirmed the session is up.

**You, eventually:** step 6 and **Gates 4–5**. These wait on a real limit event and can't be forced.

**Do not silently substitute values.** If a gate fails and no listed remedy applies, stop and report rather than improvising. A monitor that half-works is worse than one that admits it isn't set up — it will look active in the log while doing nothing at the moment you need it.

---

### Gates

Each gate is blocking. **Do not proceed past a failed gate** — go to the referenced failure mode, apply the fix, and re-run it.

**Gate 1 — prerequisites.** `claude-local --version` prints a version, and `tmux -V` reports 2.1 or newer. If `claude-local` fails, stop: this tool is a layer on top of it and there is nothing to fall back to. If tmux is old, see Failure Mode K.

**Gate 2 — pane resolution.** Requires step 4 to be done first. `tmux list-panes -a -F '#{pane_id} #{pane_current_command} #{pane_current_path}'` shows a row whose command is `node` and whose path is your project directory. If the path is wrong, see Failure Mode F before starting the monitor — a monitor pointed at the wrong directory will resume the wrong conversation.

**Gate 3 — monitor live.** On startup, before any polling begins, `~/.claude-failover.log` gets a "watching pane" line naming your pane id, plus a "logging to" line. If neither appears within a few seconds, or you see a writability warning, see Failure Mode M.

**Gate 4 — pattern match (the one that matters).** Your real limit message matches `PATTERN`. This gate cannot be satisfied by inspection; it requires the text from an actual limit event. Until it passes, the tool is unverified. See step 6, and Failure Mode A on failure.

**Gate 5 — end-to-end swap.** A real swap completes: the session exits, relaunches under `claude-local`, history is intact, and the log records it with a timestamp. Then confirm isolation — plain `claude` in another terminal still uses your subscription.

Gates 1–3 can be run immediately. Gates 4 and 5 wait on a real limit event, so **treat the setup as provisional until both have passed.**

---

### What has no fallback

Most failures below have a documented recovery. **One does not.**

If your transcript is larger than what GLM can usefully hold, the resume cannot work — and you can't fix it after the fact, because compacting costs a model call you no longer have quota for. The fix is preventative: run `/compact` *before* you're near your limit, not after. If you're already stuck, the session is unrecoverable on GLM and you'll have to wait for the reset. See Failure Mode J.

Everything else has a path forward.

---

### Your steps (failover)

#### Before you run it

**1. Confirm `claude-local` works.**

```bash
claude-local --version
```

Should print a version. If not, fix that first — this tool is a layer on top of it.

**2. Install tmux.**

```bash
tmux -V     # need 2.1 or newer
```

If missing: `brew install tmux` on Mac, `sudo apt install tmux` on Ubuntu/Debian, `sudo dnf install tmux` on Fedora/RHEL.

**3. Make the script executable.**

```bash
chmod +x ~/claude-failover.sh
```

Put it wherever you like; the examples assume your home directory.

#### Running it

**4. Start Claude inside tmux**, from your project directory.

```bash
tmux new -s work
cd ~/your-project
claude
```

The project directory matters: `--continue` loads the most recent session **for the current folder**, so the relaunch must happen in the same place the session started.

**5. In a second terminal, find the pane id and start the monitor.**

```bash
tmux list-panes -a -F '#{pane_id} #{pane_current_command} #{pane_current_path}'
```

Look for the row where the command is `node` and the path is your project. The id looks like `%3`.

```bash
~/claude-failover.sh %3
```

Leave it running. Logs go to `~/.claude-failover.log`.

#### The one thing you must verify yourself

**6. Capture your actual limit message the first time you hit it.**

The script matches six known message formats, but Anthropic's wording changes over time and yours may differ. When you first hit your limit, **copy the exact text** before it scrolls away, then confirm it matches:

```bash
grep -Eqi 'hour limit reached|usage limit reached|out of extra usage|hit your limit|Rate limit hit|Please try again in [0-9]+ hour' <<< "PASTE YOUR MESSAGE HERE" && echo MATCH || echo NO MATCH
```

If it says `NO MATCH`, see Failure Mode A. Until you've done this once, treat the tool as unverified — a silent non-match is its most likely failure.

#### Optional

**7. Tune via environment variables**, all with sane defaults:

| Variable | Default | Purpose |
|---|---|---|
| `POLL_SECONDS` | 5 | How often to check the pane |
| `SCAN_LINES` | 30 | How much of the pane tail to read |
| `SETTLE_SECONDS` | 4 | Pause after sending `/exit` |
| `EXIT_TIMEOUT` | 20 | Max wait for Claude Code to exit |
| `READY_TIMEOUT` | 90 | Max wait for the new session to load |
| `COOLDOWN_SECONDS` | 900 | Ignore detections after a swap |
| `LOG_FILE` | `~/.claude-failover.log` | Log destination |

---

### Failure Modes — failover

#### A — Limit hits but nothing happens
**Symptom:** You hit your cap, the log shows no detection.
**Cause:** Your limit message doesn't match any of the six built-in patterns. This is the most likely failure and the reason for step 6.
**Fix:** Add your wording to the `PATTERN` variable near the top of the script, pipe-separated. Keep it specific — a loose pattern causes Failure Mode B. Restart the monitor.

#### B — Swaps when you didn't hit a limit
**Symptom:** A swap fires mid-conversation with quota remaining.
**Cause:** The pattern matched Claude's own output. Asking Claude about rate limits, or reading a file that discusses them, can put matching text in the pane.
**Fix:** Narrow `PATTERN` to phrases that only appear in the real notice — anchor on `resets` or the bullet separator rather than generic words like "limit". Lower `SCAN_LINES` to 15 so only the freshest output is considered. The cooldown limits the damage to one spurious swap per 15 minutes.

#### C — "Claude Code did not exit — aborting swap"
**Symptom:** Logged error, no swap, session untouched.
**Cause:** `/exit` didn't take. Claude Code may have been mid-tool-confirmation or in a modal state.
**Fix:** This is the safe outcome by design — the script refuses to type into a live chat prompt. Exit the session yourself and run `claude-local --continue`. If it recurs, raise `EXIT_TIMEOUT` and `SETTLE_SECONDS`.

#### D — Swap fires but `claude-local: command not found`
**Cause:** `claude-local` resolves in your shell but not the pane's, or it's an alias that isn't loaded there.
**Fix:** Use the absolute path in the `send-keys` line: `$HOME/.local/bin/claude-local --continue`. Aliases are unreliable across tmux panes; a real executable on PATH is not.

#### E — "session did not come back up within 90s"
**Cause:** The relaunch failed. Usually `NVIDIA_API_KEY` unset in that pane, or the LiteLLM proxy failing to start.
**Fix:** Check `~/glm-proxy/litellm.log` and the pane itself. Cross-reference Part 1 Failure Modes K and M (above). The monitor deliberately does not set its cooldown here, so it stays free to retry.

#### F — Resumes the wrong conversation
**Symptom:** GLM comes up with unrelated history.
**Cause:** `--continue` is directory-scoped and loads the most recent session for the pane's current folder. If you `cd`'d during the session, you get a different one.
**Fix:** Confirm the pane's path with `tmux list-panes -a -F '#{pane_id} #{pane_current_path}'`. For precision, change the script to use `--resume <session-id>` with a named session instead — name it with `/rename` while you work.

#### G — GLM comes up but doesn't continue the task
**Symptom:** Session loads with history, then just sits there.
**Cause:** The prompt that hit the limit is in the transcript with no assistant reply, and the new model may not treat it as a live instruction.
**Fix:** Type a nudge — "continue where you left off." To automate, add a `send-keys` of that text after `wait_for_session` succeeds, with a short sleep first.

#### H — Monitor dies when you close the terminal
**Cause:** You ran the monitor outside tmux, so it's tied to that terminal.
**Fix:** Run it in its own tmux pane or with `nohup ~/claude-failover.sh %3 &`. The Claude pane surviving is the whole point of tmux; the watcher should survive too.

#### I — Swaps repeatedly, or misses a second limit
**Cause:** `COOLDOWN_SECONDS` is wrong for your rhythm. Default 900 (15 min).
**Fix:** Raise it if you see repeat swaps. Lower it if you manually returned to Claude, hit the limit again quickly, and nothing fired.

#### J — Resume fails or truncates on GLM (no fallback)
**Symptom:** The session won't load, errors on context length, or comes back with visible history missing.
**Cause:** The transcript exceeds what GLM can hold. Compaction costs a model call you no longer have.
**Fix:** Preventative only. Run `/compact` during long sessions before you approach your cap. Once you're limited with an oversized transcript, that session can't move to GLM — start a fresh one on GLM or wait for the reset. This is the one path with no recovery.

#### K — `clear-history` errors on old tmux
**Cause:** tmux older than 2.1.
**Fix:** The call is already suppressed with `2>/dev/null`, so it degrades rather than breaks — but scrollback won't be wiped, raising re-trigger risk. Upgrade tmux, or rely on the cooldown.

#### L — "limit text seen but Claude is not the foreground process"
**Cause:** The guard checks for `node` or `claude` as the pane's command and found something else.
**Fix:** Usually correct behaviour — you'd exited or opened another program. If it blocks legitimately, check what `tmux display-message -p -t %3 '#{pane_current_command}'` actually returns and add that value to `foreground_is_claude`.

#### M — Log warnings about the log file
**Cause:** `$HOME` unwritable or an odd `LOG_FILE` path.
**Fix:** The script falls back to stdout-only and warns. Set `LOG_FILE` somewhere writable.

#### N — Getting back to Claude
**Not a failure — a deliberate omission.**
When your limit resets, exit and run `claude --continue`. This isn't automated because every hop kills the prompt cache, so an automatic return would trigger a full-context re-read charged against the quota that just reset — spending your fresh allowance the instant you get it. Do it manually, when you're ready to work.

---

### Final report the executor should produce

1. Pass/fail for Gates 1, 2, and 3, with the pane id used.
2. Whether `claude-local` was invoked by name or absolute path (Failure Mode D).
3. Any config variable changed from its default, and why.
4. Any edit made to `PATTERN`, quoted exactly.
5. Confirmation that Gates 4 and 5 remain **outstanding**, with a note that the setup is provisional until a real limit event closes them.

Gates 4 and 5 are not the executor's to report — they depend on a real limit event and belong to you.

---

### Status after setup

Passing Gates 1–3 means the monitor is installed and running. It does **not** mean it works. The single fact that determines whether this tool functions — whether your limit message matches the pattern — cannot be established until you hit your cap.

So: set it up, then treat the first real limit event as the actual test. Keep an eye on the log that day rather than assuming it fired.

---

# Part 3 — The monitor script

Write this to `~/claude-failover.sh`, then `chmod +x ~/claude-failover.sh`.

Two edits worth making before first run, both from Part 2's failure modes:

- If `claude-local` is a shell alias rather than an executable on PATH, replace `claude-local --continue` in `swap_to_glm` with its absolute path (Part 2, Failure Mode D).
- If your limit message doesn't match the six built-in formats, extend `PATTERN` (Part 2, Failure Mode A). This is the single most likely reason the tool silently does nothing.

```bash
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

LAST_SWAP=0

usage() {
  echo "usage: $0 <tmux-pane-id>   e.g. $0 %3" >&2
  echo "find it: tmux list-panes -a -F '#{pane_id} #{pane_current_command}'" >&2
  exit 1
}

[ -z "$PANE" ] && usage
command -v tmux >/dev/null 2>&1 || { echo "tmux not found" >&2; exit 1; }
command -v claude-local >/dev/null 2>&1 || \
  echo "WARNING: claude-local not on PATH here. If it is an alias defined in your shell rc, this is fine — the pane's interactive shell will resolve it. Otherwise the swap will fail." >&2

mkdir -p "$(dirname -- "$LOG")" 2>/dev/null
: > /dev/null 2>&1
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
  # so this must run from the folder the session started in.
  tmux send-keys -t "$PANE" 'claude-local --continue' Enter

  if wait_for_session; then
    LAST_SWAP="$(date +%s)"
    log "relaunched via claude-local --continue — now on GLM-5.2"
    log "when your limit resets, exit and run: claude --continue"
    return 0
  fi

  log "ERROR: session did not come back up within ${READY_TIMEOUT}s."
  log "Check the pane manually. Common causes: claude-local not on PATH,"
  log "NVIDIA_API_KEY unset, or the LiteLLM proxy failing to start."
  # Do not set LAST_SWAP — leave the monitor free to retry.
  return 1
}

log "watching pane $PANE (poll ${POLL}s, scan ${SCAN} lines, cooldown ${COOLDOWN}s)"
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
```

---

# Appendix — Origins and open items

**Verified against sources:** the model string `z-ai/glm-5.2` and its 1,000,000-token input window and tool-calling support come from NVIDIA's own model card. The six limit-message formats come from `cheapestinference/claude-auto-retry`. Claude Code's session-resume behaviour and the deliberate exclusion of rate-limit errors from `--fallback-model` come from the Claude Code documentation.

**Verified by testing:** the `pipefail` + `grep -q` SIGPIPE interaction was confirmed experimentally (exit status 141 on a successful match), which is why the monitor script runs under `set -u` alone.

**Not verified — test these first:**

1. Whether the hosted NVIDIA endpoint serves `/v1/messages`, or whether the proxy is doing all the translation (Part 1, Gate 3.2).
2. Whether GLM-5.2 sustains streaming tool calls on that endpoint (Part 1, Gate 0.3) — the one genuine dead end.
3. Whether your Claude Code build honours the `ANTHROPIC_*` model variables (Part 1, Failure Mode O).
4. Whether your actual limit message matches `PATTERN` (Part 2, Gate 4) — unknowable until you hit your cap.

Items 1–3 resolve in the first ten minutes of running Part 1. Item 4 resolves the first time you hit your limit, and until then Part 2 is installed but unproven.
