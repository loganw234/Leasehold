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
    logs       Follow the vLLM test's output.
    report     Copy the vLLM test report to .\reports\ next to this script.
    ssh        Open a shell on the remote machine.
    status     List your GPU droplets with age and approximate cost (needs doctl).
    down       Destroy a GPU droplet (needs doctl). Billing stops only when a droplet is destroyed.
    up         Create the droplet with doctl. Optional; the web console works too.

  The remote IP is remembered after setup or up, so later commands don't need -Ip.
  -User defaults to root (the droplet). For your own box, pass your login, e.g. -User ubuntu;
  commands that need root then run through sudo, which may ask for your password.

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
    [ValidateSet('setup', 'key', 'tunnel', 'pi', 'claude', 'rocm', 'vllm-test', 'logs', 'report', 'ssh', 'status', 'down', 'up')]
    [string]$Command,

    [string]$Ip,
    [string]$User = 'root',
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

    # up / down
    [string]$Name = 'leasehold-mi300x',
    [string]$Image,
    [string]$Region,
    [string]$SshKey,
    [string]$DropletId,

    # pi / claude: anything after -- goes to the agent
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = 'Stop'
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
    return $a
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
        Assert-Root 'vllm-test'
        Send-Scripts
        $setenv = @('--setenv=HOME=/root')
        if ($Pins) { Assert-SafeValue $Pins 'Pins'; $setenv += "--setenv=PINS='$Pins'" }
        if ($BigModel -eq 'none') { $setenv += "--setenv=BIG_MODEL=" }
        elseif ($BigModel) { Assert-SafeValue $BigModel 'BigModel'; $setenv += "--setenv=BIG_MODEL='$BigModel'" }
        if ($KeepDevServer) { $setenv += '--setenv=KEEP_DEV_SERVER=1' }
        $unit = 'leasehold-vllm-test'
        Invoke-Remote ("systemctl reset-failed $unit 2>/dev/null; " +
            "systemd-run --unit=$unit --collect $($setenv -join ' ') bash $RemoteDir/vllm-gfx942-test.sh")
        Write-Host 'Started on the droplet (about an hour). Follow it with: leasehold.ps1 logs'
        Write-Host 'When it finishes, copy the results with: leasehold.ps1 report'
    }

    'logs' {
        Assert-Root 'logs'
        $ip = Resolve-Ip
        $sshArgs = Get-SshArgs
        Write-Host 'Ctrl+C stops following; the test keeps running on the droplet.'
        & ssh @sshArgs -t "$User@$ip" 'tail -n 100 -F /root/vllm-gfx942-report/run.log'
    }

    'report' {
        Assert-Root 'report'
        $ip = Resolve-Ip
        $dest = Join-Path $PSScriptRoot ('reports\vllm-' + (Get-Date -Format 'yyyyMMdd-HHmm'))
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        $scpArgs = Get-SshArgs
        & scp @scpArgs -r "$User@${ip}:/root/vllm-gfx942-report" $dest
        if ($LASTEXITCODE -ne 0) { throw 'Copy failed. Has the test written its report yet?' }
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
        if ($Identity) { $pubPath = "$Identity.pub" } else { $pubPath = Join-Path $env:USERPROFILE '.ssh\id_ed25519.pub' }
        if (-not (Test-Path $pubPath)) { throw "No public key at $pubPath. Create one with: ssh-keygen -t ed25519" }
        $pub = (Get-Content $pubPath -Raw).Trim()
        # One key on one line, with no quotes, so it can sit inside the single-quoted remote command.
        if ($pub -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp\d+) [A-Za-z0-9+/=]+( [^''"\r\n]*)?$') {
            throw "$pubPath doesn't look like a single SSH public key."
        }
        Write-Host "Adding $pubPath to $User@${ip}'s authorized_keys. SSH asks for the password one last time."
        Invoke-Remote ("umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && " +
            "{ grep -qxF '$pub' ~/.ssh/authorized_keys || echo '$pub' >> ~/.ssh/authorized_keys; }")
        Set-Content -Path $IpFile -Value $ip
        Write-Host 'Done. Later commands log in with your key; sudo still asks for your password once per run.'
    }

    'status' {
        Assert-Doctl
        $list = @(Get-GpuDroplets)
        if ($list.Count -eq 0) { Write-Host 'No GPU droplets exist. Nothing is billing.'; return }
        $list | Format-Table -AutoSize
        Write-Host "Each MI300X bills about `$$UsdPerGpuHour/hour until destroyed, powered off or not."
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
        Write-Host 'Destroying deletes everything on the droplet. Copy reports first (leasehold.ps1 report).'
        $answer = Read-Host "Type the droplet name ($($target.Name)) to destroy it"
        if ($answer -ne $target.Name) { Write-Host 'Names did not match. Nothing was destroyed.'; return }
        & doctl compute droplet delete $target.Id --force
        if ($LASTEXITCODE -ne 0) { throw 'doctl could not destroy the droplet. Check the web console.' }
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
