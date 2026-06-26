<#
.SYNOPSIS
    Power Platform VS Code Workspace - One-click bootstrap
.DESCRIPTION
    Run this script to create a fully configured Power Platform workspace
    with Power Platform Master Agent, Microsoft skills, and PAC CLI helpers.
    Once complete it opens the folder in VS Code - select Power Platform Master Agent
    from the Copilot Chat dropdown and type anything to start.
.NOTES
    Local authoring flow: git, VS Code 1.117.0+ with GitHub Copilot, pac CLI.
    Live canvas authoring flow (optional): .NET 10 SDK - provides 'dnx', which
    runs the Canvas Authoring MCP server used for real-time coauthoring.
#>

# Keep the window open on any error so the user can read it
$ErrorActionPreference = 'Stop'
trap {
    Write-Host "`nERROR: $_" -ForegroundColor Red
    Read-Host "`nPress Enter to close"
    exit 1
}

# -- Helper: step banner ------------------------------------------------
function Show-Step ([int]$Number, [int]$Total, [string]$Title) {
    Write-Host ""
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host "  STEP $Number of $Total - $Title" -ForegroundColor Cyan
    Write-Host "=============================================" -ForegroundColor Cyan
    Write-Host ""
}

# -- Helper: recursively merge required keys into an existing value ----
# Merges $Required (hashtable) into $Existing (PSCustomObject or hashtable
# parsed from JSON). Required keys are added/overwritten; any user-added
# keys at every depth are preserved. Returns an [ordered] hashtable.
function Merge-SettingValue ($Existing, [hashtable]$Required) {
    $merged = [ordered]@{}
    # Seed with everything the user already has (preserve their additions)
    if ($Existing -is [System.Collections.IDictionary]) {
        foreach ($k in $Existing.Keys) { $merged[$k] = $Existing[$k] }
    } elseif ($Existing -is [PSCustomObject]) {
        foreach ($prop in $Existing.PSObject.Properties) { $merged[$prop.Name] = $prop.Value }
    }
    foreach ($key in $Required.Keys) {
        $val = $Required[$key]
        $cur = if ($merged.Contains($key)) { $merged[$key] } else { $null }
        $curIsObj = ($cur -is [PSCustomObject]) -or ($cur -is [System.Collections.IDictionary])
        if ($val -is [hashtable] -and $curIsObj) {
            # Both sides are objects -- recurse so nested user keys survive
            $merged[$key] = Merge-SettingValue $cur $val
        } else {
            $merged[$key] = $val
        }
    }
    return $merged
}

# -- Helper: merge installer-owned keys into existing JSON settings -----
function Merge-JsonSettings ([string]$Path, [hashtable]$Required) {
    $parsed = $null
    if (Test-Path $Path) {
        try {
            $parsed = Get-Content $Path -Raw | ConvertFrom-Json
        } catch {
            # Malformed JSON -- back up and start fresh
            Copy-Item $Path "$Path.bak" -Force
            Write-Host "  Backed up malformed settings.json to settings.json.bak" -ForegroundColor Yellow
        }
    }
    $existing = Merge-SettingValue $parsed $Required
    $json = $existing | ConvertTo-Json -Depth 10
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -Path $Path -Value $json -Encoding UTF8
}

$totalSteps = 7

# -- STEP 1 - Workspace configuration ---------------------------------
Show-Step 1 $totalSteps "Workspace Configuration"

$defaultName = "Power Platform"
$folderName = Read-Host "Enter a name for your workspace folder (default: $defaultName)"
if ([string]::IsNullOrWhiteSpace($folderName)) { $folderName = $defaultName }

$rootPath = Join-Path $env:USERPROFILE $folderName

$updateMode = $false
if (Test-Path $rootPath) {
    Write-Host "`nFolder already exists: $rootPath" -ForegroundColor Yellow
    Write-Host "Update mode: installation files (agent, configs, skills) will be" -ForegroundColor Yellow
    Write-Host "refreshed to latest. Your solutions, environments, and other" -ForegroundColor Yellow
    Write-Host "personal files will NOT be touched." -ForegroundColor Yellow
    $overwrite = Read-Host "`nContinue with update? (y/n)"
    if ($overwrite -ne 'y') { Write-Host "Aborted."; exit 0 }
    $updateMode = $true
}

Write-Host "`nWorkspace will be created at: $rootPath" -ForegroundColor White

# -- STEP 2 - Prerequisites check --------------------------------------
Show-Step 2 $totalSteps "Checking Prerequisites"

$missing = @()
$warnings = @()
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    $missing += "git (https://git-scm.com)"
} else {
    Write-Host "  Git: detected" -ForegroundColor Green
}

# Detect which VS Code command to use - user setup takes priority over system setup
$vscodeCmd = $null
$userVsCode         = Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code\bin\code.cmd"
$userVsCodeInsiders = Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code Insiders\bin\code-insiders.cmd"

if (Test-Path $userVsCode) {
    $vscodeCmd = $userVsCode
    Write-Host "  Detected: VS Code user setup" -ForegroundColor DarkGray
} elseif (Test-Path $userVsCodeInsiders) {
    $vscodeCmd = $userVsCodeInsiders
    Write-Host "  Detected: VS Code Insiders user setup" -ForegroundColor DarkGray
} elseif (Get-Command code -ErrorAction SilentlyContinue) {
    $vscodeCmd = 'code'
    Write-Host "  Detected: VS Code (system PATH)" -ForegroundColor DarkGray
} elseif (Get-Command code-insiders -ErrorAction SilentlyContinue) {
    $vscodeCmd = 'code-insiders'
    Write-Host "  Detected: VS Code Insiders (system PATH)" -ForegroundColor DarkGray
} else {
    $missing += "VS Code 1.117.0 or above (https://code.visualstudio.com)"
}

# Check VS Code version - require 1.117.0 or above
$minVsCodeVersion = [version]"1.117.0"
if ($vscodeCmd) {
    try {
        $vscodeVersionOutput = & $vscodeCmd --version 2>$null
        # --version returns: line 1 = version, line 2 = commit, line 3 = arch
        $vscodeVersionStr = ($vscodeVersionOutput | Select-Object -First 1).Trim()
        $vscodeVersion = [version]$vscodeVersionStr
        Write-Host "  VS Code version: $vscodeVersionStr" -ForegroundColor White
        if ($vscodeVersion -lt $minVsCodeVersion) {
            $missing += "VS Code $minVsCodeVersion or above (you have $vscodeVersionStr) - download from https://code.visualstudio.com"
            Write-Host "  Version $vscodeVersionStr is too old. Minimum required: $minVsCodeVersion" -ForegroundColor Red
        } else {
            Write-Host "  Version OK (>= $minVsCodeVersion)" -ForegroundColor Green
        }
    } catch {
        $warnings += "Could not determine VS Code version - please ensure you have $minVsCodeVersion or above"
    }
}

