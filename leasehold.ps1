<#
.SYNOPSIS
  Leasehold: stands up, proves and tears down Lemonade model endpoints on an AMD Developer Cloud
  MI300X droplet, or any Ubuntu box you can SSH into, from a Windows PC.

.DESCRIPTION
  Commands:
    setup      Upload the remote scripts, install Lemonade, and load a model (about 15 minutes).
    key        Add your SSH public key to the remote account, so later commands stop asking for its
               login password; sudo still asks once per run. For your own box: a droplet gets the
               key when it is created.
    tunnel     Forward the remote Lemonade port to this PC over SSH. Leave it running.
    pi         Start Pi against Lemonade through the tunnel, from your project folder.
    claude     Start Claude Code against Lemonade through the tunnel, from your project folder.
    rocm       Install ROCm 10.1 and check HIP on your own Ubuntu box (rocm-box\). Run it again
               after each reboot it asks for.
    vllm-test  Start the vLLM-on-MI300X test on the droplet. Runs detached, about an hour.
               -BuildOnly stops after the patch, build and unit test, on any box: a rehearsal.
    logs       Follow the vLLM test's output.
    report     Copy the vLLM test report to .\reports\ next to this script.
    ssh        Open a shell on the remote machine.
    status     List your GPU droplets with age and approximate cost (needs doctl).
    bench      Measure generation speed for -Model with one request, then -Concurrency (default 4)
               at once, each -MaxTokens (default 256) long: what -Slots buys.
    depth      Measure -Model deep into its context, at -Depths tokens (default '8000 32000 64000
               120000'): time to read the prompt, whether it finds a fact hidden halfway down, and
               generation speed at that depth; then what a request longer than a slot gets.
    toolcheck  Check how reliably -Model calls tools: the right tool and arguments, no tool when
               none is needed, and a tool result used in the answer. Each case -Repeats times.
    collect    Save the machine's Lemonade records (config, server log, usage per model, model
               revisions, versions) to .\reports\records-<name>-<time>\ on this PC.
    down       Destroy a GPU droplet (needs doctl). Billing stops only when a droplet is destroyed.
               Runs collect first, then writes lease.json (hours, cost) beside the records;
               -NoCollect skips that.
    up         Create the droplet with doctl. Optional; the web console works too.

  For AI assistants (see AGENTS.md):
    grant      Run once per machine, as yourself: creates a 'leasehold' account that logs in with
               your SSH key only and runs sudo without a password, and saves the machine under
               -Machine <name> in machines.json. At most two prompts: your login, then sudo.
    run        Run one command on a granted machine, never prompting: run -Machine <name> -- '<cmd>'.
               Each run is appended to runs.log.
    revoke     Remove the 'leasehold' account and its sudo rule: revoke -Machine <name> -User <you>.
    note       Set your notes for a granted machine: note -Machine <name> -Notes '<text>'. Every
               -Machine command shows them, and AGENTS.md asks assistants to follow them.

  The remote IP is remembered after setup or up, so later commands don't need -Ip.
  -User defaults to root (the droplet). For your own box, pass your login, e.g. -User ubuntu;
  commands that need root then run through sudo, which may ask for your password.
  -Machine <name> fills in -Ip and -User from machines.json, so any command can target a
  granted machine without prompts.

.EXAMPLE
  .\leasehold.ps1 setup -Ip 203.0.113.10
.EXAMPLE
  .\leasehold.ps1 setup -Ip 192.168.1.50 -User ubuntu -Model Qwen3.5-4B-GGUF
.EXAMPLE
  path\to\Leasehold\leasehold.ps1 pi -Model Qwen3.6-35B-A3B-GGUF
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('setup', 'key', 'tunnel', 'pi', 'claude', 'rocm', 'vllm-test', 'logs', 'report', 'ssh',
        'collect', 'bench', 'depth', 'toolcheck', 'status', 'down', 'up', 'grant', 'run', 'revoke', 'note')]
    [string]$Command,

    [string]$Ip,
    [string]$User = 'root',
    [string]$Machine,
    [string]$Notes,
    [string]$Model = 'Qwen3.6-35B-A3B-GGUF',
    [int]$Slots = 1,
    [int]$CtxPerSlot = 131072,
    [int]$MaxModels = 2,
    [int]$LocalPort = 13305,
    [string]$Identity,

    # pi
    [string]$PiDir,
    [int]$ContextWindow = 131072,

    # vllm-test
    [string]$Pins,
    [string]$BigModel,
    [switch]$KeepDevServer,
    [switch]$BuildOnly,

    # up / down
    [string]$Name = 'leasehold-mi300x',
    [string]$Image,
    [string]$Region,
    [string]$SshKey,
    [string]$DropletId,
    [switch]$NoCollect,

    # bench, depth
    [int]$Concurrency = 4,
    [int]$MaxTokens = 256,
    [string]$Depths = '8000 32000 64000 120000',
    [int]$Repeats = 2,

    # pi / claude: anything after -- goes to the agent. run: the remote command.
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$Operator = 'leasehold'
$MachinesFile = Join-Path $PSScriptRoot 'machines.json'
$RunLog = Join-Path $PSScriptRoot 'runs.log'
$script:Batch = $false

