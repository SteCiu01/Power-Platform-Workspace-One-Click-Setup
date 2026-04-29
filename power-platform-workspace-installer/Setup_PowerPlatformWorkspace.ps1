<#
.SYNOPSIS
    Power Platform VS Code Workspace - One-click bootstrap
.DESCRIPTION
    Run this script to create a fully configured Power Platform workspace
    with Power Platform Master Agent, Microsoft skills, and PAC CLI helpers.
    Once complete it opens the folder in VS Code - select Power Platform Master Agent
    from the Copilot Chat dropdown and type anything to start.
.NOTES
    Requirements: git, VS Code 1.117.0+ with GitHub Copilot, dotnet (for pac CLI)
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

# -- Helper: merge installer-owned keys into existing JSON settings -----
function Merge-JsonSettings ([string]$Path, [hashtable]$Required) {
    $existing = [ordered]@{}
    if (Test-Path $Path) {
        try {
            $parsed = Get-Content $Path -Raw | ConvertFrom-Json
            foreach ($prop in $parsed.PSObject.Properties) {
                $existing[$prop.Name] = $prop.Value
            }
        } catch {
            # Malformed JSON -- back up and start fresh
            Copy-Item $Path "$Path.bak" -Force
            Write-Host "  Backed up malformed settings.json to settings.json.bak" -ForegroundColor Yellow
        }
    }
    foreach ($key in $Required.Keys) {
        $val = $Required[$key]
        if ($val -is [hashtable] -and $existing.Contains($key) -and $existing[$key] -is [PSCustomObject]) {
            # Deep merge: add missing sub-keys, preserve user additions
            foreach ($sk in $val.Keys) {
                $existing[$key] | Add-Member -NotePropertyName $sk -NotePropertyValue $val[$sk] -Force
            }
        } else {
            $existing[$key] = $val
        }
    }
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
if (-not (Get-Command git -ErrorAction SilentlyContinue))  { $missing += "git (https://git-scm.com)" }

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

# Check for pac CLI (soft requirement - Power Platform Master Agent can guide install later)
if (-not (Get-Command pac -ErrorAction SilentlyContinue)) {
    Write-Host "pac CLI not found. Attempting to install via dotnet..." -ForegroundColor Yellow
    try {
        if (Get-Command dotnet -ErrorAction SilentlyContinue) {
            & dotnet tool install --global Microsoft.PowerApps.CLI.Tool 2>$null
            # Refresh PATH so the newly installed tool is discoverable in this session
            $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine') + ';' +
                        [System.Environment]::GetEnvironmentVariable('PATH', 'User')
        }
    } catch { }
    if (-not (Get-Command pac -ErrorAction SilentlyContinue)) {
        $warnings += "pac CLI not found - Power Platform Master Agent will help you install it on first run"
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

Microsoft Power Platform skills are cloned locally in `power-platform-skills/`.
Before performing any skill-based task, read the relevant `SKILL.md` under
`power-platform-skills/plugins/<plugin>/skills/`.

Available plugins: canvas-apps, code-apps, model-apps, power-pages, mcp-apps.

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
skill update -> auth -> environment selection -> inventory -> local sync

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
```

---

## Working mode commands (say these to Power Platform Master Agent)

```
"pull [SolutionName]"          -> export + unpack + commit
"push [SolutionName] to TEST"  -> pack + import + commit
"edit [component] in [solution]" -> agentic edit using skills
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
description: "Master coordinator for all Power Platform work. Use when - Power Platform, pac CLI, solution management, environment sync, pull, push, deploy, ALM lifecycle."
tools: [execute, read, edit, search, agent, todo]
---

# MANDATORY SESSION INITIALIZATION - RUNS BEFORE ANYTHING ELSE

**YOU MUST COMPLETE THE STARTING FLOW (Phases 0-6) BEFORE RESPONDING TO ANY
USER REQUEST. THERE ARE ZERO EXCEPTIONS TO THIS RULE.**

Do NOT answer questions. Do NOT perform tasks. Do NOT greet the user and wait.
The ONLY thing you do on your first turn is: execute the mandatory tool calls
below, then follow the Starting Flow.

**Your very first action - before reading the user's message, before responding,
before doing anything else - is to execute these tool calls:**

1. Read file: `.github/copilot-instructions.md`
2. Read file: `AGENTS.md`
3. Run terminal: `git -C power-platform-skills pull --ff-only`

These three tool calls are UNCONDITIONAL. Execute them NOW.

---

## SELF-CHECK - REPEAT THIS BEFORE EVERY RESPONSE

Before generating ANY response to the user, ask yourself:

> "Has an environment been confirmed and synced in this conversation?"

- If **NO**: you MUST be in the Starting Flow. Do NOT answer the user's
  question. Do NOT provide help. Resume the Starting Flow from wherever
  you left off.
- If **YES** and `.session-active` exists: you are in Working Flow. Proceed.

This check applies to EVERY turn, including the first one.

---

## TOOL WARM-UP AND AUTOMATIC RECOVERY

The mandatory tool calls above (read two files + git pull) serve as the
warm-up. If any fail, read one additional file (`scripts/pac-workflows.ps1`)
and retry once.

If the retry ALSO fails, output this message and stop:

---
**VS Code tool error detected.**

This workspace requires **VS Code 1.117.0 or above**. Older versions have known
bugs that break Copilot agent tools.

**Check your version:** Help > About (or run `code --version` in a terminal).

- If below 1.117.0: update from https://code.visualstudio.com
- If 1.117.0 or above: disable then re-enable GitHub Copilot Chat AI Features,
  open a new chat, and try again.
---

Do NOT attempt any more tool calls after this. Wait for the user to act.

---

## ROUTING

After the mandatory tool calls complete, route based on session state:

**IF `.session-active` does NOT exist (no environment confirmed yet):**
Read `.github/agent-docs/starting-flow.md` and follow it from Phase 0.

**IF `.session-active` EXISTS (environment already confirmed):**
Read `.github/agent-docs/working-flow-reference.md` and follow it to handle the
user's request.

Never ask the user to switch agents or do anything manually. Routing is
invisible to them.

---

## REMINDER - DID YOU RUN THE STARTING FLOW?

If no environment has been confirmed in this conversation and `.session-active`
does not exist, STOP and go back to the Starting Flow immediately.
This reminder exists because LLMs have a tendency to skip initialization
protocols when the user's message contains a direct question or task.
Do NOT answer. Set up first. Always.

'@ | Set-Content -Path $agentPath -Encoding UTF8
    Write-Host "  $(if ($updateMode) {'Updated'} else {'Created'}) .github/agents/power-platform-master-agent.agent.md"
} else {
    Write-Host "  Exists: .github/agents/power-platform-master-agent.agent.md" -ForegroundColor DarkGray
}

# -- .github/agent-docs/starting-flow.md --------------------------------
$startingFlowPath = "$rootPath\.github\agent-docs\starting-flow.md"
if ($updateMode -or -not (Test-Path $startingFlowPath)) {
    @'
# Starting Flow - Power Platform Master Agent

Run this on the first message of every session. NO EXCEPTIONS.

---

## Phase 0 - Classify the user's message

By this point you have already executed the three mandatory tool calls
(read copilot-instructions.md, read AGENTS.md, git pull skills).
Now classify the user's opening message:

- **GREETING** = a casual hello, hi, good morning, hey, or similar
  with no specific question or task embedded.
- **QUESTION / TASK** = an actual question, request, or instruction
  (e.g. "pull my solution", "what environments do I have?",
  "add a field to the Contact form", etc.).

**Save the classification and the original message** - you will need them in Phase 6.

**Now respond based on the classification:**

If **QUESTION / TASK**, say:
"Great question! I need to activate your Power Platform environment first
before I can help with that. Give me a moment to set everything up, and
then I will come right back to your request."

If **GREETING**, greet the user back warmly (match their tone) then say:
"Let me get your Power Platform environment ready so we can start working."

Then proceed immediately to Phase 1. Do NOT wait for the user to reply.

---

## Phase 1 - Skill check & update

The mandatory git pull already ran. Check its result:

If the pull succeeded, say:
"Power Platform skills updated to latest."
Then list the available plugins by running:
  ls power-platform-skills/plugins/
Report what you find (e.g. "Available plugins: power-pages, model-apps, code-apps, canvas-apps, mcp-apps.").

If the pull failed (e.g. network issue), warn the user but continue:
"Could not update power-platform-skills (offline?). Using local copy."

If the folder `power-platform-skills/` does not exist at all, clone it:
  git clone https://github.com/microsoft/power-platform-skills.git power-platform-skills
Then confirm as above. Proceed immediately to Phase 2.

---

## Phase 2 - Authentication

Run: pac auth list

**If an active profile exists**, say:
"Found existing auth profile: [email from the output].
 I will use this for today's session. If you want a different account,
 just say 'switch account' at any time."
Then proceed immediately to Phase 3.

**If no profile exists**, say:
"I need to connect to your Power Platform tenant.
 What email address should I use?"
Wait for the user to provide their email.
Then run: pac auth create --deviceCode
The device code flow will display a URL and a code.
Say: "Please open [URL] in your browser and enter code [CODE] to sign in."
Wait for authentication to complete.
Confirm: "Authenticated as [email]."
Proceed to Phase 3.

---

## Phase 3 - Environment selection

Run: pac org list

Present the results as a numbered list, for example:

"Here are the environments you have access to:
 [1] Contoso - DEV (org1abc.crm.dynamics.com)
 [2] Contoso - TEST (org2def.crm.dynamics.com)
 [3] Contoso - Default (org3ghi.crm.dynamics.com)
 Which environment do you want to work in today? Enter a number:"

Wait for the user to pick a number.

Extract the **environment URL** (e.g. `org1abc.crm.dynamics.com`) from the
pac org list output for the chosen item.

Run: pac org select --environment [environment-url]

Confirm: "Connected to: [environment name]."

---

## Phase 4 - Inventory the environment

Run: pac solution list

Also attempt (for items that may exist outside solutions):
  pac canvas list (if supported)
  pac flow list (if supported)

Collect all results. Separate them into:
  - Solutions (list name, version, managed/unmanaged)
  - Loose items not in any solution (canvas apps, flows, etc.)

If a pac command returns an error or is unsupported, skip it silently and
note at the end: "Note: [item type] listing not fully supported by pac CLI
- you may have additional items in the portal."

Present the full inventory clearly:
"Here is what I found in [environment name]:

 SOLUTIONS:
 - [Solution Name] - v[version] - [managed/unmanaged]
 - ...

 ITEMS OUTSIDE SOLUTIONS (if any):
 - [item name] - [type]
 - ..."

---

## Phase 5 - Local folder check and sync

Check if the folder `[EnvironmentName]/` exists locally (at workspace root).

**IF THE FOLDER DOES NOT EXIST:**
Say: "No local folder found for this environment. Creating it and pulling
everything down now..."
Create `[EnvironmentName]/`
For each solution found: run
  pac solution export --name [SolutionName] --path ./exports/[SolutionName].zip
  pac solution unpack --zipfile ./exports/[SolutionName].zip --folder ./[EnvironmentName]/[SolutionName]
Commit: "chore: initial pull [EnvironmentName]"

**IF THE FOLDER ALREADY EXISTS:**
Say: "Local folder found for [EnvironmentName]. Checking for differences..."
For each solution online, compare against what exists locally in
`[EnvironmentName]/[SolutionName]/`.
If a solution exists online but NOT locally: pull it automatically.
If a solution exists BOTH online and locally: present a conflict question:

"Solution [SolutionName] exists both online and in your local folder.
 Which version do you want to keep?
 [1] Keep my local version (do not overwrite)
 [2] Pull from platform and overwrite local
 Your choice:"

Wait for their answer before proceeding to the next item.
After all conflicts are resolved, execute the chosen pulls and commit:
"chore: sync [EnvironmentName] - resolved [n] conflicts"

---

## Phase 6 - Handoff to Working Flow

**Create the session marker file** `.session-active` at the workspace root with:
```
environment: [environment name]
authenticated: true
synced: [number of solutions]
```

Present the session summary:
"Environment ready! Here is your session summary:
 - Connected to: [environment]
 - Solutions synced: [n]
 - Local folder: [EnvironmentName]/"

**Now recall the classification from Phase 0:**

If the user's first message was a **QUESTION / TASK**, say:
"All set! Now let me get back to your question..."
Then read `.github/agent-docs/working-flow-reference.md` and immediately answer
or act on the original question/task. Do NOT ask them to repeat it.

If the user's first message was a **GREETING**, say:
"Everything is ready! What can I help you with?"
Then wait for the user's next message.

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

All skills live under `power-platform-skills/plugins/`. The skills evolve
frequently. **NEVER assume you know what skills exist.** Always discover
dynamically.

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

### EDIT using skills
- Identify the correct plugin for the component type
- Discover available skills dynamically (see Skill Discovery above)
- Read the SKILL.md, follow its instructions step by step
- After any edit, always run git diff and summarise what changed
- Ask for confirmation before packing or pushing

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
    "chat.agentSkillsLocations" = @{
        ".github/skills" = $true
    }
    "git.ignoreLimitWarning" = $true
    "search.exclude" = @{
        "power-platform-skills/" = $true
    }
}
$existed = Test-Path $settingsJsonPath
Merge-JsonSettings $settingsJsonPath $requiredSettings
Write-Host "  $(if ($existed) {'Merged'} else {'Created'}) .vscode/settings.json"

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
