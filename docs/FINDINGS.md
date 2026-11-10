# Findings

What running Leasehold has shown so far, newest first. Each entry gives what was seen, the evidence, and what changed because of it. Machine addresses, host names and keys stay out of this file.

The test machine for the 2026-11-09/10 entries was an Ubuntu 24.04 desktop with an AMD Radeon RX 7600 (gfx1102, 8 GB), an Intel Core i5-6600K and the 7.0 HWE kernel. It ran ROCm 10.1.0 (amdgpu 7.1.9) and Lemonade 2026.45.3 from the stable PPA.

---

## 2026-11-10: confining agents: localhost-only isn't "no network"

The agent trial's confinement (below) was rebuilt for a longer run's agents on the same box. The launcher and its gate are kept outside this repository, with the owner's notes.

**What localhost-only let through.**
- **Every service on loopback.** `IPAddressAllow=localhost` admits all of 127.0.0.0/8, so a confined process can reach any service listening on loopback, and some of those act on the network for whoever asks. A probe from inside the trial's confinement reached:
  - Lemonade's whole API on 13305, including loading and unloading models, and the endpoint that pulls models from Hugging Face;
  - llama-server's own port, Lemonade's second port, the print server and sshd;
  - systemd-resolved's DNS stub at 127.0.0.53, so names resolved even with every outside address blocked;
  - a file-sync daemon's local web interface. When no GUI password is set, any local process can use its REST API to share a folder with any remote device.
- **Unix sockets.** `IPAddressAllow` doesn't cover them at all. D-Bus, systemd-resolved's varlink socket, Avahi and snapd's API each make requests for an unprivileged caller.

**What replaced it.**
- **No network of its own.** Each agents' service gets `PrivateNetwork=yes`: a network namespace that holds only its own loopback.
- **One way out: a small gate.** It is a Python service of its own, under a dynamic user, listening on a Unix socket.
  - Inside the agents' service, `systemd-socket-activate` and `systemd-socket-proxyd` make the gate reachable as `http://127.0.0.1:13305`, so Pi's provider config doesn't change.
  - The gate passes only `GET /v1/models` and `POST /v1/chat/completions`, and answers 403 to anything else.
- **Hidden sockets.** `InaccessiblePaths=` hides the D-Bus, systemd-resolved, Avahi, snapd and CUPS sockets.
- **The probe from inside, afterwards:**
  - the model answered through the gate;
  - Lemonade's health and pull endpoints got 403;
  - github.com and 1.1.1.1 were blocked, and name lookups failed;
  - every other localhost port (22, 53, 631, 8001, 8384, 9000, 22000) was closed.
- **A usage log the agents can't reach.** The gate logs each request with:
  - the agent's service name, read from the connecting process's cgroup via `SO_PEERCRED`;
  - the model;
  - prompt tokens with the cached share, and output tokens;
  - the seconds taken.

  llama.cpp's streamed usage object nests `prompt_tokens_details`, which a flat regular expression misses. Parse it as JSON (`json.JSONDecoder.raw_decode` from the last `"usage"` key).

**The CPU limit, moved from Pi to the commands it runs.**
- **Pi itself would be killed.** `LimitCPU=` is per process, and Pi's own process lives for the whole session, so its CPU time keeps adding up. Five minutes suited the trial's half-hour tasks, but a long session would end with Pi killed.
- **A wrapper shell caps the commands instead.** If `settings.json` sets `shellPath`, Pi 1.5.0 runs every bash command as `<shellPath> -c '<command>'`. A wrapper that sets the limit and then execs bash caps each command and leaves Pi unlimited.
- **Put the soft limit below the hard one.**
  - With equal limits, a runaway command ends with SIGKILL: bash prints "Killed", exit 137, which reads like running out of memory.
  - A lower soft limit sends SIGXCPU first: "CPU time limit exceeded", exit 152.
  - Set the soft limit first. Lowering the hard limit below the current soft one (unlimited) fails with "Invalid argument".
- **Measured:** a 3-second cap ended an endless loop after 3 s with exit 152. Ubuntu's crash reporter wrote no report.

**Smaller things.**
- **`PI_OFFLINE=1`** turns off Pi's own network features: the version check and the model-list refresh.
- **What Pi writes.** With `PI_CODING_AGENT_DIR` set, Pi 1.5.0 wrote only `auth.json`, `models-store.json` and its sessions there, besides the launcher's `models.json` and `settings.json`. It created nothing else in the home directory.
- **What Pi loads by itself,** going by the names in its bundle:
  - from the working folder and every folder above it: `AGENTS.md`, `AGENTS.override.md` and `CLAUDE.md`;
  - from its agent directory: `SYSTEM.md`, `APPEND_SYSTEM.md`, extensions, skills, prompts and `mcp.json`.

  The launcher refuses to start a session while one of these sits above the project or in the agent's directory.