# machines.json maps a machine's name to its address and the account assistants use there.
function Read-Machines {
    $machines = [ordered]@{}
    if (Test-Path $MachinesFile) {
        $json = Get-Content $MachinesFile -Raw | ConvertFrom-Json
        foreach ($p in $json.PSObject.Properties) { $machines[$p.Name] = $p.Value }
    }
    return $machines
}

# -Machine fills in -Ip and -User. grant creates the entry, so for grant it only names it.
if ($Machine -and $Command -ne 'grant') {
    $entry = (Read-Machines)[$Machine]
    if (-not $entry) {
        throw "No machine named '$Machine' in machines.json. Its owner adds it with: leasehold.ps1 grant -Machine $Machine -Ip <address> -User <login>"
    }
    if (-not $Ip) { $Ip = $entry.ip }
    if (-not $PSBoundParameters.ContainsKey('User')) {
        $User = $entry.user
        # The operator account logs in with a key and never prompts, so fail fast instead of waiting.
        $script:Batch = $true
    }
    # The owner's notes can limit what may happen on the machine (AGENTS.md), so show them every time.
    if ($entry.notes -and $Command -ne 'note') { Write-Host "Notes for ${Machine}: $($entry.notes)" -ForegroundColor Yellow }
}

if ($User -notmatch '^[a-z_][a-z0-9_-]*$') { throw "'$User' is not a valid Linux user name." }
if ($User -eq 'root') { $RemoteDir = '/root/leasehold'; $Sudo = '' } else { $RemoteDir = "/home/$User/leasehold"; $Sudo = 'sudo ' }
$RemotePort = 13305
$UsdPerGpuHour = 1.99
$IpFile = Join-Path $PSScriptRoot '.last-ip'
$KnownHosts = Join-Path $PSScriptRoot '.known_hosts'

function Resolve-Ip {
    if (-not $script:Ip -and (Test-Path $IpFile)) { $script:Ip = (Get-Content $IpFile -Raw).Trim() }
    if (-not $script:Ip) { throw 'No remote IP. Pass -Ip <address> (it is remembered afterwards).' }
    $parsed = $null
    if ($script:Ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or -not [System.Net.IPAddress]::TryParse($script:Ip, [ref]$parsed)) {
        throw "'$($script:Ip)' is not an IPv4 address."
    }
    return $script:Ip
}

