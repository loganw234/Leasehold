# Leasehold

Stand up, prove and tear down [Lemonade](https://github.com/lemonade-sdk/lemonade) model endpoints on rented AMD GPUs or your own box.

Leasehold runs from a Windows PC. It installs Lemonade on an AMD Developer Cloud MI300X droplet, or on any Ubuntu 24.04 machine you can SSH into, and loads a model there. Your agents stay on your PC and reach the model through an SSH tunnel, so the server is never exposed to the internet.

It's the deployment kit that [HonestHarness's research notes](https://github.com/loganw234/HonestHarness/blob/main/Research/open-weight-pilot-notes.md) call for: the harness needs only a model's address, and the kit stands up the machine behind it.

**Status: early.** It has run against a local Radeon RX 7600 box but not yet on an MI300X droplet, so expect fixes on the first droplet runs. [docs/FINDINGS.md](docs/FINDINGS.md) has what the test runs showed.

| Path | Runs on | What it does |
|---|---|---|
| `leasehold.ps1` | your PC | Uploads and runs the remote scripts, opens the SSH tunnel, starts Pi or Claude Code, sets up a ROCm box, fetches reports, lists and destroys droplets |
| `remote/setup-lemonade.sh` | the remote machine | Installs Lemonade from its stable PPA, loads a model on the llama.cpp ROCm backend, runs smoke tests |
| `remote/vllm-gfx942-test.sh` | an MI300X | Builds Lemonade with `vllm-enable-gfx942.patch` and tests which vLLM-ROCm build works on gfx942 |
| `remote/lib.sh` | the remote machine | Helpers shared by the remote scripts |
| `remote/collect.sh` | the remote machine | Gathers Lemonade's records before a lease ends (`collect`, `down`) |
| `remote/bench.sh` | the remote machine | Times one request, then several at once, against the loaded model (`bench`) |
| `remote/depth.sh` | the remote machine | Times long prompts and checks the model finds a fact deep in them (`depth`) |
| `remote/grant-operator.sh` | the remote machine | Creates the account AI assistants use (`grant`) |
| `AGENTS.md` | AI assistants | What assistants may do on granted machines, and what to ask first |
| `docs/FINDINGS.md` | you | What running the kit has shown: measurements, bugs found and fixed, open questions |
| `rocm-box/` | your own Ubuntu box | Installs ROCm 10.1 and checks HIP with a small test program; see [its README](rocm-box/README.md) |

## Requirements

- Windows PowerShell 5.1 or newer, with the OpenSSH client that ships with Windows 10 and 11.
- For `pi`: Node.js 22.19 or newer, and [Pi](https://github.com/earendil-works/pi): `npm install -g @earendil-works/pi-coding-agent`.
- For `claude`: Claude Code on PATH.
- Optional, for `status`, `down` and `up`: [doctl](https://github.com/digitalocean/doctl/releases), set up with `doctl auth init`.
- Your SSH public key added to your AMD Developer Cloud account, or to your box.

## A session on an MI300X droplet

1. **Create the droplet in the console:** On-demand, MI300X (1 GPU), the "ROCm Software" Quick Start image (10.1), and your SSH key. Copy its IP address.
2. **Set it up** (about 15 minutes the first time):
   ```powershell
   .\leasehold.ps1 setup -Ip <droplet-ip>
   ```
   The IP is remembered for later commands. Options are `-Model`, `-Slots`, `-CtxPerSlot` and `-MaxModels`. If the connection drops, run it again: finished steps are skipped and downloads resume.
3. **Open the tunnel** in a second terminal and leave it open:
   ```powershell
   .\leasehold.ps1 tunnel
   ```
4. **Start Pi from your project folder:**
   ```powershell
   path\to\Leasehold\leasehold.ps1 pi -Model Qwen3.6-35B-A3B-GGUF
   ```
   - It writes Pi's provider config the way `lemonade launch pi` does, using the context size Lemonade reports for the model. With several slots, Pi gets one slot's share.
   - Pi's config and sessions go in `pi-agent\` next to the script, or the folder you pass with `-PiDir`. Nothing goes in `~\.pi` or `~\.claude`.
   - Arguments after `--` go to Pi.

   `claude` works the same way, with the variables `lemonade launch claude` sets, for that run only. It hides any `ANTHROPIC_API_KEY` so a real key never reaches the server, but it still loads your `~\.claude` settings, hooks and memory.
5. **Destroy the droplet when you're done.** Powering it off does not stop billing.
   ```powershell
   .\leasehold.ps1 down
   .\leasehold.ps1 status
   ```
   Before it destroys anything, `down` saves the droplet's records to `reports\records-<name>-<time>\` on your PC:
   - `summary.txt`: the versions that ran, each model with the Hugging Face revision it was pulled at, and token usage per model.
   - The server's log, Lemonade's config, and its health, stats and system info.
   - The setup log, and the vLLM test's report if there is one.

   After the droplet is destroyed, `down` adds `lease.json` with the hours and approximate cost. `collect` saves the same records at any time, from any machine; `down -NoCollect` skips them. Without doctl, run `collect`, then destroy the droplet in the console: Droplets → your droplet → Destroy.

## Your own Ubuntu box

Every command also works against any Ubuntu 24.04 machine you can SSH into. Pass your login with `-User` (the default is `root`, the droplet's login); commands that need root then go through `sudo`, which asks for your password. Run `key` first: it adds your SSH public key to the machine, so later commands don't ask for the login password on every connection.

[rocm-box/README.md](rocm-box/README.md) covers installing ROCm 10.1 on a Radeon card with the `rocm` command. After that, `setup`, `tunnel` and `pi` rehearse a droplet session for free. The remembered IP is the last machine you ran `setup`, `rocm` or `up` against, so pass `-Ip` when you switch machines.

## Letting AI assistants use a machine

Run `grant` once per machine, as yourself:

```powershell
.\leasehold.ps1 grant -Machine rocm-box -Ip <box-ip> -User <your-login>
```

`grant` does four things:
- Creates a `leasehold` account on the machine that logs in with your SSH key only and runs `sudo` without a password.
- Adds it to the GPU and USB device groups.
- Checks that it works without prompts.
- Saves the machine as `rocm-box` in `machines.json`, which stays on your PC.

It asks for at most two passwords: your login password, only if your key isn't on the machine yet, and then `sudo`'s.

After that, an assistant can work on the machine without prompts:

```powershell
.\leasehold.ps1 run -Machine rocm-box -- 'rocminfo | grep -m1 gfx'
.\leasehold.ps1 rocm -Machine rocm-box
```

Each `run` is appended to `runs.log`. [AGENTS.md](AGENTS.md) tells assistants what they may do and what to ask you first.

**This gives the account full root on that machine.** Grant it only on a machine you would hand an assistant anyway, with nothing sensitive on it. To take it back:

```powershell
.\leasehold.ps1 revoke -Machine rocm-box -User <your-login>
```

## Context size

Setup pins the context at `-Slots` × `-CtxPerSlot` tokens, 131,072 by default, and puts every layer of the model on the GPU. If that doesn't fit in VRAM, the load fails and setup shows llama.cpp's error; run it again with a smaller `-CtxPerSlot`. On an 8 GB card, Qwen3.5-4B fits 131,072 tokens with one slot, but only if the card drives no screen (see below).

Setup overrides three defaults:
- **Lemonade's own pick.** Lemonade works the context out from the VRAM free when the model loads, so it can differ from one load to the next.
- **llama.cpp's fitting.** When a context leaves less than 1 GiB of VRAM spare, llama.cpp moves layers to the CPU instead of failing (`--fit on`), and nothing in Lemonade's log says so. On an 8 GB card that made generation up to 3.5 times slower. Setup passes `--fit off -ngl all`.
- **llama.cpp's prompt cache.** llama.cpp keeps earlier prompts' KV cache in system RAM, up to 8 GiB by default (`--cache-ram`). Setup caps it at a quarter of the machine's RAM.

**A GPU that also drives a screen** needs VRAM of its own. When the screen asks for some and none is free, the driver moves the model's buffers into system RAM. On an 8 GB card at 131,072 tokens, that got llama-server killed by the OOM killer, both during a 120K-token prompt and when the login screen restarted. Setup warns when such a card has less than 1 GB free. Leave that much with a smaller `-CtxPerSlot` (65,536 on the RX 7600), or stop the desktop while serving. A droplet's MI300X drives no screen.

To see what a long context costs, `depth` sends prompts of 8K to 120K tokens. It checks that the model finds a fact hidden halfway down, and shows what a request longer than the context gets (HTTP 400):

```powershell
.\leasehold.ps1 depth -Model Qwen3.6-35B-A3B-GGUF -Depths '8000 64000 120000'
```

On the RX 7600 with Qwen3.5-4B, reading slowed from about 1,800 to 840 tokens/s between 8K and 120K, and generation from 54 to 31 tokens/s. [The findings](docs/FINDINGS.md) have the measurements.

## Several agents at once

By default, Lemonade gives each model one request at a time, so a second agent waits for the first. To serve four at once:

```powershell
.\leasehold.ps1 setup -Slots 4 -CtxPerSlot 131072
```

llama.cpp splits the context across the slots, so each gets `-CtxPerSlot` tokens. `pi` tells Pi that share, not the total Lemonade reports.

The slot count and the flags above go in Lemonade's server-wide `llamacpp.rocm_args` setting, so they apply to every llama.cpp model on that server. That keeps the sampler settings Lemonade applies per model family; passing them as a model's own arguments would replace them.

To keep two different models loaded together, raise `-MaxModels`. Running setup again reloads the model with the new settings, and `-Slots 1` puts back one slot.

To see what slots buy, `bench` times one request and then several at once:

```powershell
.\leasehold.ps1 bench -Model Qwen3.6-35B-A3B-GGUF -Concurrency 4
```

On an RX 7600 with Qwen3.5-4B, four requests at once ran at 150 tokens/s in total, against 57 for one request alone. With one slot, the four requests queue and run at 56 tokens/s in total.

## Models

Any model in Lemonade's catalog works, as does a Hugging Face GGUF that Lemonade can pull. On one MI300X (192 GB), up to about 170 GB of weights leaves room for context. Some catalog models, with the download sizes Lemonade lists:

| Model | Size | Notes |
|---|---|---|
| `Qwen3.6-35B-A3B-GGUF` | 23 GB | Default; downloads quickly |
| `Qwen3-Coder-Next-GGUF` | 48 GB | Coding and tool calling |
| `gpt-oss-120b-mxfp-GGUF` | 63 GB | Reasoning and tool calling |
| `Qwen3.5-122B-A10B-GGUF` | 78 GB | Still fits a 128 GB Strix Halo |
| `Qwen3.5-4B-GGUF` | 3.6 GB | For 8 GB cards; use `-CtxPerSlot 65536` if the card drives a screen |

## vLLM on MI300X (experimental)

Lemonade's vLLM backend leaves gfx942 off its supported list, and the vLLM build it would install for gfx942 is reported not to start ([lemonade-sdk/lemonade#3669](https://github.com/lemonade-sdk/lemonade/pull/3669)). To test both:

```powershell
.\leasehold.ps1 vllm-test      # starts it on the droplet; about an hour
.\leasehold.ps1 logs           # follow along (Ctrl+C stops following, not the test)
.\leasehold.ps1 report         # copy the results to .\reports\
```

The test does three things:
- Builds Lemonade from source with `remote/vllm-enable-gfx942.patch`.
- Tries Lemonade's default gfx942 vLLM build and the August 2026 nightly on a small model.
- Puts the first build that works through chat, tool-call and speed tests with `Qwen3.6-35B-A3B-FP8-vLLM-lowconc`.

It runs in place of the packaged server and restarts the packaged server at the end. Options:
- `-Pins "<tag> <tag>"` tests other vLLM-ROCm release tags.
- `-BigModel none` skips the big model.
- `-KeepDevServer` leaves the patched server running so you can try an agent on vLLM.

## Costs

- **Price:** an on-demand MI300X is $1.99/hour on the AMD Developer Cloud, about $48/day if left running. AMD Developer Program members get $100 of credit, about 50 hours.
- **Billing stops only on destroy.** It's per second, with a 60-second minimum, and continues while the droplet is powered off.
- **Downloads repeat.** Each new droplet downloads Lemonade's ROCm runtime and your models again.

## Creating the droplet with doctl (optional)

Create the first droplet in the console. Then `status` shows its image and region, which you can reuse:

```powershell
doctl compute ssh-key list
.\leasehold.ps1 up -Image <image-slug-or-id> -Region <region> -SshKey <key-fingerprint>
```

`up` asks for confirmation before creating anything. DigitalOcean's docs say doctl works with a personal access token; whether the AMD Developer Cloud console issues one is unconfirmed.

## Roadmap

HonestHarness's notes list eight requirements for a deployment kit (§5.2, K1–K8). Where Leasehold stands:

| Requirement | Status |
|---|---|
| K1. A pinned recipe: weights by revision, quantisation, engine version, serving flags, chat-template hash | Partly: setup pins the context, the slot count and every layer on the GPU. `collect` records the model revisions and the Lemonade, llama.cpp and ROCm versions afterwards, but nothing pins those beforehand |
| K2. An identity probe: model list, template hash, maximum context, a canary tool call, the model each response reports | Partly: setup's smoke tests include a tool call |
| K3. Leases with a time limit, a budget cap, idle shutdown, and teardown confirmed by the provider | Partly: `status` shows cost, and `down` destroys through the provider's API after you type the name |
| K4. Cost per lease, attributed to the agents that used it | Partly: `down` records each lease's hours and approximate cost, and `collect` its token usage per model; nothing attributes either to agents yet |
| K5. Warm starts: weights cached on the provider, start-up time recorded | Not yet |
| K6. Data governance: which repositories may go to which provider | Not yet |
| K7. Endpoints that vanish: resume on the same fingerprint, never silently on another model | Not yet; mostly the harness's job |
| K8. The local path is the same path | Yes: the same commands drive a droplet and your own box |

## Troubleshooting

- **Setup stopped partway:** run `setup` again.
- **Setup says the model doesn't fit:** run it again with a smaller `-CtxPerSlot` or fewer `-Slots`, or use a smaller model.
- **llama-server killed by the OOM killer** (`journalctl -u lemond` says `oom-kill`): the GPU probably also drives a screen with almost no VRAM free. See "Context size".
- **Setup waits for apt:** Ubuntu's unattended upgrades hold apt's lock, once for 24 minutes on the test box. Setup waits up to 30 minutes and names the process every 5 minutes.
- **Server won't start:** `.\leasehold.ps1 ssh`, then `journalctl -u lemond -n 100`.
- **Port 13305 is busy on your PC** (a local Lemonade, for example): add `-LocalPort 13306` to both `tunnel` and `pi` or `claude`.
- **"REMOTE HOST IDENTIFICATION HAS CHANGED":** delete `.known_hosts` in this folder. Droplet IPs get reused with new host keys.

## Licence

MIT. See [LICENSE](LICENSE).