## 2026-11-10: models for an 8 GB card

Each model was downloaded, loaded at 32,768 tokens with every layer on the GPU, timed with setup's speed test and put through `toolcheck`. The candidates are the tool-calling models in Lemonade's catalog that fit 8 GB:

| Model | Download | VRAM at 32,768 tokens | Speed | `toolcheck` |
|---|---|---|---|---|
| Qwen3.5-4B-GGUF | 3.3 GB | 5.8 GB | 57.3 tok/s | 20/20 |
| Qwen3.5-4B-MTP-GGUF | 3.4 GB, 203 s | 6.3 GB | 86.8 tok/s | 20/20 |
| granite-4.0-h-tiny-GGUF | 4.0 GB, 263 s | 5.5 GB | 81.2 tok/s | 20/20 |
| Qwen3-4B-Instruct-2507-GGUF | 2.3 GB, 146 s | 8.2 GB | 70.0 tok/s | 18/20 |
| K2-Horizon-7B-GGUF | 5.2 GB, 322 s | doesn't fit: needs 4,608 MiB of KV cache alone; 8.4 GB at 16,384 | 42.3 tok/s | 20/20 |

- **Qwen3.5-4B-MTP is 1.5 times as fast** as the plain model, with the same tool calling and only 0.5 GB more VRAM. Lemonade loads it with `--spec-type draft-mtp`: multi-token prediction drafts tokens that the model then checks. At 65,536 tokens it ran at 90.5 tok/s and used 7.6 GB.
- **The models' design sets how much context fits.**
  - Qwen3.5 and granite-4.0-h are hybrids, so only some of their layers keep a KV cache.
  - Qwen3-4B-Instruct-2507 and K2-Horizon-7B use full attention in every layer. At 32,768 tokens, Qwen3-4B already fills the card, and K2-Horizon doesn't fit at all.
  - The failed K2-Horizon load is the case setup now explains. llama.cpp logged `allocating 4608.00 MiB on device 0: cudaMalloc failed: out of memory`.
- **`toolcheck` barely separates these models.**
  - The only misses came from Qwen3-4B-Instruct-2507, which doesn't reason first: it answered 401 for 17 × 23 both times.
  - The cases are simple single calls. Harder ones would be needed to rank models: several tools in sequence, long arguments, or a tool's error to recover from.
- **Sampler settings.** Lemonade has per-model sampler settings for the Qwen models (temperature 0.6 and top-p 0.85 for Qwen3-4B-Instruct-2507), but none for granite or K2-Horizon, which run on llama.cpp's defaults.
- **Lemonade hides what the machine can't hold.**
  - On the 8 GB box, `GET /api/v1/models?show_all=true` listed no catalog model larger than the machine could hold; its log reads `max model size: 8.0 GB`. That includes the MI300X candidates.
  - The installed package's full catalog is `/usr/share/lemonade-server/resources/server_models.json`. Read that when choosing models for a bigger machine from a small one.

## 2026-11-10: Pi agents on the RX 7600: how much context each agent needs

**The trial.**
- Pi 1.5.0 worked through six small coding tasks, Python and C, each graded by its own tests, against Lemonade on the same box. The model was Qwen3.5-4B-GGUF.
- Pi ran as a throwaway account inside a transient systemd service. The grader and the original tests sat in root-owned `/opt`, where the agent couldn't change them.
- The tasks, scripts and full results are kept outside this repository, with the owner's notes.

**Results.**

| Run | Agents at once | Context per agent | Passed | Wall time | Prompt tokens from cache |
|---|---|---|---|---|---|
| 1 | 1 | 65,536 | 6 of 6 | 31 min | 92% |
| 2 | 2 | 32,768 | 4 of 6 | 19 min | 84% |

**What it means for the kit.**
- **Give each agent at least 64K tokens.**
  - In run 1, one session peaked at 49,023 tokens and still passed.
  - In run 2, both failures ran out of room. Pi compacted its history four times in a row, and every compaction made the server re-read 22–24K tokens. Twice a reply hit the output limit, once cutting off an `edit` call's arguments.
  - On an MI300X, `-Slots 4 -CtxPerSlot 131072` gives each of four agents 128K.
- **A `length` stop ends Pi's print mode with exit code 0 and no output.** A harness has to grade the work, or read the transcript's last `stopReason`, to know that a session ran out of room.
- **Pi's `thinkingLevel: off` doesn't reach the model over `openai-completions`.** Qwen3.5 reasoned anyway, as its chat template does by default. Lemonade doesn't count reasoning tokens separately; they are inside the output tokens.
- **Every tool call was well formed.** The tool errors Pi recorded (26 in run 1) were bash commands that failed, such as failing tests and compiler errors.
- **Pi's bash tool has no timeout.**
  - With Qwen3.5-4B-MTP, the agent twice edited code into an endless loop: a binary search, then `clz64`. The test run then spun at 100% CPU until the task's 25-minute limit stopped Pi, with the agent waiting on it the whole time.
  - The agents' service now sets `LimitCPU=300`, which kills any single process after five minutes of CPU, and the agent gets the error back. For a session longer than the trial's, that limit would also kill Pi itself. The entry above moves it to the commands Pi runs.
  - Rerun with the limit, the MTP model passed 5 of 6. The sixth ran out of time one case short of passing (`INT64_MAX / INT64_MIN`).
