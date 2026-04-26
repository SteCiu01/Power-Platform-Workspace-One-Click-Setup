<#
.SYNOPSIS
    Power Platform VS Code Workspace - One-click bootstrap
.DESCRIPTION
    Run this script to create a fully configured Power Platform workspace
    with Power Platform Master Agent, Microsoft skills, and PAC CLI helpers.
    Once complete it opens the folder in VS Code - select Power Platform Master Agent
    from the Copilot Chat dropdown and type anything to start.
.NOTES
    Requirements: git, dotnet (for pac CLI), VS Code with GitHub Copilot
#>

# Keep the window open on any error so the user can read it
$ErrorActionPreference = 'Stop'
trap {
    Write-Host "`nERROR: $_" -ForegroundColor Red
    Read-Host "`nPress Enter to close"
    exit 1
}

# -- Prompt for folder name --------------------------------------------
$defaultName = "Power Platform"
$folderName = Read-Host "Enter a name for your workspace folder (default: $defaultName)"
if ([string]::IsNullOrWhiteSpace($folderName)) { $folderName = $defaultName }

$rootPath = Join-Path $env:USERPROFILE $folderName

if (Test-Path $rootPath) {
    Write-Host "`nFolder already exists: $rootPath" -ForegroundColor Yellow
    $overwrite = Read-Host "Continue and fill in missing files? (y/n)"
    if ($overwrite -ne 'y') { Write-Host "Aborted."; exit 0 }
}

Write-Host "`n=== Creating workspace at: $rootPath ===" -ForegroundColor Cyan

# -- Prerequisites check ----------------------------------------------
$missing = @()
$warnings = @()
if (-not (Get-Command git -ErrorAction SilentlyContinue))  { $missing += "git (https://git-scm.com)" }
if (-not (Get-Command code -ErrorAction SilentlyContinue)) { $missing += "VS Code (https://code.visualstudio.com)" }