function Get-SshArgs {
    $a = @('-o', 'StrictHostKeyChecking=accept-new', '-o', 'ServerAliveInterval=30')
    # Droplet IPs get reused with new host keys, so keep their keys out of your main known_hosts.
    if ($KnownHosts -notmatch '\s') { $a += @('-o', "UserKnownHostsFile=$KnownHosts") }
    if ($Identity) { $a += @('-i', $Identity) }
    if ($script:Batch) { $a += @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15') }
    return $a
}

function Get-PublicKey {
    if ($Identity) { $pubPath = "$Identity.pub" } else { $pubPath = Join-Path $env:USERPROFILE '.ssh\id_ed25519.pub' }
    if (-not (Test-Path $pubPath)) { throw "No public key at $pubPath. Create one with: ssh-keygen -t ed25519" }
    $pub = (Get-Content $pubPath -Raw).Trim()
    # One key on one line, with no quotes, so it can sit inside a single-quoted remote command.
    if ($pub -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp\d+) [A-Za-z0-9+/=]+( [^''"\r\n]*)?$') {
        throw "$pubPath doesn't look like a single SSH public key."
    }
    return $pub
}

# The remote command that adds a key to the login account's authorized_keys, once.
function Get-AddKeyCommand([string]$Pub) {
    return "umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && " +
        "{ grep -qxF '$Pub' ~/.ssh/authorized_keys || echo '$Pub' >> ~/.ssh/authorized_keys; }"
}

function Invoke-Remote([string]$RemoteCommand, [switch]$Tty) {
    $ip = Resolve-Ip
    $sshArgs = Get-SshArgs
    if ($Tty) { $sshArgs += '-t' }
    & ssh @sshArgs "$User@$ip" $RemoteCommand
    if ($LASTEXITCODE -ne 0) { throw "Remote command failed (exit $LASTEXITCODE): $RemoteCommand" }
}

function Assert-SafeValue([string]$Value, [string]$What) {
    if ($Value -notmatch '^[A-Za-z0-9._:+/ -]+$') { throw "$What contains characters this script won't pass to a shell: $Value" }
}

function Assert-Root([string]$What) {
    if ($User -ne 'root') { throw "$What is for the MI300X droplet; run it with -User root." }
}

function Send-Scripts {
    $ip = Resolve-Ip
    $files = @(Get-ChildItem -File (Join-Path $PSScriptRoot 'remote') | ForEach-Object { $_.FullName })
    Invoke-Remote "mkdir -p $RemoteDir"
    $scpArgs = Get-SshArgs
    & scp @scpArgs @files "${User}@${ip}:$RemoteDir/"
    if ($LASTEXITCODE -ne 0) { throw 'Upload failed.' }
    # Files edited on Windows may have CRLF line endings, which bash and git apply reject.
    Invoke-Remote "sed -i 's/\r`$//' $RemoteDir/*.sh $RemoteDir/*.patch && chmod +x $RemoteDir/*.sh"
}

# Gathers the machine's Lemonade records (remote/collect.sh) into reports\records-<label>-<time>\
# on this PC and returns that folder.
function Save-Records([string]$Label) {
    # Remote output goes to the host, so the folder is this function's only output.
    $ip = Resolve-Ip
    $dest = Join-Path $PSScriptRoot ('reports\records-' + $Label + '-' + (Get-Date -Format 'yyyyMMdd-HHmm'))
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Send-Scripts | Out-Host
    $remoteTar = '/tmp/leasehold-records.tar.gz'
    Invoke-Remote "${Sudo}bash $RemoteDir/collect.sh $remoteTar $User" | Out-Host
    $scpArgs = Get-SshArgs
    $localTar = Join-Path $dest 'records.tar.gz'
    & scp @scpArgs "${User}@${ip}:$remoteTar" $localTar | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'Copying the records to this PC failed.' }
    Invoke-Remote "rm -f $remoteTar" | Out-Host
    # Windows 10 and 11 ship tar.exe, which unpacks .tar.gz.
    & tar -xzf $localTar -C $dest | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Warning "Could not unpack $localTar; the archive itself is intact." }
    return $dest
}

function Test-Lemonade([string]$Base) {
    foreach ($path in '/v1/health', '/api/v1/health') {
        try { Invoke-RestMethod "$Base$path" -TimeoutSec 5 | Out-Null; return $true } catch { }
    }
    return $false
}

# Runs $Body with environment variables set for this process only, then restores them.
function Invoke-WithEnv([System.Collections.IDictionary]$Vars, [scriptblock]$Body) {
    $saved = @{}
    foreach ($k in $Vars.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process')
        [Environment]::SetEnvironmentVariable($k, $Vars[$k], 'Process')
    }
    try { & $Body }
    finally {
        foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') }
    }
}

# The model's context size, looked up the way `lemonade launch pi` does it.
function Get-ModelContext([string]$Base, [string]$ModelName) {
    try {
        $m = Invoke-RestMethod "$Base/api/v1/models/$ModelName" -TimeoutSec 10
        if ($m.context_length -gt 0) { return [int]$m.context_length }
    } catch { }
    try {
        $list = Invoke-RestMethod "$Base/api/v1/models?show_all=false" -TimeoutSec 10
        foreach ($e in (@($list.data) + @($list))) {
            if ($e.id -eq $ModelName -and $e.recipe_options.ctx_size -gt 0) { return [int]$e.recipe_options.ctx_size }
        }
    } catch { }
    return $null
}

# How many requests the server runs at once for the model: llama.cpp's --parallel, which splits the
# model's context evenly across that many slots. Lemonade reports the whole context.
function Get-ModelSlots([string]$Base, [string]$ModelName) {
    $flags = $null
    try {
        $health = Invoke-RestMethod "$Base/api/v1/health" -TimeoutSec 10
        foreach ($m in @($health.all_models_loaded)) {
            if ($m.model_name -eq $ModelName) { $flags = [string]$m.recipe_options.llamacpp_args }
        }
    } catch { }
    if (-not $flags) {
        # Not loaded yet: it will load with the server-wide flags that setup set.
        try { $flags = [string](Invoke-RestMethod "$Base/internal/config" -TimeoutSec 10).llamacpp.rocm_args } catch { }
    }
    if ($flags -match '(?:--parallel|-np)\s+(\d+)') { return [int]$Matches[1] }
    return 1
}