- **Multi-token prediction pays off in agent use.** Over a whole run, Qwen3.5-4B-MTP produced 77.7 output tokens per second of model time, against 52.6 for Qwen3.5-4B: 1.48 times as fast. Task times still varied more with each run's path than with the model.
- **The confinement held.** These systemd properties gave the agent only what it needed:
  - `IPAddressDeny=any` with `IPAddressAllow=localhost`;
  - `ProtectSystem=strict` with `ReadWritePaths=` its home;
  - `PrivateTmp`, `NoNewPrivileges` and `MemoryMax=3G`.

  A probe confirmed Lemonade answered on localhost while the internet was blocked. `/etc` and the grader were read-only, the home was writable, and `sudo` was refused. This is one way to enforce the clean-room block on the agents' machine without a Pi extension.

  **Later found incomplete:** allowing localhost reaches every local service, and some of them act on the network for the agent. The entry above replaces it with a private network namespace and a gate.

## 2026-11-10: setup from nothing, as on a new droplet

**The wipe.**
- Lemonade was removed from the box completely:
  - the package, purged;
  - its `lemonade` system user;
  - `/var/lib/lemonade` and `/var/cache/lemonade` (20 GB of models and backends);
  - the PPA's source file;
  - the three libraries only it used.
- `apt autoremove` would also have removed three unrelated video-decode packages, so it wasn't used.
- `collect` saved the records first, as `down` does.

`setup -Model Qwen3.5-4B-GGUF -CtxPerSlot 65536` then ran from scratch, with no errors: 347 s from the PC, 5:44 on the box's clock. Step headings now show the time since the start:

| Step | Took |
|---|---|
| Install Lemonade from the PPA (add the source with `-n`, update apt, install) | 16 s |
| Start the service | 8 s |
| Configure | 6 s |
| The llama.cpp ROCm backend: 0.3 GB, plus its own ROCm 10.1 runtime as 2.0 GB of wheels | 1:49 |
| Download Qwen3.5-4B-GGUF, 3.3 GB | 3:03 |
| Load (65,536 tokens, 7.0 of 8.6 GB) | 5 s |
| Smoke tests (chat, tool call, 57.4 tok/s) | 17 s |

- **Downloads.** About 5 of the 5:44 minutes went on downloads, at about 18 MB/s on a home connection. On a droplet the other steps should take a minute or two, plus the model's download.
- **First live runs.** Adding the PPA with `-n` and the retrying update after it ran cleanly, as did a first-time backend install and a first pinned load.
- **Usage across installs.** `collect` reported usage across the old and new installs, because the systemd journal outlives the package. A new droplet's journal starts empty.
- **vLLM speed.** Lemonade's telemetry logs `ttft=0.00s, tps=0.00` for every vLLM request, so `collect` averaged vLLM's speed to 0.0 tok/s. It now averages only requests that report a speed, and says "speed not reported" otherwise.

## 2026-11-10: the vLLM-on-MI300X change, rehearsed on the RX 7600

`vllm-test -BuildOnly` runs the droplet test's first half on any box: patch Lemonade, build it, run the unit test and regenerate the generated docs. It stops before anything needs an MI300X.

**Upstream status.**
- `lemonade-sdk/lemonade#3669`, which enabled gfx942 and gfx950 for vLLM, was opened and closed by its author within 18 minutes on 2026-09-25. It was a draft and has no comments or reviews.
- Its description reports that the stable gfx942 vLLM build doesn't start: a `tokenizers`/`transformers` version clash and an undefined torch symbol in `vllm/_C.abi3.so`. It therefore points gfx942 at the nightly build.
- No later PR takes this up. `main`'s `vllm.h` still leaves gfx942 out, with the same lines our patch changes.

**On the box, against `main` at `14a09e179`:**

| Step | Result |
|---|---|
| Patch | applied cleanly: 2 files, 8 lines in, 8 out |
| Build | 17 minutes, 742 steps, on a 4-core i5-6600K |
| `test_vllm_cdna_gating` | 44 checks passed, none failed, among them "vllm:rocm gfx942 (MI300X) is advertised installable" |
| Generated docs | regenerated: `README.md`'s support table and `docs/dev/backends-reference.md` gain gfx942, so the change is 4 files |