# Check for pac CLI (soft requirement - Power Platform Master Agent can guide install later)
if (-not (Get-Command pac -ErrorAction SilentlyContinue)) {
    Write-Host "pac CLI not found. Attempting to install via dotnet..." -ForegroundColor Yellow
    try {
        if (Get-Command dotnet -ErrorAction SilentlyContinue) {
            & dotnet tool install --global Microsoft.PowerApps.CLI.Tool 2>$null
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

# -- Create folder structure -------------------------------------------
$dirs = @(
    $rootPath
    "$rootPath\exports"
    "$rootPath\deploy"
    "$rootPath\scripts"
    "$rootPath\.github\agents"
)
foreach ($d in $dirs) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# -- .gitignore --------------------------------------------------------
$gitignorePath = "$rootPath\.gitignore"
if (-not (Test-Path $gitignorePath)) {
    @"
*.zip
exports/
node_modules/
.env
*.log
*.user
power-platform-skills/
"@ | Set-Content -Path $gitignorePath -Encoding UTF8
    Write-Host "  Created .gitignore"
}

# -- scripts/pac-workflows.ps1 ----------------------------------------
$pacWorkflowsPath = "$rootPath\scripts\pac-workflows.ps1"
if (-not (Test-Path $pacWorkflowsPath)) {
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
    Write-Host "  Created scripts/pac-workflows.ps1"
}

# -- .github/copilot-instructions.md -----------------------------------
$copilotInstructionsPath = "$rootPath\.github\copilot-instructions.md"
if (-not (Test-Path $copilotInstructionsPath)) {
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
    Write-Host "  Created .github/copilot-instructions.md"
}

# -- AGENTS.md ---------------------------------------------------------
$agentsReadmePath = "$rootPath\AGENTS.md"
if (-not (Test-Path $agentsReadmePath)) {
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
- On session start: runs skill update -> auth -> environment selection ->
  inventory -> local sync -> hands off to working mode
- In working mode: full ALM lifecycle using power-platform-skills plugins

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
    Write-Host "  Created AGENTS.md"
}

# -- .github/agents/power-platform-master-agent.agent.md --------------------
$agentPath = "$rootPath\.github\agents\power-platform-master-agent.agent.md"
if (-not (Test-Path $agentPath)) {
    @'
---
name: "Power Platform Master Agent"
description: "Master coordinator for all Power Platform work. Use when - Power Platform, pac CLI, solution management, environment sync, pull, push, deploy, ALM lifecycle."
tools: [execute, read, edit, search, agent, todo]
---

You are Power Platform Master Agent, the single entry point for all Power Platform work.
The user selects you from the Copilot Chat agent dropdown and sends any
message to begin.

## HOW TO ROUTE

On every new session (defined as: no environment has been confirmed yet in
this conversation), immediately delegate to the STARTING FLOW below.

Once an environment has been confirmed and the local folder is prepared,
switch to the WORKING FLOW below for all subsequent requests in this session.

Never ask the user to switch agents or do anything manually to change mode.
Routing is invisible to them.

---

## STARTING FLOW
(Run this on the first message of every session)

### Phase 1 - Skill check & update
Say exactly:
"Starting your Power Platform session...
 Updating power-platform-skills from GitHub."

The workspace contains a local clone of microsoft/power-platform-skills in
`power-platform-skills/`. Pull the latest version on every session start:

Run:
  git -C power-platform-skills pull --ff-only

This uses -C so the terminal never changes directory. If the pull succeeds, confirm:
"Power Platform skills updated to latest.
 Available plugins: power-pages, model-apps, code-apps, canvas-apps, mcp-apps."

If the pull fails (e.g. network issue), warn the user but continue:
"Could not update power-platform-skills (offline?). Using local copy."

If the folder `power-platform-skills/` does not exist at all, clone it:
  git clone https://github.com/microsoft/power-platform-skills.git power-platform-skills

Then confirm as above.

### Phase 2 - Authentication
Run: pac auth list
If an active profile exists, say:
  "Found existing auth profile: [profile name / email]. 
   Do you want to use this or connect with a different account?"
Wait for the user's answer.
If they want a different account, or no profile exists, say:
  "Please enter your Power Platform / Microsoft 365 email address:"
Wait for input. Then run:
  pac auth create --username [their email] --deviceCode
Guide them through the device code login if it appears.
Confirm: "Authenticated as [email]."

### Phase 3 - Environment selection
Run: pac org list
Present the results as a numbered questionnaire, for example:

  "Here are the environments you have access to:
   [1] Contoso - DEV (dev.crm.dynamics.com)
   [2] Contoso - TEST (test.crm.dynamics.com)  
   [3] Contoso - Default (org.crm.dynamics.com)
   Which environment do you want to work in today? Enter a number:"

Wait for the user to pick a number.
Run: pac auth select --index [chosen index]
Confirm: "Connected to: [environment name]."

### Phase 4 - Inventory the environment
Run: pac solution list
Also run (for items that may exist outside solutions):
  pac flow list (if supported)
  pac canvas list (if supported)
Collect all results. Separate them into:
  - Solutions (list name, version, managed/unmanaged)
  - Loose items not in any solution (flows, apps, etc. - list what is found)
If a pac command returns an error or is unsupported, skip it silently and
note at the end: "Note: [item type] listing not fully supported by pac CLI
- you may have additional items in the portal."

Present the full inventory clearly:
  "Here is what I found in [environment name]:

   SOLUTIONS:
   ? [Solution Name] - v[version] - [managed/unmanaged]
   ? ...

   ITEMS OUTSIDE SOLUTIONS (if any):
   ? [Flow name] - [type]
   ? ..."

### Phase 5 - Local folder check and sync

Check if the folder `[EnvironmentName]/` exists locally (at workspace root).

IF THE FOLDER DOES NOT EXIST:
Say: "No local folder found for this environment. Creating it and pulling
everything down now..."
Create `[EnvironmentName]/`
For each solution found: run
  pac solution export --name [SolutionName] --path ./exports/[SolutionName].zip
  pac solution unpack --zipfile ./exports/[SolutionName].zip --folder ./[EnvironmentName]/[SolutionName]
Commit: "chore: initial pull [EnvironmentName]"

IF THE FOLDER ALREADY EXISTS:
Say: "Local folder found for [EnvironmentName]. Checking for differences..."
For each solution online, compare against what exists locally in
`[EnvironmentName]/[SolutionName]/`.
If a solution exists online but NOT locally: pull it automatically, no question needed.
If a solution exists BOTH online and locally: present a conflict question:

  "Solution [SolutionName] exists both online and in your local folder.
   Which version do you want to keep?
   [1] Keep my local version (do not overwrite)
   [2] Pull from platform and overwrite local
   Your choice:"

Wait for their answer before proceeding to the next item.
After all conflicts are resolved, execute the chosen pulls and commit:
"chore: sync [EnvironmentName] - resolved [n] conflicts"

### Phase 6 - Handoff to Working Flow
Say:
"Environment ready. Here is your session summary:
 ? Connected to: [environment]
 ? Solutions synced: [n]
 ? Local folder: [EnvironmentName]/
 
 Power Platform Working Agent is active. What would you like to work on?"

From this point, enter the WORKING FLOW for all user requests.

---

## WORKING FLOW
(Active after Phase 6 completes)

You are now Power Platform Working Agent. Help the user work on their Power Platform
solutions using the local power-platform-skills and pac CLI.

### Local skill files (read these before executing a skill)

All skills live under `power-platform-skills/plugins/`. Before performing
any skill-based task, read the relevant SKILL.md file to follow its
instructions precisely.

| Plugin | AGENTS.md (read first) | Skills folder |
|--------|----------------------|---------------|
| model-apps | `power-platform-skills/plugins/model-apps/AGENTS.md` | `power-platform-skills/plugins/model-apps/skills/` |
| code-apps | `power-platform-skills/plugins/code-apps/AGENTS.md` | `power-platform-skills/plugins/code-apps/skills/` |
| canvas-apps | `power-platform-skills/plugins/canvas-apps/AGENTS.md` | `power-platform-skills/plugins/canvas-apps/skills/` |
| power-pages | `power-platform-skills/plugins/power-pages/AGENTS.md` | `power-platform-skills/plugins/power-pages/skills/` |
| mcp-apps | `power-platform-skills/plugins/mcp-apps/AGENTS.md` | `power-platform-skills/plugins/mcp-apps/skills/` |

**Workflow for any skill-based task:**
1. Read the plugin's `AGENTS.md` to understand available skills and routing
2. Read the specific `SKILL.md` for the skill you are about to execute
3. Read any `references/` docs mentioned in the SKILL.md
4. Follow the SKILL.md instructions step by step

### Capabilities available to the user:

PULL a specific solution:
- Export and unpack a named solution into [env]/[solution]/
- Commit with message "chore: pull [solution] from [env]"

PUSH a specific solution:
- Pack [env]/[solution]/ into deploy/[solution].zip
- Confirm the target environment before importing
- Require explicit "yes" confirmation for Production environments
- Import and commit: "feat: push [solution] to [env]"

EDIT using skills:
- Use model-apps skills for Model Driven App components:
  forms, views, sitemap, security roles, business rules
  -> Read `power-platform-skills/plugins/model-apps/skills/genpage/SKILL.md`
- Use canvas-apps skills for Canvas App source files:
  screens, controls, connections, app.json structure
  -> Read `power-platform-skills/plugins/canvas-apps/skills/*/SKILL.md`
- Use code-apps skills for:
  PCF controls, plugins, web resources, TypeScript, C# components
  -> Read `power-platform-skills/plugins/code-apps/skills/*/SKILL.md`
- Use power-pages skills for:
  site templates, content snippets, web roles, page layouts
  -> Read `power-platform-skills/plugins/power-pages/skills/*/SKILL.md`
- After any edit, always run git diff and summarise what changed
- Ask for confirmation before packing or pushing

COMPARE environments:
- Pull the same solution from two different environments
- Run git diff between the two unpacked folders
- Summarise what is different between environments

NEW solution:
- Run pac solution init --publisher-name [name] --publisher-prefix [prefix]
- Scaffold initial structure using appropriate skills plugin
- Commit: "chore: init solution [name]"

STATUS check at any time:
- Run pac auth list, pac solution list, git status, git log --oneline -10
- Present a clean summary

### Working rules:
- Never import to Production without the user typing "confirm push to prod"
- Always check pac auth list before export or import
- Always unpack after export - never commit raw .zip files
- Unmanaged for dev work, managed for production deployments
- If any pac command fails, diagnose the error, suggest a fix, ask before retrying
- Keep git history clean: one commit per logical action
'@ | Set-Content -Path $agentPath -Encoding UTF8
    Write-Host "  Created .github/agents/power-platform-master-agent.agent.md"
}

# -- Git init, clone skills, initial commit ----------------------------
Push-Location $rootPath
try {
    if (-not (Test-Path "$rootPath\.git")) {
        try { & git init 2>&1 | Out-Null } catch { }
        Write-Host "  Initialised git repository"
    }

    # -- Clone power-platform-skills ----------------------------------
    if (-not (Test-Path "$rootPath\power-platform-skills")) {
        Write-Host "  Cloning microsoft/power-platform-skills (this may take a moment)..."
        try {
            & git clone https://github.com/microsoft/power-platform-skills.git power-platform-skills 2>&1 | Out-Null
        } catch { }
        if (Test-Path "$rootPath\power-platform-skills\plugins") {
            Write-Host "  Skills cloned successfully." -ForegroundColor Green
        } else {
            Write-Host "  Warning: could not clone skills repo. You can clone it manually later." -ForegroundColor Yellow
        }
    }

    # -- Initial commit ------------------------------------------------
    $gitUser  = git config user.name  2>$null
    $gitEmail = git config user.email 2>$null
    if ([string]::IsNullOrWhiteSpace($gitUser) -or [string]::IsNullOrWhiteSpace($gitEmail)) {
        Write-Host "  Warning: git user.name/email not configured — skipping initial commit." -ForegroundColor Yellow
        Write-Host "  Run:  git config --global user.name 'Your Name'" -ForegroundColor Yellow
        Write-Host "  Run:  git config --global user.email 'you@example.com'" -ForegroundColor Yellow
    } else {
        try { & git add . 2>&1 | Out-Null } catch { }
        try { & git commit -m "chore: initial workspace setup" 2>&1 | Out-Null } catch { }
    }
} finally {
    Pop-Location
}

# -- Done - open in VS Code -------------------------------------------
Write-Host ""
Write-Host "=============================================" -ForegroundColor Green
Write-Host "  Workspace ready: $rootPath" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Write-Host "Opening in VS Code..."
Write-Host "Once open: select Power Platform Master Agent from the Copilot Chat dropdown and type anything."
Write-Host ""

code $rootPath

# Only prompt to close when running in a standalone window (the .bat),
# not inside VS Code's integrated terminal where it would block the session.
if (-not $env:TERM_PROGRAM) {
    Read-Host "Press Enter to close this window"
}