function Write-JsonFile([string]$Path, $Object) {
    # UTF-8 without a byte-order mark; Windows PowerShell's Set-Content would add one.
    $json = ConvertTo-Json -InputObject $Object -Depth 10
    [System.IO.File]::WriteAllText($Path, $json + "`n", (New-Object System.Text.UTF8Encoding($false)))
}

function Assert-Doctl {
    if (-not (Get-Command doctl -ErrorAction SilentlyContinue)) {
        throw 'doctl is not installed. See "Optional: doctl" in README.md, then run: doctl auth init'
    }
}

function Get-GpuDroplets {
    $raw = & doctl compute droplet list --output json
    if ($LASTEXITCODE -ne 0) { throw 'doctl could not list droplets. Has doctl auth init been run?' }
    $all = ($raw | Out-String) | ConvertFrom-Json
    foreach ($d in (@($all) | Where-Object { $_.size_slug -like 'gpu-*' })) {
        $gpus = 1
        if ($d.size_slug -match 'x(\d+)-') { $gpus = [int]$Matches[1] }
        $hours = ((Get-Date).ToUniversalTime() - ([datetime]$d.created_at).ToUniversalTime()).TotalHours
        $public = @($d.networks.v4) | Where-Object { $_.type -eq 'public' } | Select-Object -First 1
        $imageSlug = $d.image.slug
        if (-not $imageSlug) { $imageSlug = "$($d.image.id) ($($d.image.name))" }
        [pscustomobject]@{
            Name       = $d.name
            Id         = $d.id
            Status     = $d.status
            Ip         = $public.ip_address
            Size       = $d.size_slug
            Region     = $d.region.slug
            Image      = $imageSlug
            Hours      = [math]::Round($hours, 1)
            ApproxCost = ('${0:N2}' -f ($hours * $gpus * $UsdPerGpuHour))
        }
    }
}