The droplet hour can now go straight to the vLLM releases.

**Bug found on the way.**
- The test's environment step ran `rocminfo | grep 'Marketing Name:.*(MI|Instinct)'`. On a Radeon, nothing matched, and under `set -euo pipefail` the script ended there without a message (`status=1/FAILURE` after "Preflight").
- An MI300X always matches, so the droplet never showed it.
- It now tolerates no match, and lists Radeon names too.

**Also changed.** `logs` and `report` work from an account other than root: `report` copies the report out of `/root` with `sudo` before `scp`.

## 2026-11-10: a tool-calling check

`toolcheck` sends a fixed set of requests with three tools (`get_weather`, `convert_currency`, `search_files`):
- **Choosing a tool.** Five cases need the right tool with the right arguments, for example `amount == 250` from `USD` to `EUR`.
- **No tool.** Two cases need no tool at all.
- **Round trip.** One case gives the model a tool's result, which it must use in its answer (18 °C and light rain).
- **Claude Code's API.** Two of the choosing cases also go through `/v1/messages`.

Each case runs twice with the model's own sampling settings and thinking left on, as an agent would run it.

**Qwen3.5-4B-GGUF: 20 of 20 in 72 s**, including loading the model. The set may be too easy to separate stronger models; the 8 GB model survey will show whether it separates weaker ones.

## 2026-11-10: filling the context, and a GPU that also drives a screen

The new `depth` command sends prompts of a given size: a made-up weather log with an access code hidden halfway down. It records how long the model took to read the prompt, whether it found the code, and how fast it then generated at that depth. Last, it sends a prompt longer than one slot's context. Qwen3.5-4B-GGUF, one slot:

| Prompt | Read in | Reading speed | Code | Generation at that depth |
|---|---|---|---|---|
| 8,047 tokens | 4.5 s | 1,793 tok/s | found | 54.2 tok/s |
| 31,981 | 21.9 s | 1,459 tok/s | found | 46.7 tok/s |
| 60,016 | 50.9 s | 1,180 tok/s | found | 40.2 tok/s |
| 119,913 | 142.9 s | 839 tok/s | found | 30.8 tok/s |

- **At depth.** Reading and generation both slow as the context fills. An agent turn that re-reads 120K tokens would take more than two minutes on this card. In practice the prompt cache spares most of that, because each turn only reads what is new.
- **Overrunning the context.** A request longer than the context gets a clean HTTP 400: `request (134947 tokens) exceeds the available context size (131072 tokens), try increasing it`. Pi has to compact before then.

**The 120K prompt first crashed the server.** On the first try, at the 131,072-token default with the box's login screen running:
- The kernel's OOM killer killed llama-server (exit 137).
- systemd then stopped the whole `lemond` unit (`Failed with result 'oom-kill'`) and restarted it.
- The first llama-server after the restart logged `failed to initialize ROCm: no ROCm-capable device is detected`.

**The cause was the screen, not the model.**
- The RX 7600 also drives the box's monitor (HDMI connected, GDM's login screen). The kill happened inside the GPU driver, while the display was pinning a framebuffer: `amdgpu_dm_plane_helper_prepare_fb` → `amdgpu_bo_pin` → `ttm_bo_evict` → `ttm_bo_bounce_temp_buffer` → `__ttm_pool_alloc`.
- With VRAM full, the driver moves other buffers into system RAM to make room for the screen, and that allocation failed.
- llama-server held only 1.3 GB of anonymous memory when it was killed, so its own use of system RAM wasn't the cause.
- **The same 120K prompt with the login screen stopped** went through, at the speeds in the table. VRAM ended at 8.6 of 8.6 GB, 0.2 GB more than after loading.
- **Starting the login screen again** with VRAM in that state got llama-server killed once more, by the display thread itself (`KMS thread invoked oom-killer`).
- **At 65,536 tokens,** VRAM peaks at 6.6 GB. With the screen on, the 8K, 32K and 60K rows above all passed.

**Changes.**
- When a GPU with a screen connected has less than 1 GB of VRAM free after loading, setup now warns and suggests a smaller `-CtxPerSlot` or stopping the desktop while serving. Checked: it warns at 131,072 (0.2 GB free) and stays quiet at 65,536 (2.2 GB free).
- The ROCm box now runs with `-CtxPerSlot 65536`.
- A droplet's MI300X drives no screen.

**The desktop is now off on the box.**
- On the owner's go-ahead, GDM was stopped and the box set to boot to text mode (`systemctl set-default multi-user.target`).
- That freed 0.6 GB of VRAM: from 7.9 to 7.3 GB with Qwen3.5-4B-MTP loaded at 65,536 tokens. The kernel logged no errors during the switch.
- The HDMI cable is still plugged in, so the connector still reads `connected`. Setup's check therefore now also requires a running display server (a display manager, or a compositor such as `gnome-shell` or `Xwayland`). A text console alone takes a few MB and didn't cause trouble: the 120K prompt passed with GDM stopped.
- To bring the desktop back: `sudo systemctl set-default graphical.target`, then `sudo systemctl start gdm`.