# Check for pac CLI - FORCE-install it if missing. Attempts, in order:
#   1. .NET global tool  (only if the .NET SDK is already present)
#   2. Official standalone MSI from https://aka.ms/PowerAppsCLI
#      (Windows, per-user, NO admin and NO .NET SDK required)
# The MSI route is what makes this work on a clean machine with no dotnet.
# Only fall back to the "agent will help" message if EVERY attempt fails.
if (-not (Get-Command pac -ErrorAction SilentlyContinue)) {
    Write-Host "pac CLI not found. Forcing automatic installation..." -ForegroundColor Yellow

    $dotnetToolsDir = Join-Path $env:USERPROFILE ".dotnet\tools"
    # The MSI installs pac per-user under LocalAppData and adds it to the user PATH.
    $msiToolsDirs = @(
        (Join-Path $env:LOCALAPPDATA "Microsoft\PowerAppsCLI")
        (Join-Path ${env:ProgramFiles} "Microsoft Power Platform CLI")
    )

    # Refreshes the CURRENT session PATH from the registry plus any known tool
    # dirs. A freshly installed tool often is not on the in-memory PATH yet,
    # which is the usual reason a successful install still reports "not found".
    function Update-PacSessionPath {
        $machinePath = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
        $userPath    = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
        $extra = @($dotnetToolsDir) + $msiToolsDirs
        $env:PATH = (@($machinePath, $userPath) + $extra | Where-Object { $_ }) -join ';'
    }

    # -- Attempt 1: .NET global tool (only if dotnet is available) -------
    if (Get-Command dotnet -ErrorAction SilentlyContinue) {
        try {
            Write-Host "  Trying .NET tool: Microsoft.PowerApps.CLI.Tool" -ForegroundColor DarkGray
            & dotnet tool install --global Microsoft.PowerApps.CLI.Tool 2>$null
            if ($LASTEXITCODE -ne 0) {
                # Non-zero usually means it is already installed - make sure it is current
                & dotnet tool update --global Microsoft.PowerApps.CLI.Tool 2>$null
            }
        } catch { }
        Update-PacSessionPath
    } else {
        Write-Host "  .NET SDK not present - using the standalone installer instead." -ForegroundColor DarkGray
    }

    # -- Attempt 2: official standalone MSI (no dependencies) -----------
    if (-not (Get-Command pac -ErrorAction SilentlyContinue)) {
        try {
            $msiUrl  = "https://aka.ms/PowerAppsCLI"
            $msiPath = Join-Path $env:TEMP "powerapps-cli.msi"
            Write-Host "  Downloading Power Platform CLI installer..." -ForegroundColor DarkGray
            $oldProgress = $ProgressPreference
            $ProgressPreference = 'SilentlyContinue'   # huge speed-up for Invoke-WebRequest
            Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing
            $ProgressPreference = $oldProgress
            if (Test-Path $msiPath) {
                Write-Host "  Installing pac CLI silently (this can take a minute)..." -ForegroundColor DarkGray
                $proc = Start-Process msiexec.exe -ArgumentList "/i `"$msiPath`" /quiet /norestart" -Wait -PassThru
                if ($proc.ExitCode -ne 0) {
                    Write-Host "  Installer returned exit code $($proc.ExitCode)." -ForegroundColor DarkGray
                }
                Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
            }
        } catch {
            Write-Host "  Standalone install failed: $($_.Exception.Message)" -ForegroundColor DarkGray
        }
        Update-PacSessionPath
    }

    if (Get-Command pac -ErrorAction SilentlyContinue) {
        Write-Host "  pac CLI installed successfully." -ForegroundColor Green
    } else {
        $warnings += "pac CLI could not be installed automatically - restart your terminal and re-run, or let Power Platform Master Agent guide the install on first run"
    }
} else {
    Write-Host "  PAC CLI: detected" -ForegroundColor Green
}

# Surface the PowerShell edition/version (informational - both 5.1 and 7+ work)
Write-Host "  PowerShell: $($PSVersionTable.PSEdition) $($PSVersionTable.PSVersion)" -ForegroundColor DarkGray

# Check git identity early (soft) - required later for the initial commit
if (Get-Command git -ErrorAction SilentlyContinue) {
    $gitUserCheck  = git config user.name  2>$null
    $gitEmailCheck = git config user.email 2>$null
    if ([string]::IsNullOrWhiteSpace($gitUserCheck) -or [string]::IsNullOrWhiteSpace($gitEmailCheck)) {
        $warnings += "git identity not set - the initial commit will be skipped until you run:" + [Environment]::NewLine +
                     "             git config --global user.name 'Your Name'" + [Environment]::NewLine +
                     "             git config --global user.email 'you@example.com'"
    } else {
        Write-Host "  Git identity: $gitUserCheck <$gitEmailCheck>" -ForegroundColor Green
    }
}

# Check for GitHub Copilot (the Master Agent requires it).
# Notes:
#  - `code --list-extensions` only reports user-installed marketplace extensions
#    and is unreliable while VS Code is running (can return an empty list).
#  - Modern VS Code builds ship Copilot as a BUILT-IN extension, which never
#    appears in --list-extensions, so we also probe the install tree.
#  - Absence cannot be proven, so we only inform - we never hard-warn.
if ($vscodeCmd) {
    $copilotFound = $false

    # 1) Ask the CLI (retry once to absorb flakiness)
    try {
        $exts = & $vscodeCmd --list-extensions 2>$null
        if (-not $exts) { $exts = & $vscodeCmd --list-extensions 2>$null }
        if ($exts | Where-Object { $_ -match 'copilot' }) { $copilotFound = $true }
    } catch {
        # --list-extensions can fail on some shims; non-fatal
    }

    # 2) Probe built-in (bundled) extensions of the resolved install
    if (-not $copilotFound) {
        try {
            $cmdPath = (Get-Command $vscodeCmd -ErrorAction SilentlyContinue).Source
            if (-not $cmdPath) { $cmdPath = $vscodeCmd }
            $installRoot = Split-Path (Split-Path $cmdPath -Parent) -Parent   # ...\bin\code.cmd -> root
            if ($installRoot -and (Test-Path $installRoot)) {
                $copilotProbe = @(
                    (Join-Path $installRoot 'resources\app\extensions\copilot')
                    (Join-Path $installRoot '*\resources\app\extensions\copilot')
                )
                foreach ($p in $copilotProbe) {
                    if (Test-Path $p -PathType Container) { $copilotFound = $true; break }
                }
            }
        } catch { }
    }

    if ($copilotFound) {
        Write-Host "  GitHub Copilot: detected" -ForegroundColor Green
    } else {
        Write-Host "  GitHub Copilot: not detected via CLI (it may be built in) -" -ForegroundColor DarkGray
        Write-Host "    make sure GitHub Copilot Chat is enabled in VS Code before starting." -ForegroundColor DarkGray
    }
}

# -- Power Platform Tools extension (optional) -------------------------
# Adds visual auth/environment panels and YAML support. The agent works
# without it, so this is non-blocking: we detect it and, if absent, install
# it via 'code --install-extension' (works even while VS Code is running).
if ($vscodeCmd) {
    $ppToolsId = 'microsoft-IsvExpTools.powerplatform-vscode'
    $ppFound = $false
    try {
        $exts = & $vscodeCmd --list-extensions 2>$null
        if (-not $exts) { $exts = & $vscodeCmd --list-extensions 2>$null }
        if ($exts | Where-Object { $_ -ieq $ppToolsId }) { $ppFound = $true }
    } catch { }

    if ($ppFound) {
        Write-Host "  Power Platform Tools: detected" -ForegroundColor Green
    } else {
        Write-Host "  Power Platform Tools not found - attempting install (optional)..." -ForegroundColor Yellow
        try {
            & $vscodeCmd --install-extension $ppToolsId --force 2>$null | Out-Null
        } catch { }
        $ppFound = $false
        try {
            $exts = & $vscodeCmd --list-extensions 2>$null
            if ($exts | Where-Object { $_ -ieq $ppToolsId }) { $ppFound = $true }
        } catch { }
        if ($ppFound) {
            Write-Host "  Power Platform Tools installed (restart VS Code to activate)." -ForegroundColor Green
        } else {
            $warnings += "Power Platform Tools extension could not be installed automatically (optional) -" + [Environment]::NewLine +
                         "             install it from the VS Code Marketplace for the visual auth/environment panels."
        }
    }
}

# -- Live canvas authoring prerequisites (optional, non-blocking) -------
# The checks above cover the LOCAL/OFFLINE authoring flow (pac CLI:
# export -> unpack -> edit source -> pack -> import), which is all most
# users need. The LIVE canvas authoring flow additionally drives Power
# Apps Studio in real time through the Canvas Authoring MCP server, which
# is launched with 'dnx' from the .NET 10 SDK. We force-install that SDK
# when it is missing; if it cannot be installed, live authoring is simply
# unavailable (a warning, not a blocker) - local authoring still works.
Write-Host ""
Write-Host "  -- Live canvas authoring (optional) --" -ForegroundColor DarkGray

function Get-DotNet10Root {
    # The .NET 10 SDK is often installed per-user (LOCALAPPDATA) while a
    # different 'dotnet' (e.g. C:\Program Files\dotnet) is first on PATH and
    # reports no 10.x. Probe every known dotnet.exe and return the directory of
    # the first one that exposes a 10.x SDK (that dir also contains dnx.cmd).
    $candidates = @()
    if ($env:DOTNET_ROOT) { $candidates += (Join-Path $env:DOTNET_ROOT 'dotnet.exe') }
    $candidates += (Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe')
    if (${env:ProgramFiles})      { $candidates += (Join-Path ${env:ProgramFiles} 'dotnet\dotnet.exe') }
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'dotnet\dotnet.exe') }
    $onPath = (Get-Command dotnet -ErrorAction SilentlyContinue).Source
    if ($onPath) { $candidates += $onPath }
    foreach ($exe in ($candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique)) {
        try {
            $sdks = & $exe --list-sdks 2>$null
            if ($sdks | Where-Object { $_ -match '^\s*10\.' }) { return (Split-Path $exe -Parent) }
        } catch { }
    }
    return $null
}

function Add-DirToPath {
    # Add a directory to the current session PATH and persist it (user scope),
    # so VS Code can resolve 'dnx' on future launches. Idempotent.
    param([string]$Dir)
    if (-not $Dir) { return }
    if ($env:PATH -notlike "*$Dir*") {
        $env:PATH = (@($Dir, $env:PATH) | Where-Object { $_ }) -join ';'
    }
    try {
        $userPath = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
        if ($userPath -notlike "*$Dir*") {
            [System.Environment]::SetEnvironmentVariable(
                'PATH', ((@($userPath, $Dir) | Where-Object { $_ }) -join ';'), 'User')
        }
    } catch { }
}

$net10Root = Get-DotNet10Root
if ($net10Root) {
    Add-DirToPath $net10Root
    Write-Host "  .NET 10 SDK: detected (live canvas authoring available)" -ForegroundColor Green
} else {
    Write-Host "  .NET 10 SDK not found - attempting install (needed only for LIVE canvas authoring)..." -ForegroundColor Yellow
    $dotnetInstallDir = Join-Path $env:LOCALAPPDATA "Microsoft\dotnet"

    $dlOk = $true
    $installerScript = Join-Path $env:TEMP "dotnet-install.ps1"
    try {
        $oldProgress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri "https://dot.net/v1/dotnet-install.ps1" -OutFile $installerScript -UseBasicParsing
        $ProgressPreference = $oldProgress
    } catch {
        $dlOk = $false
        Write-Host "  Could not download the .NET install script: $($_.Exception.Message)" -ForegroundColor DarkGray
    }

    if ($dlOk -and (Test-Path $installerScript)) {
        Write-Host "  Installing .NET 10 SDK (per-user, no admin; this can take a few minutes)..." -ForegroundColor DarkGray
        # Run in a child process so the official script cannot 'exit' or throw into this session.
        $psHost = (Get-Process -Id $PID -ErrorAction SilentlyContinue).Path
        if (-not $psHost) { $psHost = "powershell" }
        try {
            Start-Process -FilePath $psHost -Wait -NoNewWindow -ArgumentList @(
                "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $installerScript,
                "-Channel", "10.0", "-InstallDir", $dotnetInstallDir, "-NoPath"
            )
        } catch {
            Write-Host "  .NET 10 SDK install failed: $($_.Exception.Message)" -ForegroundColor DarkGray
        }
        Remove-Item $installerScript -Force -ErrorAction SilentlyContinue
        $env:DOTNET_ROOT = $dotnetInstallDir
    }

    $net10Root = Get-DotNet10Root
    if ($net10Root) {
        Add-DirToPath $net10Root
        Write-Host "  .NET 10 SDK installed (live canvas authoring available)." -ForegroundColor Green
    } else {
        $warnings += "Local authoring is ready, but LIVE canvas authoring is NOT enabled yet -" + [Environment]::NewLine +
                     "             it needs the .NET 10 SDK (https://dotnet.microsoft.com/download/dotnet/10.0)." + [Environment]::NewLine +
                     "             Install it, open a new terminal, then re-run this installer to enable live authoring."
    }
}

# -- Azure CLI (az) - OPTIONAL, opt-in (specific Power BI <-> Power Apps tasks) ----
# 'az' is NOT required by the workspace. It is used only by the custom
# pbi-powerapps-integration skill's cross-environment repoint workflow, to
# auto-resolve a Power Apps visual's live appId from Dataverse (the canvasapps
# table). Everything else - including the rest of that workflow - works without
# it (the skill also offers maker-portal / sibling-report fallbacks). Because it
# is so niche we do NOT auto-install it: we ask once (default: skip), try winget
# if you accept, and otherwise point you at the manual installer.
Write-Host ""
Write-Host "  -- Azure CLI (optional, for Power BI <-> Power Apps repoint tasks) --" -ForegroundColor DarkGray

function Test-AzCli {
    # Resilient 'az' probe: a fresh winget MSI updates the registry PATH but not
    # this running process, so refresh PATH from Machine+User and also probe the
    # default install location before giving up.
    if (Get-Command az -ErrorAction SilentlyContinue) { return $true }
    try {
        $machine = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
        $user    = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
        $env:PATH = (@($env:PATH, $machine, $user) | Where-Object { $_ }) -join ';'
    } catch { }
    if (Get-Command az -ErrorAction SilentlyContinue) { return $true }
    $wbin = Join-Path ${env:ProgramFiles} 'Microsoft SDKs\Azure\CLI2\wbin'
    if ((Test-Path $wbin) -and (Test-Path (Join-Path $wbin 'az.cmd'))) { Add-DirToPath $wbin; return $true }
    return $false
}

$azLink = "https://aka.ms/installazurecli"
if (Test-AzCli) {
    Write-Host "  Azure CLI (az): detected" -ForegroundColor Green
} else {
    Write-Host "  Azure CLI (az) is optional - only used to auto-resolve Power Apps appIds during the" -ForegroundColor Gray
    Write-Host "  Power BI <-> Power Apps repoint workflow (maker-portal / sibling-report fallbacks exist)." -ForegroundColor Gray
    $azAns = Read-Host "  Install Azure CLI now? (y/N)"
    if ($azAns -match '^\s*(y|yes)\s*$') {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Host "  Installing Azure CLI via winget (Microsoft.AzureCLI)..." -ForegroundColor DarkGray
            try { & winget install --silent --accept-package-agreements --accept-source-agreements -e --id Microsoft.AzureCLI 2>$null | Out-Null } catch { }
            if (Test-AzCli) {
                Write-Host "  Azure CLI installed (open a new terminal if 'az' isn't found right away)." -ForegroundColor Green
            } else {
                Write-Host "  OK - Azure CLI wasn't installed automatically. If you later need the repoint" -ForegroundColor Yellow
                Write-Host "       integration, install it from: $azLink" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "  OK - winget isn't available, so Azure CLI wasn't installed. If you later need the" -ForegroundColor Yellow
            Write-Host "       repoint integration, install it from: $azLink" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  Skipped. If you later need the Power BI <-> Power Apps repoint integration," -ForegroundColor DarkGray
        Write-Host "  install Azure CLI from: $azLink" -ForegroundColor DarkGray
    }
}

if ($missing.Count -gt 0) {
    Write-Host "`nMissing prerequisites:" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host "`nInstall the above and re-run this script."
    exit 1
}

if ($warnings.Count -gt 0) {
    Write-Host ""
    $warnings | ForEach-Object { Write-Host "  WARNING: $_" -ForegroundColor Yellow }
    Write-Host ""
}

Write-Host "All prerequisites found." -ForegroundColor Green
Read-Host "`nPress Enter to continue setup..."

# -- STEP 3 - Create folder structure ----------------------------------
Show-Step 3 $totalSteps "Creating Folder Structure"
$dirs = @(
    $rootPath
    "$rootPath\exports"
    "$rootPath\deploy"
    "$rootPath\scripts"
    "$rootPath\.github\agents"
    "$rootPath\.github\agent-docs"
    "$rootPath\.github\hooks"
    "$rootPath\.github\skills\pbi-powerapps-integration"
    "$rootPath\.vscode"
)
foreach ($d in $dirs) {
    if (-not (Test-Path $d)) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Write-Host "  Created: $($d.Replace($rootPath, '.'))"
    }
}

Write-Host "`nFolder structure ready." -ForegroundColor Green
Read-Host "`nPress Enter to continue..."

# -- STEP 4 - Generate configuration files -----------------------------
Show-Step 4 $totalSteps "Generating Configuration Files"

# -- .gitignore --------------------------------------------------------
$gitignorePath = "$rootPath\.gitignore"
if ($updateMode -or -not (Test-Path $gitignorePath)) {
    @"
*.zip
exports/
node_modules/
.env
*.log
*.user
power-platform-skills/
"@ | Set-Content -Path $gitignorePath -Encoding UTF8
    Write-Host "  $(if ($updateMode -and (Test-Path $gitignorePath)) {'Updated'} else {'Created'}) .gitignore"
}

# -- scripts/pac-workflows.ps1 ----------------------------------------
$pacWorkflowsPath = "$rootPath\scripts\pac-workflows.ps1"
if ($updateMode -or -not (Test-Path $pacWorkflowsPath)) {
    @'
# Power Platform PAC CLI helper workflows
# Used by Power Platform Master Agent - can also be run manually

param(
  [string]$Action,       # pull | push | init
  [string]$SolutionName,
  [string]$Environment,  # DEV | TEST | PROD
  [string]$PackageType = "Unmanaged"
)

# -- Verify git identity is configured (required for commits) ----------
$gitUser  = git config user.name  2>$null
$gitEmail = git config user.email 2>$null
if ([string]::IsNullOrWhiteSpace($gitUser) -or [string]::IsNullOrWhiteSpace($gitEmail)) {
    Write-Host "ERROR: git user.name and user.email must be configured before committing." -ForegroundColor Red
    Write-Host "  Run:  git config --global user.name 'Your Name'" -ForegroundColor Yellow
    Write-Host "  Run:  git config --global user.email 'you@example.com'" -ForegroundColor Yellow
    exit 1
}

$exportsPath = "./exports"
$srcPath     = "./$Environment"
$deployPath  = "./deploy"

switch ($Action) {
  "pull" {
    Write-Host "Exporting $SolutionName from $Environment..."
    pac solution export --name $SolutionName --path "$exportsPath/$SolutionName.zip"
    pac solution unpack --zipfile "$exportsPath/$SolutionName.zip" --folder "$srcPath/$SolutionName"
    git add .
    git commit -m "chore: pull $SolutionName from $Environment"
    Write-Host "Pull complete."
  }
  "push" {
    Write-Host "Packing $SolutionName..."
    pac solution pack --zipfile "$deployPath/$SolutionName.zip" --folder "$srcPath/$SolutionName" --packagetype $PackageType
    Write-Host "Importing to $Environment..."
    pac solution import --path "$deployPath/$SolutionName.zip"
    git add .
    git commit -m "feat: push $SolutionName to $Environment"
    Write-Host "Push complete."
  }
  "init" {
    Write-Host "Initialising new solution $SolutionName..."
    New-Item -ItemType Directory -Path "$srcPath/$SolutionName" -Force
    pac solution init --publisher-name $SolutionName --publisher-prefix pp --output-directory "$srcPath/$SolutionName"
    git add .
    git commit -m "chore: init solution $SolutionName"
    Write-Host "Init complete."
  }
}
'@ | Set-Content -Path $pacWorkflowsPath -Encoding UTF8
    Write-Host "  $(if ($updateMode) {'Updated'} else {'Created'}) scripts/pac-workflows.ps1"
} else {
    Write-Host "  Exists: scripts/pac-workflows.ps1" -ForegroundColor DarkGray
}

# -- .github/copilot-instructions.md -----------------------------------
$copilotInstructionsPath = "$rootPath\.github\copilot-instructions.md"
if ($updateMode -or -not (Test-Path $copilotInstructionsPath)) {
    @'
# Copilot Workspace Instructions

This is a Power Platform development workspace.

## Agent

The primary agent is **Power Platform Master Agent**, defined in
`.github/agents/power-platform-master-agent.agent.md`.
Select it from the Copilot Chat agent dropdown to begin.

## Skills

Two skill sources, read both:

1. **Microsoft Power Platform skills** (cloned, gitignored) live in
   `power-platform-skills/`. Before any skill-based task, read the relevant
   `SKILL.md` under `power-platform-skills/plugins/<plugin>/skills/`.
   Available plugins: canvas-apps, code-apps, model-apps, power-pages, mcp-apps.
2. **Custom embedded skills** (committed, maintainer house style) live in
   `.github/skills/<name>/SKILL.md`. Currently:
   `.github/skills/pbi-powerapps-integration/SKILL.md` - read it for any work on
   a canvas app embedded in a Power BI report (the `PowerBIIntegration` object,
   stale-schema issues, field-well changes) or repointing Power Apps / Flow
   visuals across DevOps branches (dev/stage/prod). It layers first-hand knowledge
   on top of the cloned canvas-apps skills; the custom skill takes precedence where
   they overlap.

## Workspace conventions

- Solutions are unpacked into `<EnvironmentName>/<SolutionName>/` at the root.
- `exports/` holds raw .zip exports (gitignored).
- `deploy/` holds packed .zip files for import.
- `scripts/pac-workflows.ps1` provides pull, push, and init helpers.
- Commits follow Conventional Commits (`chore:` for pulls, `feat:` for pushes).
'@ | Set-Content -Path $copilotInstructionsPath -Encoding UTF8
    Write-Host "  $(if ($updateMode) {'Updated'} else {'Created'}) .github/copilot-instructions.md"
} else {
    Write-Host "  Exists: .github/copilot-instructions.md" -ForegroundColor DarkGray
}

# -- AGENTS.md ---------------------------------------------------------
$agentsReadmePath = "$rootPath\AGENTS.md"
if ($updateMode -or -not (Test-Path $agentsReadmePath)) {
    @'
# Power Platform - Agent Guide

## How to use this workspace

Open this folder in VS Code.
In Copilot Chat, select **Power Platform Master Agent** from the agent dropdown.
Type anything to begin. The agent handles everything from there.

You never need to manually switch agents. Power Platform Master Agent routes
automatically between Starting mode (session setup and sync) and
Working mode (editing, pull, push).

---

## Agent architecture

### Power Platform Master Agent  `.github/agents/power-platform-master-agent.agent.md`
Single entry point. Select this in the Copilot Chat dropdown.
Routes between two modes automatically:

**Starting mode** (defined in `.github/agent-docs/starting-flow.md`):
skills -> sign in -> environment -> readiness (incl. live authoring) -> inventory -> sync

**Working mode** (defined in `.github/agent-docs/working-flow-reference.md`):
full ALM lifecycle using power-platform-skills plugins

---

## Workspace structure

```
[EnvironmentName]/
  [SolutionName]/       ? unpacked solution source (XML, JSON, YAML)
exports/                ? raw .zip exports (gitignored)
deploy/                 ? packed .zip files ready to import
scripts/                ? pac-workflows.ps1 helper script
power-platform-skills/  ? cloned Microsoft skills repo (gitignored)
.github/agents/         ? agent definitions
.github/skills/         ? custom embedded skills (committed, house style)
```

---

## Working mode commands (say these to Power Platform Master Agent)

```
"pull [SolutionName]"          -> export + unpack + commit
"push [SolutionName] to TEST"  -> pack + import + commit
"edit [component] in [solution]" -> agentic edit using skills
"live edit [app]"              -> real-time canvas coauthoring (open browser + MCP)
"new solution [name]"          -> scaffold new solution
"compare DEV and TEST"         -> diff two environments
"status"                       -> auth + solutions + git summary
```
'@ | Set-Content -Path $agentsReadmePath -Encoding UTF8
    Write-Host "  $(if ($updateMode) {'Updated'} else {'Created'}) AGENTS.md"
} else {
    Write-Host "  Exists: AGENTS.md" -ForegroundColor DarkGray
}


# -- .github/agents/power-platform-master-agent.agent.md --------------------
$agentPath = "$rootPath\.github\agents\power-platform-master-agent.agent.md"
if ($updateMode -or -not (Test-Path $agentPath)) {
    @'
---
name: "Power Platform Master Agent"
description: "Master coordinator for all Power Platform work. Use when - Power Platform, pac CLI, canvas apps, live coauthoring, solution management, environment sync, pull, push, deploy, ALM lifecycle."
tools: [execute, read, edit, search, agent, todo, canvas-authoring/*]
---

# Power Platform Master Agent

You are the single entry point for Power Platform work. You always get the user
set up first (skills, sign-in, environment, readiness), then you help them work.
Two kinds of work, both equally important:

- **Offline authoring** - export -> unpack -> edit -> pack -> import via pac.
  Works for EVERY component (canvas apps, Power Automate flows, model-driven
  forms/views, pages, code apps, ...).
- **Live coauthoring** - real-time editing of an open Power Apps Studio browser
  tab via the `canvas-authoring` MCP tools. Canvas apps only.

You route automatically; the user never switches agents or modes.

## First turn of a session

A SessionStart hook (`.github/hooks/clear-session.json`) deletes any leftover
`.session-active` marker when a new chat session begins - so a MISSING marker
reliably means "new session, not set up yet." Before responding, read these two
files to load context and warm up the tools:

1. Read `.github/copilot-instructions.md`
2. Read `AGENTS.md`

If both fail, read `scripts/pac-workflows.ps1` and retry once. If it still
fails, show the **VS Code tool error** message below and stop.

## Routing

- **`.session-active` EXISTS** -> you're already set up this session. Read
  `.github/agent-docs/working-flow-reference.md` and handle the request.

- **`.session-active` does NOT exist** -> fresh session. Don't railroad the user
  through full setup. Offer a quick choice first, in one friendly line:

  "Want me to run the full setup (sign-in, environment, sync, readiness), or
   just get to work? [S] set me up - [W] just work"

  - **S - full setup** -> read `.github/agent-docs/starting-flow.md` and run it
    end to end (it writes `.session-active` with `mode: full`).
  - **W - just work** -> do ONLY what's obligatory: confirm there is an active
    sign-in and a selected environment. Run `pac org who`; if it shows no auth
    or no environment, run just the sign-in + environment steps from
    starting-flow (Phases 2-3) - nothing else (no skills pull, inventory, or
    full sync). Then write `.session-active` with `mode: quick` and handle the
    request. Pull/export a solution only if the task actually needs local source.

  If the first message clearly implies a path (e.g. "just tweak the canvas app I
  have open" -> W), pick it and say which, but still confirm sign-in + env.

Routing is invisible - never tell the user to switch agents or modes.

## Guardrails

- Canvas authoring is browser-based. There is NO Power Apps desktop app - never
  tell the user they need one. Live coauthoring simply attaches to an open Power
  Apps Studio browser tab that has coauthoring turned on.
- Use the `canvas-authoring` MCP tools for live edits; use pac for the offline
  flow. Non-canvas components are offline only.

## VS Code tool error message

If tool warm-up fails twice, show this and stop, then wait for the user:

---
**VS Code tool error detected.**

This workspace requires **VS Code 1.117.0 or above**. Older versions have known
bugs that break Copilot agent tools.

**Check your version:** Help > About (or run `code --version` in a terminal).

- If below 1.117.0: update from https://code.visualstudio.com
- If 1.117.0 or above: disable then re-enable GitHub Copilot Chat AI Features,
  open a new chat, and try again.
---

'@ | Set-Content -Path $agentPath -Encoding UTF8
    Write-Host "  $(if ($updateMode) {'Updated'} else {'Created'}) .github/agents/power-platform-master-agent.agent.md"
} else {
    Write-Host "  Exists: .github/agents/power-platform-master-agent.agent.md" -ForegroundColor DarkGray
}

# -- .github/agent-docs/starting-flow.md --------------------------------
$startingFlowPath = "$rootPath\.github\agent-docs\starting-flow.md"
if ($updateMode -or -not (Test-Path $startingFlowPath)) {
    @'
# Setup Flow - Power Platform Master Agent

Run this the first time each session, before working on the user's task. Goal:
get them signed in, pointed at an environment, and fully set up (including live
canvas authoring) - in a friendly, step-by-step way. Keep each step short and
conversational: say what you're doing, do it, confirm, move on. Don't dump it
all at once.

You have already read copilot-instructions.md + AGENTS.md and pulled the skills
repo (the agent's first-turn warm-up).

---

## Phase 0 - Read the room

Look at the user's opening message and remember it (you return to it at the end):

- **GREETING** (hi / hello / hey, no specific task) -> greet back warmly in their
  tone, then: "Let me get you set up first - it'll only take a moment."
- **TASK / QUESTION** (an actual request) -> "Love it. Let me get you set up
  first so I can do that properly, then I'll jump right on it."

Proceed to Phase 1 immediately - don't wait for a reply.

---

## Phase 1 - Latest skills

The skills pull already ran on warm-up:

- Succeeded -> "Skills are up to date." Then list the plugins:
  `ls power-platform-skills/plugins/`  and report them (e.g. "Available:
  canvas-apps, model-apps, code-apps, power-pages, mcp-apps.").
- Failed (offline) -> "Couldn't refresh skills - using the local copy."
- Folder missing -> clone it:
  `git clone https://github.com/microsoft/power-platform-skills.git power-platform-skills`

The custom embedded skill `.github/skills/pbi-powerapps-integration/SKILL.md` is
always present (committed) regardless of the clone's state.

Move on to Phase 2.

---

## Phase 2 - Sign in

Run: `pac auth list`

- **Active profile exists** -> "You're signed in as [email]. I'll use that -
  just say 'switch account' anytime to change."
- **No profile** -> "Let's get you signed in. What email should I use?" Wait for
  it, then run `pac auth create --deviceCode`, show the URL + code
  ("Open [URL] and enter code [CODE] to sign in."), and wait for them to finish.
  Confirm "Signed in as [email]."

Move on to Phase 3.

---

## Phase 3 - Pick an environment

Run: `pac org list`. Present a numbered list, e.g.:

 "[1] Contoso - DEV (org1abc.crm.dynamics.com)
  [2] Contoso - TEST (org2def.crm.dynamics.com)
  Which environment do you want to work in? Enter a number:"

Wait for their pick, extract its environment URL, run
`pac org select --environment [url]`, and confirm "Connected to [environment]."

Move on to Phase 4.

---

## Phase 4 - Readiness check ("are we all set?")

Quickly confirm the toolbox and tell the user what's available. Keep it to a
line or two.

1. **pac CLI** - already used in Phases 2-3, so it's working. (If `pac` errors,
   tell them to re-run the workspace installer.)
2. **Live canvas coauthoring readiness:**
   - Check `dnx` is available (it ships with the .NET 10 SDK): run `dnx --version`,
     or `dotnet --list-sdks` and look for a `10.x` line.
   - Confirm `canvas-authoring` is registered in `.vscode/mcp.json`.
   - **Both present** -> "Live canvas coauthoring is ready. (The MCP server
     starts automatically the first time you use it - nothing to start by hand.)"
   - **dnx / .NET 10 missing** -> "Heads up: live canvas coauthoring needs the
     .NET 10 SDK, which isn't installed yet. Everything else works. To enable it
     later, install .NET 10
     (https://dotnet.microsoft.com/download/dotnet/10.0) or re-run the workspace
     installer." Do NOT block - keep going.

Move on to Phase 5.

---

## Phase 5 - Inventory the environment

Run: `pac solution list`. Also try (skip silently if unsupported):
  `pac canvas list`, `pac flow list`

Group results into:
  - Solutions (name, version, managed/unmanaged)
  - Loose items not in any solution (canvas apps, flows, etc.)

Present a clear inventory. If a command is unsupported, note briefly:
"Note: [item type] listing isn't fully supported by pac CLI - you may have more
in the portal."

Move on to Phase 6.

---

## Phase 6 - Sync the local folder

Check if `[EnvironmentName]/` exists locally (at workspace root).

**If it does NOT exist:**
Say: "No local folder for this environment yet - creating it and pulling
everything down now..."
Create `[EnvironmentName]/`, and for each solution:
  pac solution export --name [SolutionName] --path ./exports/[SolutionName].zip
  pac solution unpack --zipfile ./exports/[SolutionName].zip --folder ./[EnvironmentName]/[SolutionName]
Commit: "chore: initial pull [EnvironmentName]"

**If it already exists:**
Say: "Found a local folder for [EnvironmentName]. Checking for differences..."
For each online solution, compare with `[EnvironmentName]/[SolutionName]/`:
- Online but NOT local -> pull it automatically.
- In BOTH -> ask:
  "Solution [SolutionName] exists online and locally. Which to keep?
   [1] Keep my local version  [2] Pull and overwrite local"
  Wait for the answer before moving to the next.
After resolving, run the chosen pulls and commit:
"chore: sync [EnvironmentName] - resolved [n] conflicts"

Move on to Phase 7.

---

## Phase 7 - All set -> over to work

Create the session marker `.session-active` at the workspace root with:
```
environment: [environment name]
authenticated: true
synced: [number of solutions]
mode: full
live_authoring: [ready | needs-dotnet-10]
```

Give a short, friendly summary:
"You're all set!
 - Signed in: [email]
 - Environment: [environment]
 - Solutions synced: [n]
 - Live canvas coauthoring: [ready / needs .NET 10]"

Then return to the Phase 0 message:

- **It was a TASK / QUESTION** -> "Now, back to what you asked..." then read
  `.github/agent-docs/working-flow-reference.md` and do it. Don't make them repeat it.
- **It was a GREETING** -> "So - what would you like to do? I can pull or push
  solutions, edit a component offline (any type), or live-coauthor a canvas app
  you've got open in Studio." Then wait.

'@ | Set-Content -Path $startingFlowPath -Encoding UTF8
    Write-Host "  $(if ($updateMode) {'Updated'} else {'Created'}) .github/agent-docs/starting-flow.md"
} else {
    Write-Host "  Exists: .github/agent-docs/starting-flow.md" -ForegroundColor DarkGray
}

# -- .github/agent-docs/working-flow-reference.md ----------------------
$workingFlowPath = "$rootPath\.github\agent-docs\working-flow-reference.md"
if ($updateMode -or -not (Test-Path $workingFlowPath)) {
    @'
# Working Flow Reference - Power Platform Master Agent

This file is read by the agent after the Starting Flow has completed and
`.session-active` exists. It defines all capabilities available in working mode.

---

## Skill Discovery - ALWAYS Dynamic

Two skill sources. **NEVER assume you know what skills exist.** Always discover
dynamically.

**A. Custom embedded skills (committed, maintainer house style)** under
`.github/skills/<name>/SKILL.md`. These are first-hand, maintainer-authored and
take **precedence** over cloned skills where they overlap. Check them first:

- `.github/skills/pbi-powerapps-integration/SKILL.md` - canvas apps embedded in
  a Power BI report via the Power Apps visual (`PowerBIIntegration.Data` /
  `.Refresh()`, the "re-edit from the Power BI Service" golden rule, the
  1000-row cap, and a stale-schema troubleshooting playbook). Read it whenever
  the app uses `PowerBIIntegration`, is launched with `source=PowerBIIntegration`,
  or the user mentions the Power Apps visual / Power BI integration / columns
  from the visual's field well. **Also read it for cross-environment repoint
  tasks** - hardcoding the right `appId` / `EnvironmentId` into Power Apps / Flow
  visuals per DevOps branch (dev/stage/prod): "repoint", "hardcode the prod ids",
  "lock the app/flow ids per environment".

**B. Microsoft cloned skills** under `power-platform-skills/plugins/`. These
evolve frequently.

**Before performing any skill-based task:**

1. List the plugin's skills directory:
   `ls power-platform-skills/plugins/[plugin-name]/skills/`
2. Read the plugin's `AGENTS.md`:
   `power-platform-skills/plugins/[plugin-name]/AGENTS.md`
3. Read the `SKILL.md` inside the relevant skill folder
4. Read any `references/` docs mentioned in the SKILL.md
5. Follow the SKILL.md instructions step by step

**Available plugin directories** (list `power-platform-skills/plugins/` to
confirm what is currently available):

| Plugin | Purpose |
|--------|---------|
| model-apps | Model-driven app components: generative pages, forms, views, sitemap |
| code-apps | Power Apps code apps: React + Vite + TypeScript |
| canvas-apps | Canvas app source files via PA YAML format |
| power-pages | Power Pages sites: code sites with React, Angular, Vue, Astro |
| mcp-apps | MCP-based app generation |

If the user asks about a component type and you are unsure which plugin
handles it, list all plugin `skills/` directories to find the right match.

---

## Capabilities

### PULL a solution
- Export and unpack a named solution into [env]/[solution]/
- Commands:
  pac solution export --name [SolutionName] --path ./exports/[SolutionName].zip
  pac solution unpack --zipfile ./exports/[SolutionName].zip --folder ./[EnvironmentName]/[SolutionName]
- Commit with message: "chore: pull [solution] from [env]"

### PUSH a solution
- Pack [env]/[solution]/ into deploy/[solution].zip
- Commands:
  pac solution pack --zipfile ./deploy/[SolutionName].zip --folder ./[EnvironmentName]/[SolutionName] --packagetype [Unmanaged|Managed]
  pac solution import --path ./deploy/[SolutionName].zip
- Confirm the target environment before importing
- **Require explicit "yes" confirmation for Production environments**
- Commit: "feat: push [solution] to [env]"

### EDIT a component

Two editing modes, both first-class. Pick by component type and what the user wants.

**Offline authoring - works for EVERY component** (canvas apps, Power Automate
flows, model-driven forms/views/sitemap, code apps, pages, ...):
1. Pull the solution (export -> unpack) so the source is local.
2. Identify the right skills plugin and discover its skills dynamically (see
   Skill Discovery above); read the SKILL.md and follow it step by step.
3. Edit the unpacked source, then run git diff and summarise what changed.
4. Pack and import to apply (ask first). Changes show up in the platform after
   import + a refresh.

**Live coauthoring - canvas apps ONLY** (real-time; no pack/import): drives an
OPEN Power Apps Studio browser tab through the `canvas-authoring` MCP tools - see
"Live canvas coauthoring" below.

Rule of thumb: non-canvas components -> offline only. Canvas apps -> offer either
(quick tweaks shine live; larger or source-controlled changes shine offline).
Canvas authoring is browser-based - there is NO desktop app; never say otherwise.

#### Live canvas coauthoring (step by step)

Real-time editing of an OPEN Power Apps Studio session via the `canvas-authoring`
MCP server (registered in `.vscode/mcp.json`, launched on demand via `dnx`).

Prerequisites - confirm before starting:
- `.NET 10 SDK` installed (`dnx --version`, or `dotnet --list-sdks` shows a
  `10.x` line) - it provides `dnx`. If missing, tell the user to install it
  (https://dotnet.microsoft.com/download/dotnet/10.0) or re-run the installer,
  then fall back to offline.
- `canvas-authoring` present in `.vscode/mcp.json` (installer adds it). VS Code
  starts the server automatically the first time a canvas-authoring tool runs.

Steps (guide the user - it is not all automatic):
1. Open the app in **Power Apps Studio** (make.powerapps.com) in **edit** mode, in a browser.
2. Enable coauthoring: **Settings -> Updates -> Coauthoring** -> ON (save/reopen
   if prompted). Live editing does NOT work unless coauthoring is on for that app.
3. **Keep that tab OPEN the whole session** - closing it ends coauthoring and
   breaks compile_canvas / sync_canvas.
4. Copy the full Studio URL (e.g.
   https://make.powerapps.com/e/<env>/canvas/?action=edit&app-id=...).
5. Tell the agent e.g. "connect live canvas authoring" and paste the URL.
6. The agent calls the MCP `connect` tool FIRST - it "must be called before any
   other tool". Extract the three params from the URL:
   - environment_id = the segment between /e/ and the next / (a bare GUID)
   - app_id = **URL-decode** the app-id value, then take the **last `/` segment**
     -> a bare GUID. The raw `%2Fproviders%2F...%2Fapps%2F<GUID>` value will NOT
     work - decode it down to just `<GUID>` first. (This wrong-app_id mistake is
     the most common reason connect silently fails.)
   - cluster_category = from the host: make.powerapps.com /
     make.preview.powerapps.com -> prod, make.gov.powerapps.us -> gov,
     make.high.powerapps.us -> high, make.apps.appsplatform.us -> dod,
     make.powerapps.cn -> china, anything else -> test
   Omit optional params (auth_flow / login_hint) unless sign-in actually fails or
   the user needs a different account - if already signed in, connect is silent
   (no prompt). **Confirm `connect` returns "Successfully connected for app: ..."
   before calling ANY other tool.**
7. **The live read -> edit -> commit loop (VERIFIED end-to-end):**
   a. `sync_canvas { directoryPath: <dir> }` - pulls every screen/control/formula
      from the live session into `<dir>` as `.pa.yaml` (App.pa.yaml + one
      `Screen_*.pa.yaml` per screen). This is the ONLY way to read the real
      control formulas. (`list_controls` / `describe_control` only describe control
      *types* - the catalog of buttons/labels/galleries - NOT your app's instances.)
   b. Edit the `.pa.yaml` files on disk. To ADD a control, append a list item under
      the target screen's `Children:` block, matching the existing indentation
      (screen `Children:` at 4 spaces, each `- ControlName:` at 6 spaces). Example -
      a square box named `test`:

          Children:
            - test:
                Control: Rectangle
                Properties:
                  Fill: =RGBA(255, 0, 0, 1)
                  Height: =100
                  Width: =100
                  X: =700
                  Y: =50

      Property values are Power Fx and MUST start with `=`. To EDIT a control,
      change the relevant `Properties:` lines in place.
   c. `compile_canvas { directoryPath: <dir> }` - this is the COMMIT. Despite its
      name and its "Validates" description, when a live session is connected
      `compile_canvas` **uploads your local YAML to the authoring session and
      persists the change to the app** - the edit then shows in the open Studio
      tab. This is the write-back mechanism; there is no separate save/push tool.
   d. (Optional) `sync_canvas` again into a *fresh* directory to confirm the server
      now returns your change.

   **CRITICAL - do not be fooled by "Validation FAILED":** On Power BI-embedded apps
   `compile_canvas` reports hundreds of `PowerBIIntegration` / `Distinct` / `First`
   errors (e.g. "453 errors"). These are FALSE POSITIVES - the App-level
   `PowerBIIntegration` host control is not part of the synced source, so any formula
   referencing `[@PowerBIIntegration].Data` looks unresolved in isolation. **The
   commit still succeeds and your change is still applied even when validation
   "FAILED" with these errors.** Do NOT report failure or abort on them; only real
   errors on the control(s) YOU just touched matter. (More detail in the
   `pbi-powerapps-integration` skill.)
8. To stop, just close the Studio tab. Nothing to pack/import - changes are already live.

**The tool set is DYNAMIC - this is the #1 source of confusion, do not get fooled:**
- BEFORE a successful `connect`, only the base tools exist: `connect`,
  `sync_canvas`, `compile_canvas`, `list_controls`, `describe_control`,
  `list_data_sources`, `get_data_source_schema`, `list_apis`, `describe_api`.
- AFTER `connect` succeeds, the server registers MORE tools based on the backend
  version (e.g. app checker / accessibility checks). So if a checker tool "isn't
  there", you simply have not connected yet - connect first, then re-check.
- If ANY tool reports blocked / unavailable / empty / "no session", that almost
  always means **there is no live session** (connect was never done, used a still-
  encoded or wrong app_id, or the Studio tab closed and the session dropped) - NOT
  that the tool is disabled or the capability is missing. Re-run `connect` and
  retry. **Never tell the user a capability "does not exist" or "is blocked"
  without first confirming a live session ("Successfully connected") and that you
  passed a decoded GUID app_id.**
- A Power BI-embedded app (`source=PowerBIIntegration&is-hosted=true`) connects
  fine for reading - it does NOT block `connect`. For its field-well / stale-schema
  quirks, read the `.github/skills/pbi-powerapps-integration/SKILL.md` skill.

### COMPARE environments
- Pull the same solution from two different environments
- Run git diff between the two unpacked folders
- Summarise what is different

### NEW solution
- Run: pac solution init --publisher-name [name] --publisher-prefix [prefix] --output-directory ./[EnvironmentName]/[SolutionName]
- Scaffold initial structure using the appropriate skills plugin
- Commit: "chore: init solution [name]"

### STATUS check
- Run: pac auth list, pac solution list, git status, git log --oneline -10
- Present a clean summary of auth state, solutions, and recent git history

---

## Working Rules

- Never import to Production without the user typing "confirm push to prod"
- Always check pac auth list before export or import
- Always unpack after export - never commit raw .zip files
- Unmanaged for dev work, managed for production deployments
- If any pac command fails, diagnose the error, suggest a fix, ask before retrying
- Keep git history clean: one commit per logical action
- When the user says "switch account", run pac auth create --deviceCode
  with their new email and re-run the Starting Flow from Phase 3 onward

'@ | Set-Content -Path $workingFlowPath -Encoding UTF8
    Write-Host "  $(if ($updateMode) {'Updated'} else {'Created'}) .github/agent-docs/working-flow-reference.md"
} else {
    Write-Host "  Exists: .github/agent-docs/working-flow-reference.md" -ForegroundColor DarkGray
}

# -- .github/hooks/clear-session.json (reset setup each new session) ----
# A SessionStart hook deletes the .session-active marker at the start of every
# new chat session, so the agent re-offers setup (full or quick) each time
# instead of treating a stale marker as "already set up". Fires for any agent in
# this workspace. Cross-platform: 'rm' on posix; on Windows the value is run by
# PowerShell, so we use Remove-Item (idempotent, never throws on a missing file
# and contains no '&', which PowerShell rejects as an unquoted operator).
$hookPath = "$rootPath\.github\hooks\clear-session.json"
if ($updateMode -or -not (Test-Path $hookPath)) {
    @'
{
  "hooks": {
    "SessionStart": [
      {
        "type": "command",
        "command": "rm -f .session-active",
        "windows": "powershell -NoProfile -Command \"Remove-Item -Force -ErrorAction SilentlyContinue .session-active; exit 0\""
      }
    ]
  }
}
'@ | Set-Content -Path $hookPath -Encoding UTF8
    Write-Host "  $(if ($updateMode) {'Updated'} else {'Created'}) .github/hooks/clear-session.json"
} else {
    Write-Host "  Exists: .github/hooks/clear-session.json" -ForegroundColor DarkGray
}

# -- .github/skills/pbi-powerapps-integration/SKILL.md -----------------
# Custom, maintainer-authored skill (committed - NOT gitignored). Embedded here
# so it is (re)installed and kept current on every run, layering first-hand
# Power BI <-> Power Apps integration knowledge on top of the cloned Microsoft
# canvas-apps skills. This here-string is the source of truth: edit it and
# re-run, or edit the file directly - its on-disk mtime is the freshness signal.
$pbiPaSkillPath = "$rootPath\.github\skills\pbi-powerapps-integration\SKILL.md"
if ($updateMode -or -not (Test-Path $pbiPaSkillPath)) {
    @'
---
name: pbi-powerapps-integration
description: "Use when: building, editing, or debugging a canvas app embedded in a Power BI report via the Power Apps visual (the PowerBIIntegration object), OR repointing Power Apps / Power Automate visuals across DevOps branches (dev -> stage -> prod). Covers the field-well -> schema hand-off, the golden rule that field changes must be re-edited from the Power BI SERVICE, the PowerBIIntegration.Data / .Refresh() API surface, platform limitations, a troubleshooting playbook for stale-schema errors, and the end-to-end cross-environment REPOINT workflow that hardcodes the correct appId / EnvironmentId per branch."
---

# Power BI <-> Power Apps Integration Skill

## Provenance and maintenance

- **Authored from**: a real production incident (a Power BI-embedded
  canvas app whose `PowerBIIntegration.Data` showed stale columns after the report's
  field well was changed in Desktop) plus the official Microsoft documentation
  ([Power Apps visual for Power BI](https://learn.microsoft.com/en-us/power-apps/maker/canvas-apps/powerapps-custom-visual)).
- **Independent / house style**: written first-hand from the incident and Microsoft
  Learn; not copied or AI-rewritten from any GPL-licensed source.
- **Updating**: edit the PS1 installer (source of truth) and re-run it, or edit this
  file directly. The agent does NOT auto-modify it (it is maintainer house style).
- **Freshness**: this file's on-disk modification time reflects the last update.

---

## When to use

- A canvas app is opened from / embedded in a Power BI report (URL contains
  `source=PowerBIIntegration`, `is-hosted=true`, or the app uses the `PowerBIIntegration`
  object / `PowerBI` control).
- The user mentions: "Power Apps visual", "Power BI integration", "PowerBIIntegration",
  fields/columns "from the visual's well", or formulas that reference report data.
- Symptoms: new columns added in Power BI don't appear in the app; IntelliSense shows an
  old set of columns; formulas referencing a recently-added field throw errors; data
  isn't passing into the app while editing.
- **Cross-environment repoint** task: the user gives a report (or reports) that lives in
  several DevOps branches (dev/prod, or dev/stage/prod) and wants the Power Apps / Power
  Automate visuals in each branch to point at that branch's Power Platform environment.
  Phrasings: "repoint", "these visuals point to dev, fix prod", "hardcode the prod ids",
  "lock the app/flow ids per environment". -> jump to **Cross-environment repoint
  workflow** below.

---

## Core mental model (read this first)

The **Power Apps visual** in a Power BI report has a **"Power Apps Data" field well**.
Whatever columns sit in that well are pushed into the canvas app as the **read-only
`PowerBIIntegration.Data`** table (it behaves like any other read-only data source /
collection).

The single most important fact:

> **The canvas app SNAPSHOTS the field-well schema at the moment Power Apps Studio is
> launched from the visual. It does NOT live-refresh that schema when you later change
> the well.** Change the well while Studio is open (or relaunch from the wrong place) and
> the app keeps advertising the OLD columns -> IntelliSense is stale and any formula
> touching a new column errors.

A clean reload of the app against the *current* well compiles fine. So "old columns" is
almost always a **stale Studio session**, not a broken app.

---

## THE GOLDEN RULE (the #1 cause of "old columns")

Microsoft, verbatim:

> *"If you change the data fields associated with the visual, you must edit the app from
> within the Power BI **service** by selecting the ellipsis (...) and then selecting
> **Edit**. Otherwise, the changes won't be propagated to Power Apps, and the app will
> behave in unexpected ways."*

Practical rules that follow:

1. **Any time you add / remove / rename a column in the visual's field well, you MUST
   re-launch Power Apps Studio for the app to pick up the new schema.** Refreshing the
   Studio browser tab/URL is **not** enough - the schema only re-injects on a *fresh
   launch from the visual*.
2. **Re-launch from the Power BI SERVICE (web), not Desktop**, for field-well changes:
   report (edit mode) -> select the Power Apps visual -> **More options (...)** ->
   **Edit**. Editing from Desktop after a field change will **not** propagate reliably.
3. **Desktop provides data when CREATING an app but not while EDITING.** Use **Power BI
   web** to preview live data while editing. (Per docs: *"Power Apps in Power BI Desktop
   provides data to Power Apps Studio when creating apps but not while editing. Use Power
   BI Web to preview the data while editing apps."*)
4. **Publish the report to the Service first**, then create/modify the app. Microsoft's
   recommendation: *"first publish your report to the Power BI service and then create or
   modify apps."*
5. The launch point and the report you changed **must be the same report**. Columns added
   in Desktop won't help if you relaunch Studio from an older, not-yet-republished Service
   report (and vice-versa). **Publish, then relaunch from Service.**

---

## Troubleshooting playbook - "my new columns don't show / formulas error"

Run these in order; stop when fixed.

1. **Confirm the well.** In the report, select the Power Apps visual and verify ALL the
   intended columns are in the **"Power Apps Data" field well**.
2. **Publish.** Save (Desktop) and **publish to the Power BI Service**. The Service copy
   is what hands the schema to the app.
3. **Fully close** the current Power Apps Studio tab. (Do not just refresh.)
4. **Relaunch from Service:** open the report in the **Power BI Service**, edit mode ->
   Power Apps visual -> **... -> Edit**. `PowerBIIntegration.Data` now exposes the new
   columns; IntelliSense and formulas resolve.
5. **Still stale? Re-seat the fields (known fallback).** Power BI sometimes caches the
   field-to-app mapping on the visual itself:
   - Remove **all** fields from the "Power Apps Data" well.
   - Re-add **all** the columns fresh.
   - Save/publish, then relaunch Studio from the Service visual.
6. **Verify in Studio.** Type `PowerBIIntegration.Data.` and confirm IntelliSense lists
   every expected column. Run App Checker - it should be clean once the schema matches.

### Live-coauthoring / MCP note (this workspace)
When connected via the `canvas-authoring` MCP tools, a fresh `connect` loads the app
against the current schema. If `get_appchecker_errors` returns **0 issues** but the user
still sees old columns, that **confirms** the problem is the user's stale browser tab, not
the app source - the fix is to **relaunch their Studio tab from the Service visual**, not
a YAML edit.

**Editing a PBI-embedded app live (verified loop):** `sync_canvas` -> edit `.pa.yaml` ->
`compile_canvas` commits the change to the live session (it is the write-back, not just a
validator). `compile_canvas` will report hundreds of `PowerBIIntegration` / `Distinct` /
`First` errors (e.g. "453 errors, Validation FAILED") because the App-level
`PowerBIIntegration` host control is NOT in the synced source, so those formulas look
unresolved in isolation. **These are false positives and the commit still applies.** Do
not abort or report failure on them - only errors on the control(s) you actually edited
count.

**The "integration disappears while authoring" pattern (undocumented - learned the hard
way):** The moment you author live over MCP, the `PowerBIIntegration` node **drops out of
the Studio left Tree-view pane** and every formula that references the report's field-well
columns (`PowerBIIntegration.Data`, `First([@PowerBIIntegration].Data).<Col>`, etc.) turns
**red with "name isn't recognized"** errors. This is because the MCP coauthoring source
does not include the App-level `PowerBIIntegration` host - the Power BI visual injects it
only at launch. What to do:
- **Do NOT "fix" the red by deleting or rewriting those references.** They are correct;
  the host is just temporarily detached. Removing them would actually break the app.
- **Keep authoring with the real column names** exactly as they appear in the field well.
  Write your new logic referencing `PowerBIIntegration.Data` / the well columns as normal
  and `compile_canvas`-commit it despite the red.
- **If you don't know the exact column names** the logic needs, you cannot introspect the
  well while the host is detached - **ask the user which field-well column names to
  reference**, then use those verbatim.
- **The red clears itself on re-launch.** Once the user re-connects / relaunches the app
  from the **Power BI Service visual** (... -> Edit), the `PowerBIIntegration` host is
  re-injected, the node returns to the tree, and all those references resolve - your
  committed logic now works. So the correct hand-off is: *"I've applied the change; the
  PowerBIIntegration errors you see are expected during live authoring - reopen the app
  from the Power BI Service and they'll resolve."*

---

## `PowerBIIntegration` API surface

| Member | What it is | Notes |
|--------|-----------|-------|
| `PowerBIIntegration.Data` | Read-only table of the rows passed from the report's field well | Behaves like a data source / collection. Use `First()`, `LookUp()`, `Filter()`, `Gallery.Items`, etc. **Read-only** - you cannot write back to it. |
| `PowerBIIntegration.Refresh()` | Triggers a refresh of the underlying Power BI data | **Only available if the app was CREATED from the Power Apps visual** AND the data source supports / uses **DirectQuery**. Not available in apps merely associated later, nor on import-mode models. Cannot trigger refresh from Power BI **Desktop**. |

### Example formulas
```powerfx
// First row of the report data
First(PowerBIIntegration.Data).Customer_Name

// Join Power BI data with a Dataverse/other source
LookUp(Customer, Customer_x0020_Name = First(PowerBIIntegration.Data).Customer_Name)

// Bind a gallery to the report rows
Gallery1.Items = PowerBIIntegration.Data

// Refresh the report data (only for apps created from the visual on a DirectQuery source)
PowerBIIntegration.Refresh()
```

> **Column name encoding:** spaces and special characters in Power BI column names are
> escaped in Power Fx (e.g. a space becomes `_x0020_`). After adding columns, confirm the
> exact escaped name via IntelliSense rather than guessing.

---

## Hard limitations (design within these)

- **1,000-row cap.** A maximum of **1000 records** can be passed from Power BI into the
  app via `PowerBIIntegration`. Pre-aggregate/filter in the report for larger datasets.
- **No filtering / write-back to the report.** The Power Apps visual **cannot filter the
  report or send data back** to it. Writing back to the same source as the report won't
  reflect immediately in Desktop - only on the next scheduled refresh.
- **Field changes require Service re-edit** (the Golden Rule above).
- **Desktop = data only on create, not on edit.** Preview live data on Power BI **web**.
- **`Refresh()` constraints.** App must be created from the visual AND use DirectQuery.
- **Embedding scope.** Supported only for **"Embed for your organization"** - *not*
  "Embed for your customers". No **multi-level embedding** on sovereign clouds (e.g.
  report-in-SharePoint-in-Teams).
- **Guest users** are supported only when the app URI carries the tenantId, the Power BI
  portal authenticates the user (no anonymous access), and the app is shared with them.
- **Sharing is separate.** The app must be **shared with report users independently** of
  sharing the report.
- **Power BI Report Server is not supported.**
- **Power BI mobile app** doesn't support the **microphone** control in Power Apps visuals.
- **`Launch()`** in the visual supports **https only**.

---

## Browser support

| Browser | View | Create | Modify |
|---------|:----:|:------:|:------:|
| Microsoft Edge | yes | yes | yes |
| Google Chrome | yes | yes | yes |
| Safari | yes | - | - | *(must clear "Prevent cross-site tracking" in Privacy)* |
| Firefox / others | - | - | - |

Use **Edge or Chrome** for any create/modify work.

---

## Quick checklist (paste-ready)

When a user reports Power BI integration trouble, walk this list:

- [ ] Are the new columns actually in the visual's **"Power Apps Data" field well**?
- [ ] Is the report **published to the Service** with those columns?
- [ ] Did they **fully close** Studio (not just refresh)?
- [ ] Did they **relaunch from the Service** visual via **... -> Edit** (not Desktop)?
- [ ] If still stale: did they **remove + re-add all fields** and relaunch?
- [ ] Are they on **Edge/Chrome**?
- [ ] Is the dataset within the **1000-row** limit?
- [ ] If they need `Refresh()`: was the app **created from the visual** on a **DirectQuery** source?

---

## Cross-environment repoint workflow (lock PowerApps/Flow visuals per DevOps branch)

> **Authored from**: a real workspace task - repointing a Power BI report's embedded
> Power Platform visuals from one environment to another across DevOps branches.
> Mechanical and repeatable; this section is the A-to-Z playbook.

### What this is
A **Power Apps visual** and a **Power Automate (Flow) visual** embedded in a Power BI
(PBIR) report each carry a **hardcoded pointer to one specific Power Platform
environment**. When the same report is promoted through DevOps branches
(`dev -> prod`, or `dev -> stage -> prod`), every branch's copy must point at the
**matching** environment. The pointers are static literals inside each `visual.json`;
rewriting them "locks" each branch to its environment (they act like a fixed parameter
and survive future development).

### What I need from you (the ONLY inputs)
1. **The report name(s)** - the `*.Report` (PBIR) folder name(s).
2. **Which workspace folders are the DevOps branches**, and which is `dev`, `stage`,
   `prod`. The **`dev` branch is the source of truth** for the DEV ids and is left
   **unchanged**; `stage`/`prod` branches get rewritten.
3. **One confirmation** (Phase 2) that the discovered ids really are the **DEV** values.

Everything else (discovery, live-environment id resolution, the hardcode, verification)
I do myself.

### The two visual types and their environment-specific identifiers
| Visual | `visual.visualType` prefix | JSON literal(s) holding the env pointer |
|--------|----------------------------|-----------------------------------------|
| **Power Apps** | `PowerApps_PBI_CV_...` | `visual.objects.general[0].properties.appId` = `'/providers/Microsoft.PowerApps/apps/<appId>'` |
| **Power Automate (Flow)** | `FlowVisual_...` | `visual.objects.flowInfo[0].properties.FlowId` = `'/providers/Microsoft.ProcessSimple/environments/<envId>/flows/<flowId>'` **and** `...EnvironmentId` = `'<envId>'` |

Golden facts (verified):
- **PowerApps `appId` is environment-specific** -> it **changes** per environment and MUST
  be swapped.
- **Flow `<flowId>` is solution-aware -> SAME GUID in every environment.** Only `<envId>`
  changes. So in a Flow visual you swap the env id in **two** places (the FlowId path +
  the EnvironmentId property) and **leave the flow GUID alone**.
- **Leave untouched** (env-agnostic): `ManagementUri`, `EnvironmentLocation`
  (e.g. `unitedstates`), `EnvironmentRegion` (e.g. `westus`), `someSettings`.

### Phase 1 - Discover the visuals (read-only)
> **DevOps repo folders are usually gitignored**, so `grep_search` / `file_search` return
> nothing. Use a terminal scan with absolute `-LiteralPath`.

Enumerate `definition/pages/*/visuals/*/visual.json` for each branch's report and pull
`visualType` + the identifier literals:
```powershell
$base = "<abs path to ...\<Report>.Report>"
Get-ChildItem -LiteralPath $base -Recurse -Filter visual.json |
  Select-String -Pattern '/apps/[0-9a-f-]+','/environments/[0-9a-f-]+/flows/[0-9a-f-]+',"'[0-9a-f-]{36}'" -AllMatches |
  ForEach-Object { foreach($m in $_.Matches){ "{0} :: {1}" -f ($_.Path -replace [regex]::Escape($base),'...'), $m.Value } } | Sort-Object
```
Build a per-visual map: `page folder \ visual folder \ type \ friendly title \ current id(s)`.
Each Flow visual should show the env id **twice** (FlowId path + EnvironmentId).

### Phase 2 - Confirm DEV with the user (gate)
Present the distinct DEV ids found (the `appId`(s), `envId`, `flowId`(s)) and the visual
map. **Stop and get explicit confirmation** that these are the DEV environment values
before resolving or editing anything.

### Phase 3 - Resolve the target ids from the live Power Platform
For **each** target environment (`stage` if it exists, then `prod`):
1. **Environment ID** - select that env's `pac` auth profile and run `pac org who` (or use
   a known/confirmed env id).
2. **PowerApps App ID per app** - the Dataverse `canvasapps` table's **`canvasappid` IS
   the `appId` the visual uses**. `pac canvas list` does **not** expose the GUID. Match by
   app display/unique name. Mint a token if needed and query the Web API:
   ```powershell
   $tok = (az account get-access-token --resource https://<org>.crm.dynamics.com --query accessToken -o tsv)
   irm "https://<org>.crm.dynamics.com/api/data/v9.2/canvasapps?`$select=displayname,name,canvasappid" -Headers @{ Authorization = "Bearer $tok" }
   ```
3. **Flow** - GUID is unchanged; just **confirm it exists/active** in the target env via
   the `workflows` table (`workflowid eq <flowId>`, expect `statecode=1`/Activated,
   `category=5` cloud flow). If a flow is **missing** in the target env, **flag it** rather
   than guessing.
4. **Validation trick (high confidence):** sibling apps that already work in a target-env
   report will have live `canvasappid`s that **exactly match** the App IDs baked into those
   working reports - proving `canvasappid` == the visual's `appId`.
5. **Restore the original active `pac` auth profile** afterward (`pac auth select --index N`)
   - read-only queries shouldn't leave the profile switched. `pac` is often not on PATH;
   use the full `pac.exe` under the VS Code extension `globalStorage` if needed.

Record a clean mapping per environment, e.g. (placeholder ids):
```
DEV   appId <dev-appId>  | env <dev-envId>  | flow <flowId>
PROD  appId <prod-appId> | env <prod-envId> | flow <flowId>   (flow GUID identical)
```

### Phase 4 - Hardcode into the target branch(es)
For each target branch's report, edit every relevant `visual.json` with the **file-editing
tools** (`multi_replace_string_in_file`), **not** terminal sed:
- **PowerApps visuals:** `appId` DEV -> target.
- **Flow visuals:** `EnvironmentId` DEV -> target in **both** the FlowId path **and** the
  EnvironmentId property (flow GUID stays).
Apply `stage` ids into the stage branch and `prod` ids into the prod branch - **never cross
them**. The `dev` branch stays as-is. Files are pretty-printed JSON; target the
`appId` / `FlowId` / `EnvironmentId` literal blocks for unique matches within each file.

### Phase 5 - Verify (per target branch)
Re-scan and assert:
- **0** DEV ids remain (`appId` and `envId`).
- Target `appId` count == number of PowerApps visuals.
- Target `envId` count == **2 x** number of Flow visuals.
- Every `visual.json` still parses (`Get-Content -Raw | ConvertFrom-Json`).
```powershell
$files = Get-ChildItem -LiteralPath $base -Recurse -Filter visual.json
# tally DEV vs target appId/envId occurrences and ConvertFrom-Json each file; expect DEV=0
```

### Phase 6 - Hand off
Report the per-visual change table and the verification counts. Leave the edits **staged in
the working tree** - the user pushes each branch themselves. Touch **only** the report's
`visual.json` files (no semantic-model or other files).

### One-line recap
> Give me the **report name(s)** and which folders are the **dev / stage / prod** DevOps
> branches; confirm once that the discovered ids are DEV. I handle discovery, live-env id
> resolution, the per-branch hardcode, and verification end to end.

---

## Sources

- Microsoft Learn - [Power Apps visual for Power BI](https://learn.microsoft.com/en-us/power-apps/maker/canvas-apps/powerapps-custom-visual)
  (Using the visual, Limitations, Browser support).
- Microsoft Learn - [Add a Power Apps visual to a report (tutorial)](https://learn.microsoft.com/en-us/power-bi/visuals/power-bi-visualization-powerapp).
- First-hand workspace incident (stale `PowerBIIntegration.Data` schema, resolved by
  re-editing the app from the Power BI Service).
- First-hand workspace task (repointing a Power BI report's embedded Power Platform
  visuals across DevOps branches; basis of the Cross-environment repoint workflow).
'@ | Set-Content -Path $pbiPaSkillPath -Encoding UTF8
    Write-Host "  $(if ($updateMode) {'Updated'} else {'Created'}) .github/skills/pbi-powerapps-integration/SKILL.md"
} else {
    Write-Host "  Exists: .github/skills/pbi-powerapps-integration/SKILL.md" -ForegroundColor DarkGray
}

# -- .vscode/tasks.json (force terminal warm-up on folder open) --------
$tasksJsonPath = "$rootPath\.vscode\tasks.json"
if ($updateMode -or -not (Test-Path $tasksJsonPath)) {
    @'
{
    "version": "2.0.0",
    "tasks": [
        {
            "label": "Initialise Terminal",
            "type": "shell",
            "command": "echo Power Platform workspace ready",
            "runOptions": { "runOn": "folderOpen" },
            "presentation": {
                "reveal": "silent",
                "panel": "shared",
                "close": true
            },
            "problemMatcher": []
        }
    ]
}
'@ | Set-Content -Path $tasksJsonPath -Encoding UTF8
    Write-Host "  $(if ($updateMode) {'Updated'} else {'Created'}) .vscode/tasks.json (terminal warm-up on open)"
} else {
    Write-Host "  Exists: .vscode/tasks.json" -ForegroundColor DarkGray
}

# -- .vscode/settings.json (merge -- preserves user customisations) -----
$settingsJsonPath = "$rootPath\.vscode\settings.json"
$requiredSettings = @{
    "task.allowAutomaticTasks" = "on"
    "git.ignoreLimitWarning" = $true
    "search.exclude" = @{
        "power-platform-skills/" = $true
    }
}
$existed = Test-Path $settingsJsonPath
Merge-JsonSettings $settingsJsonPath $requiredSettings
Write-Host "  $(if ($existed) {'Merged'} else {'Created'}) .vscode/settings.json"

# -- .vscode/mcp.json (Canvas Authoring MCP server -- LIVE canvas editing) --
# Registers Microsoft's Canvas Authoring MCP server so the agent can drive
# Power Apps Studio in real time. Launched via 'dnx' (ships with the .NET 10
# SDK installed in Step 2). Merged so any user-added MCP servers are kept.
$mcpJsonPath = "$rootPath\.vscode\mcp.json"
$requiredMcp = @{
    "servers" = @{
        "canvas-authoring" = @{
            "command" = "dnx"
            "args" = @(
                "Microsoft.PowerApps.CanvasAuthoring.McpServer"
                "--yes"
                "--prerelease"
                "--source"
                "https://api.nuget.org/v3/index.json"
            )
        }
    }
}
$mcpExisted = Test-Path $mcpJsonPath
Merge-JsonSettings $mcpJsonPath $requiredMcp
Write-Host "  $(if ($mcpExisted) {'Merged'} else {'Created'}) .vscode/mcp.json (canvas-authoring MCP server)"

Write-Host "`nAll configuration files ready." -ForegroundColor Green
Read-Host "`nPress Enter to continue..."

# -- STEP 5 - Clone skills repository ---------------------------------
Show-Step 5 $totalSteps "Cloning Skills Repository"

# -- Git init, clone skills, initial commit ----------------------------
Push-Location $rootPath
try {
    if (-not (Test-Path "$rootPath\.git")) {
        try { & git init 2>&1 | Out-Null } catch { }
        Write-Host "  Initialised git repository"
    }

    # -- Clone or update power-platform-skills -------------------------
    if (-not (Test-Path "$rootPath\power-platform-skills")) {
        Write-Host "  Cloning microsoft/power-platform-skills from GitHub..."
        Write-Host "  (this may take a minute depending on your connection)" -ForegroundColor DarkGray
        try {
            & git clone https://github.com/microsoft/power-platform-skills.git power-platform-skills 2>&1 | Out-Null
        } catch { }
        if (Test-Path "$rootPath\power-platform-skills\plugins") {
            Write-Host "  Skills cloned successfully." -ForegroundColor Green
        } else {
            Write-Host "  Warning: could not clone skills repo. You can clone it manually later." -ForegroundColor Yellow
        }
    } elseif ($updateMode) {
        Write-Host "  Updating power-platform-skills to latest version..." -ForegroundColor White
        # Note: redirect stderr to $null separately - using 2>&1 | Out-Null trips
        # $ErrorActionPreference = 'Stop' because git writes progress to stderr.
        $updateSuccess = $false
        & git -C power-platform-skills fetch origin 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            # Auto-detect default branch instead of assuming 'main'
            $defaultBranch = & git -C power-platform-skills symbolic-ref refs/remotes/origin/HEAD 2>$null
            $defaultBranch = ($defaultBranch -replace 'refs/remotes/origin/', '').Trim()
            if ([string]::IsNullOrWhiteSpace($defaultBranch)) { $defaultBranch = 'main' }
            & git -C power-platform-skills reset --hard "origin/$defaultBranch" 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { $updateSuccess = $true }
        }
        if ($updateSuccess) {
            Write-Host "  Skills updated to latest." -ForegroundColor Green
        } else {
            Write-Host "  Warning: could not update skills repo. Using existing copy." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  power-platform-skills/ already exists - skipping clone." -ForegroundColor Green
    }

    Read-Host "`n  Press Enter to continue..."

    # -- STEP 6 - Initialise git repository ----------------------------
    Show-Step 6 $totalSteps "Initializing Git Repository"

    # -- Initial commit ------------------------------------------------
    $gitUser  = git config user.name  2>$null
    $gitEmail = git config user.email 2>$null
    if ([string]::IsNullOrWhiteSpace($gitUser) -or [string]::IsNullOrWhiteSpace($gitEmail)) {
        Write-Host "  Warning: git user.name/email not configured - skipping initial commit." -ForegroundColor Yellow
        Write-Host "  Run:  git config --global user.name 'Your Name'" -ForegroundColor Yellow
        Write-Host "  Run:  git config --global user.email 'you@example.com'" -ForegroundColor Yellow
    } else {
        try { & git add . 2>&1 | Out-Null } catch { }
        try { & git commit -m "chore: initial workspace setup" 2>&1 | Out-Null } catch { }
    }
} finally {
    Pop-Location
}

Write-Host "`nGit repository ready." -ForegroundColor Green

# -- STEP 7 - Launch VS Code ------------------------------------------
Show-Step 7 $totalSteps "Launching VS Code"

Write-Host "=============================================" -ForegroundColor Green
Write-Host "  Setup complete!" -ForegroundColor Green
Write-Host "  Workspace: $rootPath" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Write-Host "VS Code will now open your workspace." -ForegroundColor White
Write-Host "Once open, select Power Platform Master Agent from the" -ForegroundColor White
Write-Host "Copilot Chat dropdown and type anything to start." -ForegroundColor White
Write-Host ""
Read-Host "Press Enter to open VS Code and finish setup..."

& $vscodeCmd $rootPath