switch ($Command) {
    'setup' {
        Assert-SafeValue $Model 'Model'
        $ip = Resolve-Ip
        Send-Scripts
        Set-Content -Path $IpFile -Value $ip
        $vars = "MODEL='$Model' SLOTS=$Slots CTX_PER_SLOT=$CtxPerSlot MAX_MODELS=$MaxModels"
        Invoke-Remote "${Sudo}env $vars bash $RemoteDir/setup-lemonade.sh" -Tty
    }

    'tunnel' {
        $ip = Resolve-Ip
        $busy = Get-NetTCPConnection -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue
        if ($busy) { throw "Port $LocalPort is already in use on this PC (a local Lemonade?). Use -LocalPort 13306 here and with pi or claude." }
        Write-Host "Forwarding http://127.0.0.1:$LocalPort to Lemonade on $ip. Leave this window open; Ctrl+C closes the tunnel."
        $sshArgs = Get-SshArgs
        & ssh @sshArgs -N -o ExitOnForwardFailure=yes -L "${LocalPort}:127.0.0.1:$RemotePort" "$User@$ip"
    }

    'pi' {
        $base = "http://127.0.0.1:$LocalPort"
        if (-not (Test-Lemonade $base)) { throw "Nothing answers at $base. Start the tunnel first: leasehold.ps1 tunnel" }
        if (-not (Get-Command pi -ErrorAction SilentlyContinue)) {
            throw 'Pi is not installed. Install it with: npm install -g @earendil-works/pi-coding-agent'
        }
        # Pi's config and sessions go in their own folder, never ~/.pi or ~/.claude. Point -PiDir at a
        # round's folder to keep that round's config and transcripts with its record.
        $agentDir = $PiDir
        if (-not $agentDir) { $agentDir = Join-Path $PSScriptRoot 'pi-agent' }
        New-Item -ItemType Directory -Force -Path $agentDir | Out-Null
        $agentDir = (Resolve-Path $agentDir).Path

        $ctx = Get-ModelContext $base $Model
        if (-not $ctx) {
            $ctx = $ContextWindow
            Write-Host "Couldn't read $Model's context size from Lemonade; telling Pi $ctx tokens (-ContextWindow changes it)."
        } else {
            # With several slots, one agent's requests get one slot's share of the context.
            $slots = Get-ModelSlots $base $Model
            if ($slots -gt 1) {
                $ctx = [int][math]::Floor($ctx / $slots)
                Write-Host "$Model serves $slots requests at once, so each gets $ctx tokens of context."
            }
        }
        # The same provider block `lemonade launch pi` writes (src/cpp/cli/pi_profile.cpp in Lemonade).
        Write-JsonFile (Join-Path $agentDir 'models.json') ([ordered]@{
            providers = [ordered]@{
                Lemonade = [ordered]@{
                    baseUrl = "$base/v1"
                    api     = 'openai-completions'
                    apiKey  = 'lemonade'
                    compat  = [ordered]@{ supportsStore = $false; maxTokensField = 'max_tokens' }
                    models  = @([ordered]@{ id = $Model; contextWindow = $ctx; maxTokens = $ctx; input = @('text') })
                }
            }
        })
        Write-JsonFile (Join-Path $agentDir 'settings.json') ([ordered]@{ defaultProvider = 'Lemonade'; defaultModel = $Model })

        $vars = [ordered]@{
            PI_CODING_AGENT_DIR         = $agentDir
            PI_CODING_AGENT_SESSION_DIR = (Join-Path $agentDir 'sessions')
            LEMONADE_API_KEY            = 'lemonade'
        }
        Write-Host "Pi -> $base ($Model, $ctx-token context). Config and sessions: $agentDir"
        Invoke-WithEnv $vars { & pi --provider Lemonade --model $Model @Rest }
    }

    'claude' {
        $base = "http://127.0.0.1:$LocalPort"
        if (-not (Test-Lemonade $base)) { throw "Nothing answers at $base. Start the tunnel first: leasehold.ps1 tunnel" }
        if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { throw 'Claude Code (claude) is not on PATH.' }
        # The same variables `lemonade launch claude` sets (src/cpp/cli/agent_launcher.cpp in Lemonade).
        $vars = [ordered]@{
            ANTHROPIC_BASE_URL                       = $base
            ANTHROPIC_AUTH_TOKEN                     = 'lemonade'
            LEMONADE_API_KEY                         = 'lemonade'
            ANTHROPIC_DEFAULT_OPUS_MODEL             = $Model
            ANTHROPIC_DEFAULT_SONNET_MODEL           = $Model
            ANTHROPIC_DEFAULT_HAIKU_MODEL            = $Model
            CLAUDE_CODE_SUBAGENT_MODEL               = $Model
            CLAUDE_CODE_ATTRIBUTION_HEADER           = '0'
            CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = '1'
            # Never send a real Anthropic key to the remote machine.
            ANTHROPIC_API_KEY                        = $null
        }
        Write-Host "Claude Code -> $base ($Model)"
        Invoke-WithEnv $vars { & claude @Rest }
    }

    'rocm' {
        $ip = Resolve-Ip
        $boxDir = Join-Path $PSScriptRoot 'rocm-box'
        if (-not (Test-Path (Join-Path $boxDir 'setup-rocm-box.sh'))) { throw "rocm-box not found at $boxDir" }
        if ($User -eq 'root') { $remote = '/root/rocm-box' } else { $remote = "/home/$User/rocm-box" }
        Invoke-Remote "mkdir -p $remote/hip-smoke"
        Set-Content -Path $IpFile -Value $ip
        $scpArgs = Get-SshArgs
        & scp @scpArgs (Join-Path $boxDir 'setup-rocm-box.sh') "${User}@${ip}:$remote/"
        if ($LASTEXITCODE -ne 0) { throw 'Upload failed.' }
        & scp @scpArgs (Join-Path $boxDir 'hip-smoke\vector_add.hip') "${User}@${ip}:$remote/hip-smoke/"
        if ($LASTEXITCODE -ne 0) { throw 'Upload failed.' }
        Invoke-Remote ("sed -i 's/\r`$//' $remote/setup-rocm-box.sh $remote/hip-smoke/vector_add.hip && " +
            "${Sudo}bash $remote/setup-rocm-box.sh") -Tty
    }

    'vllm-test' {
        # -BuildOnly rehearses the patch and build on any box; the full test needs the droplet.
        if (-not $BuildOnly) { Assert-Root 'vllm-test' }
        Send-Scripts
        $setenv = @('--setenv=HOME=/root')
        if ($Pins) { Assert-SafeValue $Pins 'Pins'; $setenv += "--setenv=PINS='$Pins'" }
        if ($BigModel -eq 'none') { $setenv += "--setenv=BIG_MODEL=" }
        elseif ($BigModel) { Assert-SafeValue $BigModel 'BigModel'; $setenv += "--setenv=BIG_MODEL='$BigModel'" }
        if ($KeepDevServer) { $setenv += '--setenv=KEEP_DEV_SERVER=1' }
        if ($BuildOnly) { $setenv += '--setenv=BUILD_ONLY=1' }
        $unit = 'leasehold-vllm-test'
        Invoke-Remote ("${Sudo}systemctl reset-failed $unit 2>/dev/null; " +
            "${Sudo}systemd-run --unit=$unit --collect $($setenv -join ' ') bash $RemoteDir/vllm-gfx942-test.sh") -Tty:([bool]$Sudo)
        if ($BuildOnly) { Write-Host 'Started: patch, build, unit test and docs only (10 to 30 minutes). Follow it with: leasehold.ps1 logs' }
        else { Write-Host 'Started on the droplet (about an hour). Follow it with: leasehold.ps1 logs' }
        Write-Host 'When it finishes, copy the results with: leasehold.ps1 report'
    }

    'logs' {
        $ip = Resolve-Ip
        $sshArgs = Get-SshArgs
        Write-Host 'Ctrl+C stops following; the test keeps running.'
        & ssh @sshArgs -t "$User@$ip" "${Sudo}tail -n 100 -F /root/vllm-gfx942-report/run.log"
    }

    'report' {
        $ip = Resolve-Ip
        $dest = Join-Path $PSScriptRoot ('reports\vllm-' + (Get-Date -Format 'yyyyMMdd-HHmm'))
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        $remote = '/root/vllm-gfx942-report'
        if ($Sudo) {
            # Another account can't read /root, so copy the report out for scp first.
            Invoke-Remote ("sudo rm -rf /tmp/vllm-gfx942-report && sudo cp -r $remote /tmp/ && " +
                "sudo chown -R ${User}: /tmp/vllm-gfx942-report") -Tty
            $remote = '/tmp/vllm-gfx942-report'
        }
        $scpArgs = Get-SshArgs
        & scp @scpArgs -r "$User@${ip}:$remote" $dest
        if ($LASTEXITCODE -ne 0) { throw 'Copy failed. Has the test written its report yet?' }
        if ($Sudo) { Invoke-Remote 'rm -rf /tmp/vllm-gfx942-report' }
        Write-Host "Copied to $dest"
        $summary = Join-Path $dest 'vllm-gfx942-report\summary.md'
        if (Test-Path $summary) { Get-Content $summary }
    }

    'ssh' {
        $ip = Resolve-Ip
        $sshArgs = Get-SshArgs
        & ssh @sshArgs -t "$User@$ip"
    }

    'key' {
        $ip = Resolve-Ip
        $pub = Get-PublicKey
        Write-Host "Adding your public key to $User@${ip}'s authorized_keys. SSH asks for the password one last time."
        Invoke-Remote (Get-AddKeyCommand $pub)
        Set-Content -Path $IpFile -Value $ip
        Write-Host 'Done. Later commands log in with your key; sudo still asks for your password once per run.'
    }

    'grant' {
        if (-not $Machine -or $Machine -notmatch '^[A-Za-z0-9._-]+$') {
            throw 'grant needs -Machine <name>: the name assistants will use for this machine, e.g. -Machine rocm-box.'
        }
        if ($User -eq $Operator) { throw "Run grant as yourself: -User <your login on the machine>, not $Operator." }
        $ip = Resolve-Ip
        $pub = Get-PublicKey
        Write-Host "This lets AI assistants use $ip through a '$Operator' account that logs in with your SSH key only"
        Write-Host 'and runs sudo without a password. Expect at most two prompts: your login password, only if'
        Write-Host 'your key is not on the machine yet, then sudo.'
        Invoke-Remote (Get-AddKeyCommand $pub)
        $scpArgs = Get-SshArgs
        & scp @scpArgs (Join-Path $PSScriptRoot 'remote\grant-operator.sh') "${User}@${ip}:leasehold-grant-operator.sh"
        if ($LASTEXITCODE -ne 0) { throw 'Upload failed.' }
        Invoke-Remote ("sed -i 's/\r`$//' leasehold-grant-operator.sh && " +
            "${Sudo}bash leasehold-grant-operator.sh $Operator '$pub'; rc=`$?; rm -f leasehold-grant-operator.sh; exit `$rc") -Tty

        # Prove it the way an assistant will use it: key login, no prompts, sudo without a password.
        $script:Batch = $true
        $sshArgs = Get-SshArgs
        $out = @(& ssh @sshArgs "$Operator@$ip" 'sudo -n true && hostname && ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub')
        if ($LASTEXITCODE -ne 0 -or $out.Count -lt 2) { throw "The '$Operator' account did not work without prompts: $($out -join ' ')" }
        $machines = Read-Machines
        # Granting again keeps the owner's notes unless -Notes replaces them.
        $keep = ''
        if ($machines[$Machine] -and $machines[$Machine].notes) { $keep = [string]$machines[$Machine].notes }
        if ($PSBoundParameters.ContainsKey('Notes')) { $keep = $Notes }
        $machines[$Machine] = [ordered]@{
            ip       = $ip
            user     = $Operator
            hostname = $out[0]
            host_key = ($out[1] -split ' ')[1]
            granted  = (Get-Date -Format 'yyyy-MM-dd')
            by       = $User
            notes    = $keep
        }
        Write-JsonFile $MachinesFile $machines
        Set-Content -Path $IpFile -Value $ip
        Write-Host "Granted. $Machine is $($out[0]) at $ip, host key $(($out[1] -split ' ')[1])."
        Write-Host "Assistants can now run: leasehold.ps1 run -Machine $Machine -- '<command>'"
        Write-Host "To take it back: leasehold.ps1 revoke -Machine $Machine -User $User"
    }

    'note' {
        if (-not $Machine) { throw "note needs -Machine <name> and -Notes '<text>' (an empty -Notes '' clears them)." }
        if (-not $PSBoundParameters.ContainsKey('Notes')) { throw "note needs -Notes '<text>'; -Notes '' clears the notes." }
        $machines = Read-Machines
        $entry = $machines[$Machine]
        $entry | Add-Member -NotePropertyName notes -NotePropertyValue $Notes -Force
        $machines[$Machine] = $entry
        Write-JsonFile $MachinesFile $machines
        if ($Notes) { Write-Host "Notes for $Machine saved. Every -Machine $Machine command shows them." }
        else { Write-Host "Notes for $Machine cleared." }
    }

    'run' {
        $remoteCmd = ($Rest -join ' ').Trim()
        if (-not $remoteCmd) { throw "run needs a command after --, for example: leasehold.ps1 run -Machine rocm-box -- 'uname -a'" }
        $ip = Resolve-Ip
        $script:Batch = $true
        $sshArgs = Get-SshArgs
        $started = Get-Date
        & ssh @sshArgs "$User@$ip" $remoteCmd
        $code = $LASTEXITCODE
        $label = $Machine
        if (-not $label) { $label = $ip }
        $line = '{0}	{1}	{2}@{3}	exit {4}	{5}' -f $started.ToString('yyyy-MM-ddTHH:mm:ss'), $label, $User, $ip, $code, $remoteCmd
        Add-Content -Path $RunLog -Value $line -Encoding UTF8
        exit $code
    }

    'revoke' {
        if (-not $PSBoundParameters.ContainsKey('User') -or $User -eq $Operator) {
            throw 'Run revoke as yourself: -User <your login on the machine>.'
        }
        $ip = Resolve-Ip
        Invoke-Remote ("${Sudo}sh -c 'rm -f /etc/sudoers.d/$Operator; pkill -KILL -u $Operator; " +
            "userdel -r $Operator 2>/dev/null; true'") -Tty
        $machines = Read-Machines
        if ($Machine -and $machines.Contains($Machine)) {
            $machines.Remove($Machine)
            Write-JsonFile $MachinesFile $machines
        }
        Write-Host "Revoked: the '$Operator' account and its sudo rule are gone from $ip."
    }

    'status' {
        Assert-Doctl
        $list = @(Get-GpuDroplets)
        if ($list.Count -eq 0) { Write-Host 'No GPU droplets exist. Nothing is billing.'; return }
        $list | Format-Table -AutoSize
        Write-Host "Each MI300X bills about `$$UsdPerGpuHour/hour until destroyed, powered off or not."
    }

    'bench' {
        Assert-SafeValue $Model 'Model'
        if ($Concurrency -lt 1 -or $MaxTokens -lt 1) { throw '-Concurrency and -MaxTokens must be at least 1.' }
        Send-Scripts
        Invoke-Remote "bash $RemoteDir/bench.sh '$Model' $Concurrency $MaxTokens"
    }

    'depth' {
        Assert-SafeValue $Model 'Model'
        if ($Depths -notmatch '^\s*[1-9][0-9]*(\s+[1-9][0-9]*)*\s*$') { throw "-Depths takes token counts separated by spaces, e.g. '8000 32000'." }
        Send-Scripts
        Invoke-Remote "bash $RemoteDir/depth.sh '$Model' $($Depths.Trim())"
    }

    'toolcheck' {
        Assert-SafeValue $Model 'Model'
        if ($Repeats -lt 1) { throw '-Repeats must be at least 1.' }
        Send-Scripts
        Invoke-Remote "bash $RemoteDir/toolcheck.sh '$Model' $Repeats"
    }

    'collect' {
        $label = $Machine
        if (-not $label) { $label = Resolve-Ip }
        $dest = Save-Records $label
        Write-Host "Records saved to $dest"
    }

    'down' {
        Assert-Doctl
        $list = @(Get-GpuDroplets)
        if ($list.Count -eq 0) { Write-Host 'No GPU droplets exist. Nothing to destroy.'; return }
        if ($DropletId) { $target = $list | Where-Object { "$($_.Id)" -eq $DropletId } | Select-Object -First 1 }
        elseif ($list.Count -eq 1) { $target = $list[0] }
        else { $list | Format-Table -AutoSize; throw 'More than one GPU droplet; pass -DropletId <id>.' }
        if (-not $target) { throw "No GPU droplet with id $DropletId." }
        $target | Format-List
        $records = $null
        if ($NoCollect) {
            Write-Host 'Skipping the records (-NoCollect).'
        }
        elseif (-not $target.Ip) {
            Write-Warning 'The droplet has no public IP, so its records cannot be saved first.'
        }
        else {
            Write-Host "Saving the droplet's records to this PC first..."
            $script:Ip = $target.Ip
            try {
                $records = Save-Records $target.Name
                Write-Host "Records saved to $records"
            }
            catch {
                Write-Warning "Saving the records failed: $($_.Exception.Message)"
                Write-Warning 'Destroying now loses whatever is on the droplet.'
            }
        }
        Write-Host 'Destroying deletes everything on the droplet.'
        $answer = Read-Host "Type the droplet name ($($target.Name)) to destroy it"
        if ($answer -ne $target.Name) { Write-Host 'Names did not match. Nothing was destroyed.'; return }
        & doctl compute droplet delete $target.Id --force
        if ($LASTEXITCODE -ne 0) { throw 'doctl could not destroy the droplet. Check the web console.' }
        if ($records) {
            # What the lease cost, beside what it ran (HonestHarness K4).
            Write-JsonFile (Join-Path $records 'lease.json') ([ordered]@{
                name        = $target.Name
                id          = $target.Id
                size        = $target.Size
                region      = $target.Region
                image       = $target.Image
                hours       = $target.Hours
                approx_cost = $target.ApproxCost
                destroyed   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            })
        }
        if ($target.Ip -and (Test-Path $KnownHosts)) {
            # Forget the old host key; the next droplet on this IP will have a new one.
            $ErrorActionPreference = 'Continue'
            & ssh-keygen -R $target.Ip -f $KnownHosts *> $null
            $ErrorActionPreference = 'Stop'
        }
        if ((Test-Path $IpFile) -and ((Get-Content $IpFile -Raw).Trim() -eq $target.Ip)) { Remove-Item $IpFile }
        Write-Host "Destroyed $($target.Name). Run leasehold.ps1 status to confirm nothing is left."
    }

    'up' {
        Assert-Doctl
        if (-not ($Image -and $Region -and $SshKey)) {
            throw 'up needs -Image, -Region and -SshKey. See "Creating the droplet with doctl" in README.md.'
        }
        Write-Host "This creates $Name (gpu-mi300x1-192gb), billed at about `$$UsdPerGpuHour/hour until you destroy it."
        $answer = Read-Host 'Create it? (y/N)'
        if ($answer -notmatch '^(y|yes)$') { Write-Host 'Not created.'; return }
        $raw = & doctl compute droplet create $Name --size gpu-mi300x1-192gb --image $Image --region $Region `
            --ssh-keys $SshKey --tag-name leasehold --wait --output json
        if ($LASTEXITCODE -ne 0) { throw 'doctl could not create the droplet.' }
        $d = @(($raw | Out-String) | ConvertFrom-Json)[0]
        $newIp = (@($d.networks.v4) | Where-Object { $_.type -eq 'public' } | Select-Object -First 1).ip_address
        Set-Content -Path $IpFile -Value $newIp
        Write-Host "Created $Name ($($d.id)) at $newIp. Give it a minute to boot, then: leasehold.ps1 setup"
    }
}