**llama.cpp's prompt cache.**
- llama-server keeps earlier prompts' KV cache in system RAM, up to 8 GiB by default (`--cache-ram`). That is more than this box's 7.9 GB.
- It wasn't the cause here, but available RAM fell by 1.6 GB over three long prompts as the cache filled.
- Setup now caps it at a quarter of RAM: 1,972 MiB here, and llama.cpp's own 8,192 on a machine with more than 32 GiB.

## 2026-11-10: near full VRAM, llama.cpp quietly moves layers to the CPU

**Seen.** With one slot, setup used to let Lemonade pick the context (`--ctx-size=-1`). On the same card, with the same model and Lemonade version, it picked 95,354 tokens on 2026-11-09 and 98,631 on 2026-11-10. The larger pick generated about 20% slower.

**How Lemonade picks.**
- Lemonade sizes the context when the model loads, from the VRAM free at that moment.
- It takes the card's total minus what is in use, then subtracts the weights and a reserve for headroom and compute buffers. The rest becomes context (`src/cpp/include/lemon/auto_context_budget.h` on Lemonade's main branch).
- The server log records the result, for example `Auto-tune ctx_size resolved to 98631`.

**Why the larger pick ran slower.**
- Lemonade starts llama-server with an explicit `--ctx-size` but no `-ngl`.
- This llama.cpp build (b11836) defaults to `-ngl auto` with `--fit on`, "whether to adjust unset arguments to fit in device memory", keeping a margin of 1024 MiB (`--fit-target`).
- When the context leaves less than that margin, fit moves layers to the CPU. At Lemonade's log level nothing says so.
- Run by hand with fit on, llama-server held VRAM at 7.6 GB at both 98,631 and 131,072 tokens: the card's 8.6 GB less the margin.

Qwen3.5-4B-GGUF, one slot, setup's 768-token speed test, two runs at each size:

| Context | llama.cpp's default (`--fit on`) | `--fit off -ngl all` |
|---|---|---|
| 65,536 | 57.1 and 57.2 tok/s, 6.9 GB | |
| 95,354 | 57.5 and 57.5 tok/s, 7.9 GB | |
| 98,631 | 46.4 and 46.1 tok/s, 7.9 GB | 55.7 and 53.8 tok/s, 8.1 GB |
| 131,072 | 15.4 and 16.9 tok/s, 8.0 GB | 51.3 and 52.9 tok/s, 8.3 GB |
| 262,144 | | Load fails: `cudaMalloc failed: out of memory` for an 8,192 MiB KV cache |

GTT (system memory mapped for the GPU) stayed at 766 MB throughout, so the CPU-side layers don't show up there.

**Fix.**
- Setup now pins the context at slots × `-CtxPerSlot`, one slot included. The default is 131,072 tokens.
- It adds `--fit off -ngl all` to the server-wide `llamacpp.rocm_args`. Every layer then goes on the GPU, or the load fails.
- When a load fails, setup reads llama.cpp's lines from the server log and says the model and context don't fit. Lemonade's own message suggests missing drivers or an incompatible model file.
- Lemonade saves the requested settings even when the load fails, so setup's message also says the model won't load on demand until setup succeeds.

**Tested on the RX 7600.**
- Default setup, one slot, 131,072 tokens: 8.4 of 8.6 GB, smoke tests passed, 57.2 and 56.9 tok/s.
- Four slots of 32,768: 8.5 GB, smoke tests passed, 57.3 tok/s.
- 262,144 tokens: setup stopped after 43 s with llama.cpp's lines, starting `allocating 8192.00 MiB on device 0: cudaMalloc failed: out of memory`, and the message above.

**The first failure check missed.** It piped `journalctl` into `grep -q`. grep stops at the first match, which can end journalctl with SIGPIPE, and under `set -o pipefail` the pipe then counts as failed. Setup now reads the log into a variable first.

**Pi's context window.**
- With several slots, Lemonade reports the whole context (`context_length` 131,072 for 4 × 32,768), and `pi` passed that on: four times what one agent's requests get.
- `pi` now divides by the `--parallel` value. It reads that from `/api/v1/health`, or from `/internal/config` if the model isn't loaded yet.
- With 4 × 32,768 it told Pi 32,768 tokens.

**On an MI300X**, the default model leaves well over 100 GB of VRAM free, so fit wouldn't have moved anything. The flags matter on small cards and for models near the limit.

## 2026-11-10: an unattended upgrade held apt for 24 minutes

