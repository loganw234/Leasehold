# Notes for AI assistants

Leasehold is a Windows PowerShell helper, `leasehold.ps1`, plus scripts that run on remote Ubuntu machines (`remote/`, `rocm-box/`). README.md explains the commands.

## Using the owner's machines

- `machines.json`, kept local and never committed, lists the machines the owner has granted to assistants. For each machine it records the address, the `leasehold` operator account, the hostname, the SSH host-key fingerprint, and the owner's notes.
- Run a command with `.\leasehold.ps1 run -Machine <name> -- '<command>'`.
  - It never prompts: it logs in with the owner's SSH key, and `sudo` works without a password.
  - It returns the remote command's exit code and appends a line to `runs.log`.
- Every other command takes `-Machine <name>` too, for example `.\leasehold.ps1 rocm -Machine rocm-box`.
- Put the remote command in single quotes. Windows PowerShell 5.1 mangles double quotes passed to `ssh`.
- **If anything asks for a password, the grant is missing or broken.** Stop and ask the owner to run `.\leasehold.ps1 grant -Machine <name> -Ip <address> -User <their login>`. Never ask the owner to type a password into your tools.
- Read the machine's `notes` before acting. They may limit what goes on the machine; for example, a machine kept as a clean room for other agents must not receive certain repositories or records.

## Ask the owner first

- Anything that costs money. State the hourly price before creating a droplet (`up`), and never destroy a droplet you did not create. When you do destroy one, let `down` save its records first; pass `-NoCollect` only if the owner says so.
- Changes to a machine's users, sudo rules, SSH configuration, network or firewall.
- Reinstalling, wiping or repartitioning disks, and firmware updates.
- Copying repositories, records or data onto a machine beyond what the task needs.
- `grant` and `revoke`, which are the owner's to run.

Reboots and package installs that a Leasehold script asks for are part of the work. Do them, and say that you did.

## Before committing changes to this repository

- Run `bash -n` on every changed `.sh` file, and parse `leasehold.ps1` with the PowerShell parser (`[System.Management.Automation.Language.Parser]::ParseFile`).
- Keep `leasehold.ps1` ASCII-only. Windows PowerShell 5.1 reads files without a byte-order mark as ANSI.
- Keep `.sh`, `.hip` and `.patch` files at LF line endings. `.gitattributes` handles this for Git.
- Keep personal details out of committed files: no real IP addresses, user names or host keys. `machines.json`, `runs.log`, `.last-ip` and `.known_hosts` stay local through `.gitignore`.