- **What happened.**
  - Ubuntu's daily unattended upgrade held apt's lock from 06:30 to 06:55 local time.
  - It upgraded about 150 packages, including systemd, OpenSSH, sudo and a new HWE kernel (7.0.0-42), and auto-removed an older kernel.
- **Setup's wait was too short.**
  - A setup started during the upgrade waited its 10 minutes and then carried on anyway. The upgrade happened to finish a minute later.
  - The apt retry added earlier that day also waited for the lock again before each of its three tries.
- **Fix.**
  - `wait_for_apt` now waits up to 30 minutes. Every 5 minutes it names the process holding the lock: `Waiting for unattended-upgr to let go of apt (5 min so far)...`.
  - `apt_update` waits once, then retries.
  - A stub test checked a lock held for 3 and 70 checks (released, no warning) and one never released (one warning at 30 minutes).
- **The GPU driver module was rebuilt, and works.**
  - DKMS built amdgpu for the new kernel during the upgrade: `dkms status` lists amdgpu 7.1.9 for both 7.0.0-30 and 7.0.0-42.
  - The box rebooted onto 7.0.0-42 and was back within a minute. The DKMS module loaded (`updates/dkms/amdgpu.ko`, 7.1.9.31600000).
  - `rocm` passed: `rocminfo`, `amd-smi` (ROCm 10.1.0), the HIP test on the RX 7600 and the gfx942 cross-build.
  - Lemonade's setup and smoke tests passed at 57.1 tok/s.
  - The boot log has no amdgpu errors, only two display `REG_WAIT timeout` messages from mode setting.
- **On a droplet**, the same timers can fire soon after first boot. Once an upgrade is running, waiting is the only safe choice, at $1.99/hour.

## 2026-11-10: an Ubuntu mirror mid-sync stopped setup

- **What happened.** A re-run of `setup` died at its first `apt-get update`, with exit code 100:

  ```
  E: Failed to fetch http://us.archive.ubuntu.com/ubuntu/dists/noble-updates/main/i18n/Translation-en.xz  File has unexpected size (314236 != 314404). Mirror sync in progress?
  E: Some index files failed to download. They have been ignored, or old ones used instead.
  ```

  apt itself goes on with the old package lists after this, but the exit code stopped the script (`set -e`). On a droplet, the same error would stop setup while the GPU bills.
- **Fix.**
  - `apt_update` in `remote/lib.sh` tries three times, 20 seconds apart, then continues with the package lists already on the machine. If a package is then missing, the install after it fails with apt's own error.
  - `rocm-box/setup-rocm-box.sh` has the same retry.
  - `add-apt-repository` now runs with `-n`, which skips its built-in update (that update doesn't retry). Setup runs `apt_update` straight after.
- **Tested twice.**
  - With `apt-get` replaced by a stub that fails 0, 2 or 5 times, `apt_update` called it 1, 3 and 3 times, and the script carried on each time.
  - The next real run hit another mirror mid-sync (`noble-updates/universe/binary-amd64/Packages.xz`, 1710932 != 1711124). The first try failed, and the retry 20 seconds later worked.

## 2026-11-10: Lemonade's vLLM backend on an RX 7600 (gfx1102)

Lemonade lists `vllm:rocm` as installable on this card; its docs say the RDNA 3 builds exist but have not been tried end to end.

- **Install worked.** `lemonade backends install vllm:rocm` fetched `vllm0.20.1-rocm7.12.0-gfx110X` (two parts) and installed it in 284 s. Pulling `Qwen3.5-0.8B-FP16-vLLM` took another 102 s.
- **Loading failed.** `lemonade load` failed after 453 s, including Lemonade's one retry, with `vllm-server failed to start`. The root cause in the server log was `torch.AcceleratorError: HIP error: device kernel image is invalid` (`hipErrorInvalidImage`).
- **The cause:** the bundle's vLLM kernels were built for every RDNA 3 chip except this one.
  - The bundle's PyTorch 2.10.0+rocm7.12.0 includes gfx1102. `torch.cuda.get_arch_list()` returns gfx1100, gfx1101, gfx1102 and gfx1103, and plain PyTorch GPU operations run fine on the card.
  - vLLM's own compiled kernels (`_C`, `_moe_C`, `_rocm_C`) hold code for gfx1100, gfx1101, gfx1150, gfx1151, gfx1200, gfx1201, gfx90a, gfx942 and gfx950. gfx1102 and gfx1103 are missing.
  - Lemonade maps gfx1102 to the gfx110X bundle and installs it, so on an RX 7600 (and gfx1103 parts) the first vLLM kernel fails.
- **Workaround: tell ROCm the card is a gfx1100.**
  - The override was set for the `lemond` service in a temporary systemd drop-in:

    ```
    [Service]
    Environment=HSA_OVERRIDE_GFX_VERSION=11.0.0
    ```

  - The ROCm runtime then treats the RX 7600 as a gfx1100 (the RX 7900 chip) and loads that chip's kernels. The model loaded and served.
  - This also supports the diagnosis: the kernels were missing, not broken.
  - **Load.** It took 272 s. The weights loaded in 4 s; most of the rest went on vLLM's start-up after that (3 min 12 s until it set up its KV cache). Lemonade sized the context at 18,724 tokens, and vLLM reserved 4.0 GiB for its KV cache.
  - **Speed** (`bench`, 256 tokens per request, two runs):

    | Requests at once | In total | Each |
    |---|---|---|
    | 1 | 33.0 and 31.1 tok/s | 33.0 and 31.1 tok/s |
    | 4 | 103.9 tok/s | 26.0 tok/s |
    | 8 | 197.9 tok/s | 24.7 tok/s |

    Eight requests at once ran at about six times the throughput of one, each at 75 to 80% of solo speed.

    The model differs from the llama.cpp bench (0.8B at 16-bit against 4B at 4-bit), so the two benches don't compare the engines.
  - **Undone afterwards.** The drop-in was removed, so vLLM fails on this card again. Its backend and the model stay installed.
- **Worth reporting upstream** (lemonade-sdk/vllm-rocm): add gfx1102 and gfx1103 to the vLLM build's target list, or stop advertising `vllm:rocm` on those cards until it does.

## 2026-11-10: several agents at once

`bench` timed Qwen3.5-4B-GGUF (UD-Q4_K_XL) on the llama.cpp ROCm backend (build b11836), asking 256 tokens per request:

| Slots | 1 request | 4 at once, in total | Per request, 4 at once |
|---|---|---|---|
| 1 (Lemonade's default) | 57.4 tok/s | 56.3 tok/s (they queue) | 14.1 tok/s |
| 4 (16,384 tokens each) | 57.2 tok/s | 149.7 tok/s | 37.4 tok/s |

With four slots, four requests run at 2.6 times the throughput of one. Each request still runs at two-thirds of solo speed.

**Bug: `-Slots` dropped the model's sampler settings.**
- `setup -Slots 4` passed `--parallel 4` as the model's own `llamacpp_args`. Lemonade then replaced, rather than merged, the arguments it applies per model architecture.
- Those come from `resources/architecture_defaults.json`. Its comment: "Values are recipe option key-value pairs that override global config defaults but are overridden by model-level recipe_options."
- For Qwen3.5 they are `--temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.00 --repeat-penalty 1.0` and `--chat-template-kwargs '{"preserve_thinking":true}'`. The last keeps the model's reasoning across turns of an agent conversation.
- Agents would have quietly run with llama.cpp's generic sampling.

**Fix.** Setup now puts `--parallel N` in the server-wide `llamacpp.rocm_args` setting. The loaded model then reported both:

```
--chat-template-kwargs '{"preserve_thinking":true}' --min-p 0.00 --parallel 4 --repeat-penalty 1.0 --temp 1.0 --top-k 20 --top-p 0.95
```

The catch is that the slot count applies to every llama.cpp model on that server. `-Slots 1` cleared the setting and loaded with `--ctx-size=-1`, so Lemonade picked the context. Setup now pins it; see the entry above on llama.cpp moving layers to the CPU.

**Checked end to end through setup.**
- `setup -Slots 4 -CtxPerSlot 16384` took 87 s on a box that already had everything downloaded. The model loaded with `ctx_size` 65,536 and the arguments above, and all three smoke tests passed.
- A plain `setup` then put back one slot: the sampler settings with `--parallel 1`, and an automatic context, which setup no longer uses.

## 2026-11-09: what to save before a droplet is destroyed

On Ubuntu, the Lemonade package keeps:

| What | Where |
|---|---|
| Config | `/var/lib/lemonade/config.json` (only the settings changed from defaults) |
| Saved load options per model | `/var/lib/lemonade/recipe_options.json` |
| Server log | the systemd journal for the `lemond` unit; there is no separate log file |
| Backends | `/var/cache/lemonade/bin/<recipe>/<backend>/`, each with a `version.txt` |
| Models | `/var/lib/lemonade/.cache/huggingface/hub/`; each repository's `refs/main` holds the revision it was pulled at |

**Usage data.** The server log has one line per request:

```
(Telemetry) Inference completed: model=Qwen3.5-4B-GGUF, tokens=800 (in=32, out=768), ttft=0.09s, tps=57.87
```

`GET /api/v1/stats` returns running totals: requests, input, output and cached tokens.

**What `collect` saves.** It gathers all of this, plus `/api/v1/health`, `/api/v1/models` and `/api/v1/system-info`. On the test machine it took about 20 seconds and made a 15 KB archive. `down` now runs it before destroying a droplet and then writes `lease.json` with the hours and approximate cost. The doctl half of `down` has not run yet.

## 2026-11-09: droplet setup, rehearsed on a local box

`setup -Machine <box> -Model Qwen3.5-4B-GGUF` ran the droplet's steps end to end in about 10 minutes:
- **Downloads:** almost all of the time.
- **Context and memory:** Lemonade chose a 95,354-token context, filling 8.0 of the card's 8.6 GB.
- **Smoke tests:**
  - A chat reply arrived.
  - A `/v1/messages` tool call came back (`get_weather`, `{"city":"Paris"}`).
  - 768 tokens took 13.5 s, 57.0 tok/s.
- **From the PC:** Pi, run through `tunnel`, read a file with its read tool and answered with a code word it could not have guessed. It took 6 seconds.

**Bug: about 40 minutes of waiting for apt.**
- `wait_for_apt` matched process names. Ubuntu's always-running `unattended-upgrade-shutdown --wait-for-signal` shows up under the same short name, `unattended-upgr`, as a real unattended upgrade.
- So every apt step waited its full 10 minutes, though nothing held apt's locks.
- It now checks the lock files' holders with `fuser`. On a droplet the old version would have cost about 40 minutes of GPU time per setup. Fixed in `702f7c4`.

**Lemonade downloads its own ROCm.**
- The llama.cpp ROCm backend brought a ROCm 10.1 runtime as pip wheels: `rocm_sdk_core` (419 MB), `rocm_sdk_libraries` (680 MB) and `rocm_sdk_device_gfx1102` (906 MB).
- It did this although ROCm 10.1 was already installed in `/opt/rocm`. ROCm 10's layout puts the runtime under `/opt/rocm/core-10.1/`, which may be why Lemonade didn't find it (unconfirmed).
- That's about 2 GB per fresh machine. Open question: does setting `ROCM_PATH` for the service avoid it?

**Model download.** The 4B model was 2.8 GB plus a 0.6 GB vision projector, at about 19 MB/s on a home connection.

## 2026-11-09: ROCm 10.1 on an RX 7600

- **What `amdgpu-install` installed.** `amdgpu-install` 31.60 with `--usecase=rocm,graphics --gfxversion=auto` installed AMD's full `amdrocm` package set, with libraries for every GPU target, gfx942 (MI300X) among them. The install took about 18 minutes, most of it unpacking and building the kernel module. The module was built only for the running kernel.
- **Missing HIP headers.**
  - That install has no HIP headers, so `hipcc` failed with `'hip/hip_runtime.h' file not found`.
  - `amdrocm-core-sdk10.1` adds them, along with the libraries' development files (74 packages). `amdrocm-developer-tools10.1` adds `rocprofv3` and `rocgdb`. Together they take about 3.3 GB and installed in 75 seconds.
  - `rocm-box/setup-rocm-box.sh` installs both since `74f973b`.
- **HIP test.** With the SDK in place, the test program reported `AMD Radeon RX 7600 (gfx1102), 16 compute units, wavefront size 32, 8.6 GB` and checked 16,777,216 additions. The card has 32 compute units, so HIP appears to count them in pairs on RDNA 3; that is a reading, not something checked. The same source also builds for gfx942.
- **A closed terminal didn't stop the install.**
  - Closing the SSH session in the middle of the install didn't stop apt: it was reparented to init and finished cleanly (`dpkg --audit` came back clean).
  - The script around it died, though, so its last step (adding the user to the `render` and `video` groups) had to be done by hand.
  - Open question: run the long install pass detached with `systemd-run`, as `vllm-test` already does.
- **Ubuntu point release.** The machine reported Ubuntu 24.04.4, while ROCm 10.1's compatibility matrix lists 24.04.5 with the 7.0 HWE kernel. It worked on the HWE kernel.
- **Old NVIDIA driver.** A leftover NVIDIA 580 driver package set was removed: a dry run first showed exactly 19 packages would go. apt then offered to autoremove `pkg-config` and the OpenCL loader too, so those were marked to keep.

## 2026-11-09: one sign-in per machine

- **Five password prompts.** The first ROCm setup run asked for five passwords: one SSH login for each of four connections, then `sudo`.
- **`key`.** It installs the SSH key, leaving one `sudo` prompt per run.
- **`grant`.** It creates a key-only `leasehold` account with passwordless `sudo`, and saves the machine by name. Assistants can then work without prompting at all: `run -Machine <name>`, or `-Machine` on any command.

---

## Open questions

- Can Lemonade reuse a system ROCm 10.1 instead of downloading about 2 GB of its own?
- Should long remote installs run detached (`systemd-run`) so a dropped SSH session can't stop them halfway?
- The PPA release pins llama.cpp b11836, while Lemonade's main branch is on b12109. Does the difference matter for the models in use?
- Should setup stop Ubuntu's apt timers on a droplet, so an upgrade soon after first boot can't hold apt while the GPU bills?
