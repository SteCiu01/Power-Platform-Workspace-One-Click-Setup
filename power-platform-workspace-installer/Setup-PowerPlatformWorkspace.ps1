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
    Live canvas authoring: .NET 10 SDK - provides 'dnx', which runs the Canvas
    Authoring MCP server used for real-time coauthoring. Auto-installed by default.
    Live flow authoring: Node.js 18+ and Azure CLI (az login) - run the Power
    Automate FlowAgent MCP server bundled in the skills repo. Auto-installed by
    default (via winget). All live-authoring runtimes are non-blocking - if any
    cannot be installed, offline authoring via pac CLI still works.
.PARAMETER EmitAgentsTo
    CI / non-interactive mode. Generates the agent definition files (and the
    managed config files) into the given folder, skips all prerequisite checks
    and prompts, and exits 0 on success or 1 on failure. Used by the Pester
    test suite to validate generation without touching a real workspace.
.PARAMETER VerifyRoot
    Integrity mode. Re-hashes every managed file under the given workspace root
    and compares against .github/installed-manifest.json. Exits 0 if unchanged,
    1 on drift, 2 if no manifest is present. Non-interactive.
#>

param(
    [string]$EmitAgentsTo,
    [string]$VerifyRoot
)

# Product version - single source of truth (mirrors the manifest productVersion).
$productVersion = '0.5.1'

# Keep the window open on any error so the user can read it (interactive mode
# only - emit / verify modes must stay non-interactive for CI).
$ErrorActionPreference = 'Stop'
if (-not $EmitAgentsTo -and -not $VerifyRoot) {
    trap {
        Write-Host "`nERROR: $_" -ForegroundColor Red
        Read-Host "`nPress Enter to close"
        exit 1
    }
}

# -- Helper: SHA-256 hex, resilient across PowerShell hosts -------------
# Get-FileHash ships in Microsoft.PowerShell.Utility. When a Windows PowerShell
# 5.1 child is launched from PowerShell 7 (as the CI Pester runner does in
# Generated.Tests.ps1), the inherited PSModulePath can leave Get-FileHash
# unresolved, which - under $ErrorActionPreference='Stop' - aborts emit/verify
# mode with a non-zero exit. Fall back to the .NET SHA-256 implementation so
# hashing never depends on module autoloading. Returns lower-case hex.
function Get-Sha256Hex ([string]$LiteralPath) {
    if (Get-Command Get-FileHash -ErrorAction SilentlyContinue) {
        return (Get-FileHash -LiteralPath $LiteralPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.IO.File]::ReadAllBytes($LiteralPath)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

# =====================================================================
# -VerifyRoot : integrity check against .github/installed-manifest.json
# =====================================================================
# -- Helper: read JSON the way VS Code does (UTF-8, BOM, // and /* */ comments, trailing commas)
# Returns $null when the text still does not parse. Comments are stripped outside strings only.
function Read-JsonLenient ([string]$LiteralPath) {
    $text = [System.IO.File]::ReadAllText($LiteralPath, [System.Text.Encoding]::UTF8)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    try { return ($text | ConvertFrom-Json) } catch { }
    $sb = New-Object System.Text.StringBuilder; $inStr = $false; $i = 0; $n = $text.Length
    while ($i -lt $n) {
        $c = $text[$i]
        if ($inStr) {
            [void]$sb.Append($c)
            if ($c -eq '\' -and $i + 1 -lt $n) { [void]$sb.Append($text[$i + 1]); $i += 2; continue }
            if ($c -eq '"') { $inStr = $false }
            $i++; continue
        }
        if ($c -eq '"') { $inStr = $true; [void]$sb.Append($c); $i++; continue }
        if ($c -eq '/' -and $i + 1 -lt $n -and $text[$i + 1] -eq '/') { while ($i -lt $n -and $text[$i] -ne "`n") { $i++ }; continue }
        if ($c -eq '/' -and $i + 1 -lt $n -and $text[$i + 1] -eq '*') { $end = $text.IndexOf('*/', $i + 2); $i = if ($end -lt 0) { $n } else { $end + 2 }; continue }
        [void]$sb.Append($c); $i++
    }
    $clean = [regex]::Replace($sb.ToString(), ',(\s*[}\]])', '$1')
    try { return ($clean | ConvertFrom-Json) } catch { return $null }
}

if ($VerifyRoot) {
    $verifyFull = [System.IO.Path]::GetFullPath($VerifyRoot)
    $manifestFile = Join-Path $verifyFull '.github\installed-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestFile)) {
        Write-Host "No installed-manifest.json found at: $manifestFile" -ForegroundColor Yellow
        exit 2
    }
    $manifestData = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
    $drift = @()
    # Authored files (core agents, docs, scripts) and discovered worker wrappers are hashed.
    $hashed = @($manifestData.files) + @($manifestData.discovered)
    $nHashed = @($hashed | Where-Object { $_ }).Count
    if ($nHashed -eq 0) { $drift += "EMPTY MANIFEST: no hashed files listed - the install did not complete or the manifest was tampered with" }
    foreach ($entry in $hashed) {
        if (-not $entry) { continue }
        $target = Join-Path $verifyFull $entry.path
        if (-not (Test-Path -LiteralPath $target)) {
            $drift += "MISSING: $($entry.path)"
            continue
        }
        $actual = Get-Sha256Hex -LiteralPath $target
        if ($actual -ne $entry.sha256.ToLowerInvariant()) {
            $drift += "CHANGED: $($entry.path)"
        }
    }
    # Merge files (settings / mcp / .code-workspace) legitimately hold user keys, so they
    # are key-checked, not hashed: every installer-required key must still be present with
    # a usable value (not null), and keys listed in requiredTrue must be exactly true.
    foreach ($entry in @($manifestData.merged)) {
        if (-not $entry) { continue }
        $target = Join-Path $verifyFull $entry.path
        if (-not (Test-Path -LiteralPath $target)) { $drift += "MISSING: $($entry.path)"; continue }
        $doc = Read-JsonLenient -LiteralPath $target
        if ($null -eq $doc) { $drift += "UNPARSEABLE: $($entry.path)"; continue }
        $mustBeTrue = @($entry.requiredTrue)
        foreach ($keyPath in @(@($entry.requiredKeys) + $mustBeTrue | Select-Object -Unique)) {
            if (-not $keyPath) { continue }
            $node = $doc; $found = $true
            foreach ($seg in ($keyPath -split '::')) {
                if ($null -ne $node -and $node.PSObject.Properties[$seg]) { $node = $node.$seg } else { $found = $false; break }
            }
            if (-not $found -or $null -eq $node) { $drift += "KEY MISSING: $($entry.path) -> $keyPath"; continue }
            if (($mustBeTrue -contains $keyPath) -and ($node -ne $true)) { $drift += "KEY DISABLED: $($entry.path) -> $keyPath (must be true)" }
        }
    }
    if ($drift.Count -gt 0) {
        Write-Host "Integrity check FAILED - $($drift.Count) item(s) drifted:" -ForegroundColor Red
        $drift | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        exit 1
    }
    $nMerged = @($manifestData.merged | Where-Object { $_ }).Count
    Write-Host "Integrity check PASSED - $nHashed hashed file(s) match and $nMerged merge file(s) carry every required key with the required value." -ForegroundColor Green
    exit 0
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
        if ($val -is [System.Collections.IDictionary] -and $curIsObj) {
            # Both sides are objects -- recurse so nested user keys survive ([ordered] is not a [hashtable]).
            $req = @{}; foreach ($k in $val.Keys) { $req[$k] = $val[$k] }
            $merged[$key] = Merge-SettingValue $cur $req
        } else {
            $merged[$key] = $val
        }
    }
    return $merged
}

# -- Helper: merge installer-owned keys into existing JSON settings -----
# Reads like VS Code (UTF-8, comments, trailing commas). A file that still does not
# parse is NEVER replaced: it is left exactly as it is, reported, and recorded in
# $script:unmergedConfigs so the summary and -VerifyRoot surface it. Returns $true
# when the file was written.
$script:unmergedConfigs = @()
function Merge-JsonSettings ([string]$Path, [hashtable]$Required) {
    $parsed = $null
    $leaf = Split-Path $Path -Leaf
    if (Test-Path $Path) {
        $parsed = Read-JsonLenient -LiteralPath $Path
        if ($null -eq $parsed) {
            $script:unmergedConfigs += $Path
            Write-Host "  $leaf could not be parsed as JSON - left untouched. Fix it and re-run the installer; required keys were NOT added." -ForegroundColor Yellow
            return $false
        }
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
        try { $null = ($raw.TrimStart([char]0xFEFF) | ConvertFrom-Json); $hadComments = $false } catch { $hadComments = $true }
        if ($hadComments) {
            Copy-Item -LiteralPath $Path -Destination "$Path.bak" -Force
            Write-Host "  $leaf had comments / trailing commas; keys preserved, comments dropped (original kept as $leaf.bak)." -ForegroundColor DarkGray
        }
    }
    $existing = Merge-SettingValue $parsed $Required
    $json = $existing | ConvertTo-Json -Depth 10
    Write-ManagedFile $Path $json
    return $true
}

# -- Helper: write a managed file as UTF-8 WITHOUT a BOM ----------------
# PowerShell 5.1 'Set-Content -Encoding UTF8' prepends a BOM, which breaks
# VS Code YAML front-matter detection in .agent.md files. Always use this for
# generated agent/config files so the front-matter fence is the first byte.
function Write-ManagedFile ([string]$Path, [string]$Content) {
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

# -- Helper: skill container folders for chat.agentSkillsLocations -------
# Returns workspace-relative (forward-slash) folders that directly contain skill
# subfolders (<container>/<skill>/SKILL.md). Registering them natively means every
# agent sees the full skill catalogue (name + description) without `ls`/grep.
function Get-SkillContainerDirs {
    param([string]$RootPath, [string[]]$SearchSubPaths)
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($sub in $SearchSubPaths) {
        $base = Join-Path $RootPath $sub
        if (-not (Test-Path -LiteralPath $base)) { continue }
        Get-ChildItem -LiteralPath $base -Recurse -Filter 'SKILL.md' -File -ErrorAction SilentlyContinue | ForEach-Object {
            $container = $_.Directory.Parent
            if ($null -eq $container) { return }
            $rel = $container.FullName.Substring($RootPath.TrimEnd('\').Length).TrimStart('\').Replace('\', '/')
            if ($rel -and -not $found.Contains($rel)) { $found.Add($rel) }
        }
    }
    return @($found | Sort-Object)
}

# -- Microsoft vendor clones (read-only upstream, force-refreshed on update) --
# Two layouts exist upstream:
#   plugins - <clone>/plugins/<plugin>/{agents,skills,references}   (power-platform-skills)
#   single  - the clone IS one plugin: <clone>/{agents,skills,reference} (copilot-studio-plugin)
# Everything downstream (skill registration, worker discovery, knowledge refs, the
# status script) is driven from this table, so adding a vendor is one row here plus
# a Lead whose primarySkills names the plugin id.
$vendorClones = @(
    [pscustomobject]@{ Name = 'power-platform-skills'; Url = 'https://github.com/microsoft/power-platform-skills.git'; Layout = 'plugins'; Label = 'Microsoft power-platform-skills' },
    [pscustomobject]@{ Name = 'copilot-studio-plugin'; Url = 'https://github.com/microsoft/copilot-studio-plugin.git'; Layout = 'single';  Label = 'Microsoft copilot-studio-plugin' }
)
# Workspace-relative folders (backslash) under which SKILL.md containers are searched.
$vendorSkillSearchPaths = @($vendorClones | ForEach-Object { if ($_.Layout -eq 'plugins') { "$($_.Name)\plugins" } else { "$($_.Name)\skills" } })

# plugin id -> workspace-relative plugin root (forward slashes). Only plugins present on disk.
function Get-PluginRoots ([string]$RootPath) {
    $roots = [ordered]@{}
    foreach ($v in $vendorClones) {
        $cloneFull = Join-Path $RootPath $v.Name
        if (-not (Test-Path -LiteralPath $cloneFull)) { continue }
        if ($v.Layout -eq 'plugins') {
            $pf = Join-Path $cloneFull 'plugins'
            if (Test-Path -LiteralPath $pf) {
                foreach ($d in @(Get-ChildItem -LiteralPath $pf -Directory -ErrorAction SilentlyContinue)) { $roots[$d.Name] = "$($v.Name)/plugins/$($d.Name)" }
            }
        } else {
            $roots[$v.Name] = $v.Name
        }
    }
    return $roots
}
# Resolves a plugin id even when the clone is absent (emit mode / offline) so knowledge
# refs and messages still name the expected path.
function Resolve-PluginRoot ([string]$PluginId, $Roots) {
    if ($Roots -and $Roots.Contains($PluginId)) { return [string]$Roots[$PluginId] }
    $single = $vendorClones | Where-Object { $_.Layout -eq 'single' -and $_.Name -eq $PluginId } | Select-Object -First 1
    if ($single) { return $single.Name }
    $multi = $vendorClones | Where-Object { $_.Layout -eq 'plugins' } | Select-Object -First 1
    return "$($multi.Name)/plugins/$PluginId"
}
# -- Helper: force a vendor clone to exactly mirror upstream ------------
# The installer is authoritative for vendor repos: they must always match the
# published upstream. We fetch + prune, stash any local edits (recoverable via
# 'git stash list'), then hard-reset to origin/HEAD. This is the deliberate
# opposite of a fast-forward: a local edit to a vendor file is NOT preserved in
# place - it is stashed and the clone is reset, so vendor code is never a
# divergence risk. Returns $true on success. git writes progress to stderr even
# on success: under the script-wide EAP=Stop a `2>&1` would turn that into a
# terminating error and the reset would never run, so stderr is discarded with
# `2>$null` and every git step's $LASTEXITCODE is captured IMMEDIATELY (a later
# successful command would otherwise overwrite it). A failed stash aborts BEFORE
# any reset so local edits are never discarded; success means HEAD literally
# equals the upstream commit, not merely "no error was seen".
function Update-VendorClone ([string]$RepoPath, [string]$Label) {
    $ok = $false
    if (-not (Test-Path -LiteralPath $RepoPath)) { return $ok }
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git -C $RepoPath fetch --prune origin 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "    ${Label}: fetch failed (offline or blocked) - keeping the current clone." -ForegroundColor Yellow
            return $ok
        }
        # Full ref names (refs/remotes/...) resolve straight to the commit; they avoid the
        # '^{commit}' peel syntax, whose caret is an escape character for cmd-based git shims.
        $target = (& git -C $RepoPath rev-parse --verify --quiet 'refs/remotes/origin/HEAD' 2>$null)
        $targetExit = $LASTEXITCODE
        # origin/HEAD is a LOCAL symbolic ref set at clone time; if upstream renamed its default
        # branch it goes stale. Prefer the branch origin advertises now (ls-remote --symref).
        $advertisedLines = @(& git -C $RepoPath ls-remote --symref origin HEAD 2>$null)
        $advExit = $LASTEXITCODE
        $advertised = if ($advertisedLines.Count -gt 0) { [string]$advertisedLines[0] } else { '' }
        if ($advExit -eq 0 -and $advertised -match 'ref:\s*refs/heads/(\S+)\s+HEAD') {
            $advBranch = $Matches[1]
            $adv = (& git -C $RepoPath rev-parse --verify --quiet "refs/remotes/origin/$advBranch" 2>$null)
            if ($LASTEXITCODE -eq 0 -and $adv) {
                if ($adv -ne $target) { & git -C $RepoPath remote set-head origin $advBranch 2>$null | Out-Null }
                $target = $adv; $targetExit = 0
            }
        }
        if ($targetExit -ne 0 -or -not $target) {
            # Older clones may lack origin/HEAD; fall back to the current branch's upstream - but only on origin.
            $up = (& git -C $RepoPath rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>$null)
            if ($LASTEXITCODE -eq 0 -and $up -like 'origin/*') {
                $target = (& git -C $RepoPath rev-parse --verify --quiet "refs/remotes/$up" 2>$null)
                $targetExit = $LASTEXITCODE
            }
        }
        if ($targetExit -ne 0 -or -not $target) {
            Write-Host "    ${Label}: cannot resolve the upstream commit (no origin/HEAD or origin tracking branch) - clone left as-is." -ForegroundColor Yellow
            return $ok
        }
        $dirty = @(& git -C $RepoPath status --porcelain 2>$null)
        if ($LASTEXITCODE -ne 0) {
            Write-Host "    ${Label}: 'git status' failed - working-tree state unknown, refresh skipped so nothing is lost." -ForegroundColor Yellow
            return $ok
        }
        $stashed = $false
        if ($dirty.Count -gt 0) {
            $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
            & git -C $RepoPath stash push -u -m "installer-autostash $stamp" 2>$null | Out-Null
            $stashExit = $LASTEXITCODE
            $stillDirty = @(& git -C $RepoPath status --porcelain 2>$null)
            $statusExit = $LASTEXITCODE
            if ($stashExit -ne 0 -or $statusExit -ne 0 -or $stillDirty.Count -gt 0) {
                Write-Host "    ${Label}: could not stash local changes (git identity missing?) - refresh skipped so nothing is lost. Commit or discard them, then re-run." -ForegroundColor Yellow
                return $ok
            }
            $stashed = $true
            Write-Host "    $Label had local changes - stashed as 'installer-autostash $stamp' (recover with 'git -C <repo> stash list')." -ForegroundColor DarkGray
        }
        $before = (& git -C $RepoPath rev-parse HEAD 2>$null)
        & git -C $RepoPath reset --hard $target 2>$null | Out-Null
        $resetExit = $LASTEXITCODE
        $after = (& git -C $RepoPath rev-parse HEAD 2>$null)
        if ($resetExit -eq 0 -and $after -eq $target) {
            $ok = $true
            $shortBefore = if ($before) { $before.Substring(0, 7) } else { '?' }
            $shortAfter = $after.Substring(0, 7)
            if ($before -ne $after) { Write-Host "    $Label refreshed: $shortBefore -> $shortAfter" -ForegroundColor Green }
            else { Write-Host "    $Label already at upstream ($shortAfter)." -ForegroundColor DarkGray }
        } else {
            $where = if ($after) { $after.Substring(0,7) } else { '?' }
            $recover = if ($stashed) { " Your local edits are safe in the stash ('git -C <repo> stash pop' to restore them)." } else { '' }
            Write-Host "    ${Label}: reset to upstream failed (exit $resetExit) - clone left at $where; inspect with 'git -C <repo> status'.$recover" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "    ${Label}: refresh error - $($_.Exception.Message)" -ForegroundColor Yellow
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    return $ok
}

# =====================================================================
# EMBEDDED AGENT MANIFEST - single source of truth for the hierarchy.
# CI extracts this JSON (regex on the here-string) and validates it against
# schema/agent-manifest.schema.json. The generator below reads it to write one
# .agent.md per agent. MCP grants are additive (mcpServers -> '<server>/*').
# =====================================================================
$agentManifestJson = @'
{
  "schemaVersion": 1,
  "productVersion": "0.5.1",
  "defaults": {
    "mode": "both",
    "tools": ["read", "search"],
    "writePermissions": "workspace",
    "defaultRisk": "medium",
    "sourceControlPermissions": "commit",
    "environmentRestrictions": "no-prod-write-without-confirmation"
  },
  "agents": [
    {
      "id": "power-platform-master",
      "displayName": "Power Platform Master",
      "filename": "000-power-platform-master.agent.md",
      "level": "executive",
      "department": "orchestration",
      "parent": null,
      "allowedChildren": [
        "Solution Architect", "Integration QA & Change Controller", "Workspace Maintainer",
        "Canvas Apps Lead", "Power Automate Lead", "Power Pages Lead", "Code Apps Lead",
        "Model Apps Lead", "Mobile Apps Lead", "MCP Apps Lead", "Solution ALM & Environments Lead",
        "Copilot Studio Lead"
      ],
      "visibility": "visible",
      "userInvocable": true,
      "tools": ["agent", "read", "search", "execute"],
      "defaultRisk": "medium",
      "focus": "Single entry point for the workspace. Runs the setup/working flow, understands the request, and delegates to the Solution Architect (for design) or directly to the topic Team Leads (for execution). Coordinates, never implements."
    },
    {
      "id": "solution-architect",
      "displayName": "Solution Architect",
      "filename": "001-solution-architect.agent.md",
      "level": "executive",
      "department": "architecture",
      "parent": "power-platform-master",
      "allowedChildren": [
        "Canvas Apps Lead", "Power Automate Lead", "Power Pages Lead", "Code Apps Lead",
        "Model Apps Lead", "Mobile Apps Lead", "MCP Apps Lead", "Solution ALM & Environments Lead",
        "Copilot Studio Lead"
      ],
      "visibility": "visible",
      "userInvocable": true,
      "tools": ["agent", "read", "search"],
      "mcpServers": ["microsoft-learn"],
      "defaultRisk": "low",
      "focus": "Advisory design authority for tough or cross-cutting work: chooses the right component types, plans the solution/ALM shape, and sequences delegation across the Team Leads. Read-only; produces a plan, never edits."
    },
    {
      "id": "integration-qa-change-controller",
      "displayName": "Integration QA & Change Controller",
      "filename": "002-integration-qa-change-controller.agent.md",
      "level": "executive",
      "department": "quality",
      "parent": "power-platform-master",
      "allowedChildren": [],
      "visibility": "visible",
      "userInvocable": true,
      "tools": ["read", "search", "execute"],
      "defaultRisk": "medium",
      "focus": "Reviews changes before they leave the workspace: validates solution packs, runs git diffs, gates Production imports, and enforces the 'confirm push to prod' rule. Read + verify only; never authors component source."
    },
    {
      "id": "workspace-maintainer",
      "displayName": "Workspace Maintainer",
      "filename": "003-workspace-maintainer.agent.md",
      "level": "executive",
      "department": "capability-maintenance",
      "parent": "power-platform-master",
      "allowedChildren": [],
      "visibility": "visible",
      "userInvocable": true,
      "tools": ["read", "search", "execute", "edit"],
      "defaultRisk": "medium",
      "focus": "Keeps the workspace itself healthy: refreshes the two cloned Microsoft vendor repos (power-platform-skills, copilot-studio-plugin), maintains .vscode config / MCP registrations / the custom embedded skills, and repairs setup drift. Edits workspace scaffolding, not user solution source."
    },
    {
      "id": "canvas-apps-lead",
      "displayName": "Canvas Apps Lead",
      "filename": "010-canvas-apps-lead.agent.md",
      "level": "team-lead",
      "department": "canvas-apps",
      "parent": "power-platform-master",
      "allowedChildren": ["Solution Architect", "Integration QA & Change Controller"],
      "visibility": "visible",
      "userInvocable": true,
      "tools": ["agent", "read", "search", "execute", "edit"],
      "mcpServers": ["canvas-authoring", "microsoft-learn"],
      "primarySkills": ["canvas-apps", "pbi-powerapps-integration"],
      "artifactTypes": ["canvas app (.pa.yaml)", "Power Apps visual for Power BI"],
      "defaultRisk": "medium",
      "focus": "Owns canvas apps: offline authoring via .pa.yaml and LIVE coauthoring through the canvas-authoring MCP server, plus Power BI-embedded (PowerBIIntegration) apps and cross-environment repoint work."
    },
    {
      "id": "power-automate-lead",
      "displayName": "Power Automate Lead",
      "filename": "020-power-automate-lead.agent.md",
      "level": "team-lead",
      "department": "power-automate",
      "parent": "power-platform-master",
      "allowedChildren": ["Solution Architect", "Integration QA & Change Controller"],
      "visibility": "visible",
      "userInvocable": true,
      "tools": ["agent", "read", "search", "execute", "edit"],
      "mcpServers": ["flow-agent", "microsoft-learn"],
      "primarySkills": ["power-automate"],
      "artifactTypes": ["cloud flow", "desktop flow"],
      "defaultRisk": "medium",
      "focus": "Owns Power Automate cloud and desktop flows: browse, create, build, debug, diagnose, and route flows across environments, using the FlowAgent MCP server where available."
    },
    {
      "id": "power-pages-lead",
      "displayName": "Power Pages Lead",
      "filename": "030-power-pages-lead.agent.md",
      "level": "team-lead",
      "department": "power-pages",
      "parent": "power-platform-master",
      "allowedChildren": ["Solution Architect", "Integration QA & Change Controller"],
      "visibility": "visible",
      "userInvocable": true,
      "tools": ["agent", "read", "search", "execute", "edit"],
      "mcpServers": ["microsoft-learn"],
      "primarySkills": ["power-pages"],
      "artifactTypes": ["Power Pages site", "code site (React/Angular/Vue/Astro)"],
      "defaultRisk": "medium",
      "focus": "Owns Power Pages sites, including code sites built with React, Angular, Vue or Astro."
    },
    {
      "id": "code-apps-lead",
      "displayName": "Code Apps Lead",
      "filename": "040-code-apps-lead.agent.md",
      "level": "team-lead",
      "department": "code-apps",
      "parent": "power-platform-master",
      "allowedChildren": ["Solution Architect", "Integration QA & Change Controller"],
      "visibility": "visible",
      "userInvocable": true,
      "tools": ["agent", "read", "search", "execute", "edit"],
      "mcpServers": ["microsoft-learn"],
      "primarySkills": ["code-apps"],
      "artifactTypes": ["Power Apps code app (React + Vite + TypeScript)"],
      "defaultRisk": "medium",
      "focus": "Owns Power Apps code apps: React + Vite + TypeScript projects and their Power Platform SDK wiring."
    },
    {
      "id": "model-apps-lead",
      "displayName": "Model Apps Lead",
      "filename": "050-model-apps-lead.agent.md",
      "level": "team-lead",
      "department": "model-apps",
      "parent": "power-platform-master",
      "allowedChildren": ["Solution Architect", "Integration QA & Change Controller"],
      "visibility": "visible",
      "userInvocable": true,
      "tools": ["agent", "read", "search", "execute", "edit"],
      "mcpServers": ["microsoft-learn"],
      "primarySkills": ["model-apps"],
      "artifactTypes": ["model-driven app", "generative page", "form", "view", "sitemap"],
      "defaultRisk": "medium",
      "focus": "Owns model-driven apps: generative pages, forms, views and sitemaps."
    },
    {
      "id": "mobile-apps-lead",
      "displayName": "Mobile Apps Lead",
      "filename": "060-mobile-apps-lead.agent.md",
      "level": "team-lead",
      "department": "mobile-apps",
      "parent": "power-platform-master",
      "allowedChildren": ["Solution Architect", "Integration QA & Change Controller"],
      "visibility": "visible",
      "userInvocable": true,
      "tools": ["agent", "read", "search", "execute", "edit"],
      "mcpServers": ["microsoft-learn"],
      "primarySkills": ["mobile-apps", "power-apps-mobile-extension"],
      "artifactTypes": ["mobile app (Expo / React Native)", "native extension (.ppmplugin)"],
      "defaultRisk": "medium",
      "focus": "Owns mobile apps built with Expo / React Native on the Power Platform, including Mobile Offline Profiles and third-party native extensions (.ppmplugin) for Power Apps Wrap."
    },
    {
      "id": "mcp-apps-lead",
      "displayName": "MCP Apps Lead",
      "filename": "070-mcp-apps-lead.agent.md",
      "level": "team-lead",
      "department": "mcp-apps",
      "parent": "power-platform-master",
      "allowedChildren": ["Solution Architect", "Integration QA & Change Controller"],
      "visibility": "visible",
      "userInvocable": true,
      "tools": ["agent", "read", "search", "execute", "edit"],
      "mcpServers": ["microsoft-learn"],
      "primarySkills": ["mcp-apps"],
      "artifactTypes": ["MCP-based app"],
      "defaultRisk": "medium",
      "focus": "Owns MCP-based app generation on the Power Platform."
    },
    {
      "id": "solution-alm-environments-lead",
      "displayName": "Solution ALM & Environments Lead",
      "filename": "080-solution-alm-environments-lead.agent.md",
      "level": "team-lead",
      "department": "alm-environments",
      "parent": "power-platform-master",
      "allowedChildren": ["Solution Architect", "Integration QA & Change Controller"],
      "visibility": "visible",
      "userInvocable": true,
      "tools": ["agent", "read", "search", "execute", "edit"],
      "mcpServers": ["microsoft-learn"],
      "primarySkills": [],
      "artifactTypes": ["solution (managed/unmanaged)", "environment", "publisher"],
      "defaultRisk": "high",
      "focus": "Owns solution lifecycle and environments via pac CLI: init/export/unpack/pack/import, publisher setup, environment selection and cross-environment promotion, with Production imports gated on explicit confirmation."
    },
    {
      "id": "copilot-studio-lead",
      "displayName": "Copilot Studio Lead",
      "filename": "090-copilot-studio-lead.agent.md",
      "level": "team-lead",
      "department": "copilot-studio",
      "parent": "power-platform-master",
      "allowedChildren": ["Solution Architect", "Integration QA & Change Controller"],
      "visibility": "visible",
      "userInvocable": true,
      "tools": ["agent", "read", "search", "execute", "edit"],
      "mcpServers": ["microsoft-learn"],
      "primarySkills": ["copilot-studio-plugin"],
      "artifactTypes": ["Copilot Studio agent (MCS2 YAML project, pac copilot)"],
      "defaultRisk": "medium",
      "focus": "Owns Copilot Studio agents authored as MCS2 YAML projects with pac copilot (init/clone/pull/push/publish, knowledge, skills, tools), using Microsoft's copilot-studio-plugin skills and its bundled workers; publish and delete are gated."
    }
  ]
}
'@

$agentManifest = $agentManifestJson | ConvertFrom-Json

# -- Generator helper: render a YAML inline list ['a', 'b'] -------------
function ConvertTo-AgentYamlList ([string[]]$Items) {
    if (-not $Items -or $Items.Count -eq 0) { return '[]' }
    $quoted = $Items | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }
    return '[' + ($quoted -join ', ') + ']'
}

# -- Generator helper: compose the markdown body for one agent ----------
# Tier-aware bodies. Every agent shares an Operating contract; the Master
# coordinates and is the only voice to the user, executives advise/govern
# (PLAN / VERDICT), Team Leads own a department and dispatch Microsoft's
# workers with WORK ORDERs. Each agent then gets its specialist knowledge
# (New-KnowledgeSection) and ends with a WORK RESULT return contract. Text is
# static single-quoted here-strings with %%TOKEN%% placeholders so backticks,
# `${PLUGIN_ROOT}` and `$` stay literal. Delegation targets are passed by their
# exact dropdown label ("NNN - Display Name") so calls always resolve.
function Get-AgentBody ($Agent, [string]$Label, [string[]]$ChildLabels) {
    $sb = New-Object System.Text.StringBuilder
    $isMaster    = ($Agent.id -eq 'power-platform-master')
    $isLead      = ($Agent.level -eq 'team-lead')
    $canDelegate = (@($Agent.tools) -contains 'agent')
    $childBlock  = if ($ChildLabels.Count -gt 0) { ($ChildLabels | ForEach-Object { "- **$_**" }) -join "`n" } else { '- (none)' }

    [void]$sb.AppendLine("# $($Agent.displayName)")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine([string]$Agent.focus)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('## Operating contract')
    [void]$sb.AppendLine('')

    $flowBullet = if ($isMaster) {
        '- Follow `.github/copilot-instructions.md`, then `.github/agent-docs/starting-flow.md` (once per session) and `.github/agent-docs/working-flow-reference.md`.'
    } elseif ($Agent.level -eq 'executive') {
        '- Follow `.github/copilot-instructions.md` and `.github/agent-docs/working-flow-reference.md`. Do NOT run the session startup flow: it belongs to the Master. You are normally dispatched by the Master and then cannot ask the user; return open questions and approvals in your WORK RESULT. If the user selected you directly, you may ask them.'
    } else {
        '- Follow `.github/copilot-instructions.md` and `.github/agent-docs/working-flow-reference.md`. Do NOT run the session startup flow: it belongs to the Master. When selected directly by the user you are the entry point for your department and may ask the user questions; when dispatched by the Master you cannot ask the user, so return open questions and approvals in your WORK RESULT.'
    }
    $bullets = New-Object System.Collections.Generic.List[string]
    $bullets.Add($flowBullet)
    $bullets.Add('- Inspect the current files, git branch, `pac auth list` and the selected environment before you change anything.')
    $bullets.Add('- Skills are registered natively (custom `.github/skills`, Microsoft `power-platform-skills/plugins/<plugin>/skills` and `copilot-studio-plugin/skills`): use the list in your Knowledge section and read the relevant SKILL.md (and its `references/` / `reference/`) before authoring. Custom skills win on style; upstream skills win on syntax/spec. Only if a skill is missing from your list, re-discover it by keyword under `power-platform-skills/plugins/*/skills/` or `copilot-studio-plugin/skills/`.')
    $bullets.Add('- Microsoft''s plugins target another agent runtime: their `Task` tool is your `agent` tool, `${PLUGIN_ROOT}` is the plugin folder (`power-platform-skills/plugins/<plugin>` or `copilot-studio-plugin`), a `<plugin>:<skill>` reference such as `mcs-assistant:publish-agent` means that plugin''s `skills/<skill>/SKILL.md`, and `AskUserQuestion` does not exist for a dispatched agent (return `NEEDS INPUT` instead). Skip the plugin `AGENTS.md` / `CLAUDE.md` files; follow the `SKILL.md` and references.')
    $bullets.Add('- Use `.github/agent-docs/tool-status.json` to see which CLIs and MCP runtimes are available. When an entry has a `path`, invoke that exact executable so an older same-named copy cannot take precedence. If a needed tool is missing, do ONE optional live re-check, then fall back to the offline pac CLI path rather than failing; route install or config repair to the Workspace Maintainer.')
    $bullets.Add('- Work only in your assigned artifact paths. The cloned `power-platform-skills/` and `copilot-studio-plugin/` repos are read-only reference - never edit vendor files.')
    $bullets.Add('- Validate every change and return concise evidence, risks, and remaining actions. Never claim a check you did not run.')
    $bullets.Add('- Never expose secrets. Treat **Production as read-only** unless the user has typed `confirm push to prod` in this conversation.')
    $bullets.Add('- Destructive, irreversible or shared-environment actions need explicit user approval captured as a literal token (`APPROVED:<ACTION>:<artifact>`; Production import uses `confirm push to prod`). Deleting or dropping any app, screen, control, flow, table, column, form, view, page, file or branch, overwriting local source with an export, or importing into TEST/UAT/PROD is destructive even when the user asked for it in plain words: the request itself is not the approval. Only the top-level agent (the one the user selected) can ask the user - it confirms once, then puts the token in `approvals granted`. Every dispatched agent without the token must return `NEEDS APPROVAL` with the exact action and let it bubble up.')
    if ($canDelegate) {
        $bullets.Add('- **Dispatch health.** If the `agent` tool is missing or a dispatch is refused, check the three usual causes before anything else: (1) the window was opened without `chat.subagents.allowInvocationsFromSubagents: true` (the installer writes it to `.vscode/settings.json` and to the `<folder>.code-workspace`; in a multi-root window only the `.code-workspace` / user settings count); (2) the target name is not in your front-matter `agents:` list (only listed names can be dispatched); (3) the target `.agent.md` failed to parse (BOM, broken front matter). Report the exact cause; do not improvise the work yourself. Genuine transport errors (`ERR_HTTP2_SERVER_REFUSED_STREAM`, an empty completion) may be retried 2-3 times with a short pause ONLY for read-only calls and for dispatches whose WORK ORDER contains no write. A dispatch that could have written (edits, import, `compile_canvas`, flow publish) is NOT retry-safe: the child may have finished before the response was lost. Reconcile first (`git status` / `git diff` on the artifact, `pac solution list`, a fresh `sync_canvas`, the run history) and re-dispatch only for what is verifiably missing, stating in the new WORK ORDER what already exists.')
    }
    foreach ($b in $bullets) { [void]$sb.AppendLine($b) }

    if ($isMaster) {
        [void]$sb.AppendLine((@'

## Mandatory startup and routing

On the first message of a session, read `.github/copilot-instructions.md`, then follow `.github/agent-docs/starting-flow.md`: one status-script call, one compact status block, sign-in / environment only if missing, then straight to the user's request. Track session state in THIS conversation (the chat history is the source of truth - no marker file). If the opening message already contains work, keep it and act on it right after the status block. Never block the user behind menus. For all subsequent messages use `.github/agent-docs/working-flow-reference.md`. If a mandatory read fails, retry once; if tools still fail, show the **VS Code tool error** message below and stop instead of pretending startup completed.

## Your role: coordinator, not implementer

You are the account manager for this workspace. The user is your client and the eight Team Leads are your departments. Every request is a *project* you deliver **through the specialist teams**, never by doing the specialist work yourself. Treat "you fix it", "just do it" or "handle it" as "make the right team fix it and own the outcome" - the client is authorising the *result*, not asking you personally to touch the artifact.

You do **not** author, edit, pack, import, publish or live-edit any Power Platform artifact yourself - canvas `.pa.yaml`, flow definitions, Power Pages, code / model-driven / mobile app source, solution XML, environments or publishers. The owning **Team Lead** (and, through it, Microsoft's bundled **worker** for that artifact) performs the change; the Lead validates it. This holds even when you already know the fix: knowing the answer is not a reason to bypass the team. Hands-on you only: orchestrate, read/search just enough to classify and route, run the startup status script and the Phase 2 sign-in / environment commands, and consolidate evidence.

For every request: (1) classify the intent, the artifact(s) and the team(s); (2) route to the minimum relevant Team Lead(s) with the `agent` tool and a WORK ORDER (goal, artifact, mode, constraints, validation expected, approvals granted, context); (3) let each Lead do or delegate the work and validate it before returning; (4) consolidate the returned evidence, risks and remaining actions into one clear answer.

Use the **Solution Architect** only for genuine cross-type design, sequencing, ownership or rollback decisions. Route diff / pack review and **every Production import** through the **Integration QA & Change Controller**. Hand skills, MCP or config problems to the **Workspace Maintainer**. Keep exactly one writer per artifact.

## You are the only voice to the client

Dispatched agents (Leads, workers, Architect, QA) cannot ask the user anything. Whatever they need comes back to you as `NEEDS APPROVAL` or `NEEDS INPUT` in their WORK RESULT. You ask the client, then re-dispatch the SAME Team Lead with the answer in the work order (for approvals, include the literal token the worker asked for). Never grant an approval on the client's behalf. This is also how Microsoft's mid-build plan approvals work: the Lead returns `NEEDS APPROVAL` with the plan, you show it and ask, then re-dispatch with the token - you never tell the user to switch agents.

**Confirm destructive requests up front.** If the request itself deletes, drops, overwrites, resets, force-pushes, imports into a shared environment or changes security, do not dispatch yet: state in one or two lines exactly what will be destroyed or changed (including likely collateral, e.g. a formula that references a deleted control) and ask the client to reply with the literal token `APPROVED:<ACTION>:<artifact>` (Production import: `confirm push to prod`). Only then dispatch, with that token in `approvals granted`. "Do it now" or "you are authorised" in plain words is not a token. When you are running as a subagent yourself and cannot ask, return `NEEDS APPROVAL` with the proposed token instead of proceeding.

## The three loops you run

1. **Simple (one team, one artifact):** Master -> Team Lead -> (Microsoft worker) -> Lead validates -> Master consolidates -> client. No Architect, no QA.
2. **Designed (cross-type or design change):** Master -> Architect (PLAN) -> Master -> Team Lead(s) in the PLAN's order (parallel where the PLAN allows) -> each Lead -> (worker) -> Lead validates -> Master -> QA (VERDICT) -> Master consolidates -> client. If QA rejects, re-dispatch only the owning Lead with the defects.
3. **Blocked (approval / input / design question mid-work):** worker -> Lead relays `request` -> Master asks the client (or dispatches the Architect for a design question) -> Master re-dispatches the SAME Lead with the answer in `approvals granted` / `context` -> Lead -> worker resumes.

Rules: pass results down as `context` so nobody re-discovers facts; never dispatch two Leads to write the same artifact; when the PLAN says steps are dependent, wait for the WORK RESULT before dispatching the next.

## Session ledger

Keep a short running ledger in your own responses (not a file): request -> teams dispatched -> artifacts changed -> validation evidence -> approvals granted (tokens) -> open items. Reuse it: a follow-up request on the same artifact goes to the same Lead with the ledger facts as `context`, and an approval the client already gave is not asked twice in the same session.

## Your team (delegate by exact label)

%%CHILDREN%%

## Guardrails

- Canvas authoring is browser-based; there is NO Power Apps desktop app.
- Never import to Production without an explicit `confirm push to prod`.
- Use pac CLI for the offline flow; MCP servers only where a Lead grants them.
- Never pull "all solutions" - SYNC is gated (see the working-flow reference).

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
'@).Replace('%%CHILDREN%%', $childBlock))
    }
    elseif ($Agent.id -eq 'solution-architect') {
        [void]$sb.AppendLine((@'

## Your role: advise and plan, never edit

You are read-only. When the Master (or a Team Lead, mid-work) brings a tough or cross-cutting request, you produce a **PLAN**: which component types are involved, which skills apply, the solution / ALM shape, the order in which the Team Leads execute, and how each step is validated and rolled back. You do not author or edit source.

## Your output: a PLAN

```
PLAN
summary: <one paragraph: what changes and why this sequence>
steps:
  1. team: <Team Lead label> | artifact: <path under <Env>/<Solution>/ or live item> | change: <what> | skill: <SKILL.md to follow> | validate: <how> | rollback: <how>
  2. ...
parallel: <step numbers that may run concurrently>
risks: <broken formulas / connection references / solution dependencies / managed-vs-unmanaged / environment exposure>
decisions for the user: <only genuine choices, with a recommendation each>
```

Return the PLAN to whoever dispatched you (Master or a Team Lead). Flag any Production touch so it is gated on `confirm push to prod`.

## Two ways you are used

- **Before work (Master -> you):** produce the PLAN. The Master runs it.
- **Mid-work (a Team Lead -> you):** answer the single design / dependency question asked, in the same PLAN step format for the affected step(s) only, and return. Do not re-plan the whole request, and never dispatch a Team Lead from this mode (the Lead that asked is already running; dispatching it back would loop).
- **Run mode (explicit only):** when the Master's WORK ORDER says `run the plan`, you dispatch the Team Leads yourself in PLAN order, relay their WORK RESULTs and any `request` upward unchanged, and return one consolidated WORK RESULT. You still never write artifacts.

## Team Leads you can sequence

%%CHILDREN%%
'@).Replace('%%CHILDREN%%', $childBlock))
    }
    elseif ($Agent.id -eq 'integration-qa-change-controller') {
        [void]$sb.AppendLine(@'

## Your role: verify and gate, never author

You review changes before they leave the workspace. You are read + verify only - you do not write component source and you do not fix defects (send them back to the owning Team Lead).

## What you check

- `git status` / `git diff` - what actually changed, and that no raw `.zip` packs were committed (solutions must be unpacked).
- Solution packs are valid (`pac solution pack` succeeds) and target the intended environment.
- Cross-references: formulas that reference renamed / deleted controls, connection references, environment variables, solution dependencies, managed vs unmanaged.
- Auth + environment context is correct (`pac auth list`, `pac org who`).
- Security and privacy: no secrets, no hardcoded environment identifiers outside an explicit repoint task.
- **Production imports are gated**: never accept an import to Production unless the user has typed `confirm push to prod` in this session.

## Your output: a VERDICT

```
VERDICT: ACCEPT | ACCEPT WITH RISKS | REJECT
checked: <artifact -> checks run -> evidence>
defects: <artifact | defect | severity | owning Team Lead> (or none)
environment/auth: <pac auth list / pac org who aligned | mismatch details>
security/privacy: <ok | findings>
remaining approvals: <confirm push to prod still required | none>
```
'@)
    }
    elseif ($Agent.id -eq 'workspace-maintainer') {
        [void]$sb.AppendLine(@'

## Your role: keep the workspace healthy - the installer is authoritative

You maintain the workspace scaffolding itself - not the user's solution source. You act exactly like the installer's maintenance team: everything the installer ships is **authoritative and refreshed on every update**. You never invent a gentler policy - you enforce and explain the installer's contract.

**The contract in one line:** the installer OWNS every file it ships (agents, skills, configs, vendor clone). Those are force-refreshed each update. To extend the workspace the user adds **NEW** files in `.github/` - the installer never touches files it did not create.

## What you own

- **Force-refresh BOTH cloned vendor repos to upstream** (same rule as the installer, nothing lost) - `power-platform-skills` (`https://github.com/microsoft/power-platform-skills.git`) and `copilot-studio-plugin` (`https://github.com/microsoft/copilot-studio-plugin.git`). For each: `git -C <repo> fetch --prune origin`; if `git -C <repo> status --porcelain` shows local edits, `git -C <repo> stash push -u -m "maintenance-autostash <timestamp>"` first and tell the user how to recover; then `git -C <repo> reset --hard origin/HEAD`. Print the before/after commit. If a repo is missing, re-clone it. Never push to them and never edit their files. After a refresh the status script will report that the clone moved past the commit the agents were generated from - tell the user to re-run the installer so worker wrappers and skill lists are regenerated (discovery runs at install time, not at maintenance time).
- After a refresh, re-register skill containers in `.vscode/settings.json` -> `chat.agentSkillsLocations` if new `plugins/<plugin>/skills` or `copilot-studio-plugin/skills` folders appeared (`.github/agent-docs/Get-SessionStatus.ps1` also does this), and remind the user to reload the window.
- Keep `chat.subagents.allowInvocationsFromSubagents: true` in `.vscode/settings.json` - without it Team Leads cannot dispatch their Microsoft workers.
- Maintain `.vscode/mcp.json` (canvas-authoring + flow-agent + microsoft-learn registrations), `.vscode/settings.json` / `tasks.json`, and the embedded skills under `.github/skills/`.
- Refresh `.github/agent-docs/tool-status.json` and repair setup drift (malformed config, missing files). Re-running the installer is always the safe repair; suggest it when scaffolding is broken. The hidden `*-sub-*.agent.md` worker wrappers are regenerated by the installer from Microsoft's `plugins/<plugin>/agents/*.md` and `copilot-studio-plugin/agents/*.md` - do not hand-edit them.

When selected directly, first offer: **1. Light maintenance** - refresh both vendor clones (stash-then-mirror), re-register skill folders, refresh the tool inventory. **2. Deep maintenance** - light plus `-VerifyRoot` drift report, MCP registration check, and a worker-wrapper freshness check (re-run the installer if Microsoft added or removed workers in either clone).

## Managed files are overwritten - guide edits into NEW files

`.github/installed-manifest.json` is the authoritative write-log. It has three sections: `files` and `discovered` are authored files and worker wrappers with their SHA256 at write time (overwritten on every update); `merged` lists the three config files (`.vscode/settings.json`, `.vscode/mcp.json`, `<folder>.code-workspace`) that the installer only MERGES - user keys in them survive, the installer-required keys are re-asserted and checked by value. It also records `vendorCommits`, the commit of each vendor clone the agents were generated from; when a clone moves (maintenance refresh) the status script asks for an installer re-run so rosters and skill lists match. Classify each managed file:

1. **Managed (hashed in the manifest)** - the installer overwrites it on every update. If the user edited one, **their edit will be reset on the next update.** Do not protect it and do not build on it in place. Tell them plainly, then steer the change into a **NEW** file (a new agent, a new skill, a new instructions file) under `.github/` that the installer will never touch.
2. **Merged (the three config files)** - the user may add their own keys; only the installer-required keys are enforced.
3. **User-created (not in the manifest)** - it is theirs. Never modify or delete it. This is how users extend the workspace safely.

Run `Setup-PowerPlatformWorkspace.ps1 -VerifyRoot <workspace>` to list drift (MISSING / CHANGED) against the manifest.

## Self-pruning is automatic - verify it, do not fight it

On every update the installer **self-prunes**: any file it shipped in a previous version but no longer ships is removed automatically (it diffs the previous write-log against the new one, scoped to managed roots) and the deletion is committed. Two pre-manifest leftovers (`.github/copilot/`, `.session-active`) are removed only when their content is recognisably installer output; otherwise they are reported and left. It deliberately leaves `.github/hooks/` alone - that is VS Code's hooks folder and may hold the user's own files. Refreshing the skills clone stashes any local edits first (`installer-autostash <stamp>`, recoverable with `git stash list` / `stash pop`) and resets to upstream; it never discards them silently.

- To trigger a clean-up, re-run the installer (or `-VerifyRoot` to preview).
- A file the **user** created is never in our write-log, so the prune never touches it - confirm this when a user worries about a new file of theirs.
- If you spot a leftover the automatic prune missed, report it; only remove a file you can show was installer-authored, never a user file.

## Boundaries

Edit workspace configuration and embedded skills only. Never edit user solution source (that belongs to the Team Leads). Never touch Production. You enforce the installer's authoritative-overwrite contract - you do not soften or replace it.
'@)
    }
    elseif ($isLead) {
        $mcpNote = ''
        if ($Agent.mcpServers) {
            $mcpList = (@($Agent.mcpServers) -join ', ')
            $mcpNote = (@'

## Model Context Protocol (MCP) servers

You are granted: **%%MCP%%** (via the `<server>/*` wildcard in your `tools`). A server starts on demand the first time you call one of its tools - probe it lazily with ONE cheap call when a task first needs it, never at startup. If a tool reports "no session" / unavailable, that almost always means the server has not started or a prerequisite is missing (see `.github/agent-docs/tool-status.json`) - fall back to offline authoring via pac CLI and SAY SO, rather than telling the user a capability "does not exist". `microsoft-learn` is documentation only: use it to confirm current Microsoft guidance, never as a substitute for the SKILL.md.
'@).Replace('%%MCP%%', $mcpList)
        }
        [void]$sb.AppendLine((@'

## Your role: own this department end to end

You are the Team Lead for **%%DEPT%%**. You take a scoped WORK ORDER from the Master or the Solution Architect (or a request from the user directly), deliver it - yourself with your skills, or through the Microsoft worker that owns the artifact - validate it, and return a WORK RESULT.

## Team lead ownership and validation

- Pull the solution (export -> unpack) when you need local source; edit the unpacked files; run `git diff` and summarise what changed. For live work follow the plugin SKILL.md (canvas: `sync_canvas` -> edit `.pa.yaml` -> `compile_canvas`).
- Assign exactly **one** worker per artifact so two agents never write the same file or live object; give it a bounded scope; **validate the returned work yourself** (compile / pack succeeds, diff is what was asked, QA line complete, no raw `.zip` committed) before you report success upward. Do not sign off unreviewed worker output.
- Pack + import only after confirming the target environment (`pac org who`) and holding that environment's approval token; **never import to Production without `confirm push to prod`**.
- Escalate rather than exceed your remit: cross-type design or sequencing questions go to **001 - Solution Architect**; cross-artifact acceptance and the Production gate go to **002 - Integration QA & Change Controller**. Both are in your `agents:` list: when the user selected you directly, dispatch them yourself; when the Master dispatched you, return `NEEDS ARCHITECT` / the QA request in your WORK RESULT and let the Master sequence it (it already owns the plan).

## Refusal and escalation

If the request is outside **%%DEPT%%** (a different component type), return `OUT OF SCOPE` naming the right Team Lead - do not improvise outside your scope. If a worker needs a tool you were not granted, or the action is destructive without a token, return `NEEDS APPROVAL` / `NEEDS INPUT` instead of proceeding.

## Your team

<!-- team-roster:start -->
No Microsoft worker agents were found for your plugin(s) at install time - you run the skills directly. Re-running the installer refreshes this table when Microsoft ships `plugins/<plugin>/agents/*.md`.
<!-- team-roster:end -->

## How you dispatch

Send each worker exactly one WORK ORDER (format in `.github/agent-docs/working-flow-reference.md`): goal in the user's words, the exact artifact path or live item, mode (offline / live / hybrid), constraints, the validation evidence you expect back, approvals already granted (literal tokens), and the facts already established (environment URL, working directory, plan files). Workers are stateless and cannot ask the user: put everything they need in the order. Independent artifacts may be dispatched in parallel; the same file or live object never goes to two workers at once.

Microsoft's SKILL.md may say "invoke `canvas-screen-builder`" or use the `Task` tool: use the **dispatch name** from your team table above (e.g. `010-canvas-screen-builder`), never the bare Microsoft name, and its "waves of at most three", "compile after each wave" and "re-invoke the planner on Blocked" rules apply unchanged. Microsoft's `AskUserQuestion` / plan-approval steps become `NEEDS APPROVAL` in your WORK RESULT (with the plan attached) when you were dispatched; when the user selected you directly, ask them.

When a worker returns `NEEDS APPROVAL` / `NEEDS INPUT` / `NEEDS ARCHITECT` / `OUT OF SCOPE`, relay the `request` upward unchanged in your own WORK RESULT. If a single design or dependency question blocks you and the Master did not provide a plan, you may dispatch **001 - Solution Architect** yourself with that precise question (it answers in place and never dispatches you back), then continue.%%MCP%%
'@).Replace('%%DEPT%%', [string]$Agent.department).Replace('%%MCP%%', $mcpNote))
    }
    else {
        [void]$sb.AppendLine(@'

## Scope boundary

You are a worker focused strictly on your task. Do the work, validate it, and return the result to your Team Lead. Do not delegate. Escalate anything outside your scope.
'@)
    }

    # Per-agent specialist knowledge (skills with resolved paths, playbook, validation, tool ladder).
    $knowledgeSection = New-KnowledgeSection -Agent $Agent -Knowledge $agentKnowledge[$Agent.id]
    if ($knowledgeSection) { [void]$sb.AppendLine(''); [void]$sb.AppendLine($knowledgeSection) }

    if ($isMaster) {
        [void]$sb.AppendLine(@'

## Return contract (to the user)

One consolidated answer: what changed and where (files / live items / environment), validation evidence per team, risks, and the decisions or approvals you still need from the user. Quote approval requests verbatim. Keep the session ledger (approvals granted, results) so follow-up requests build on it.
'@)
    } else {
        [void]$sb.AppendLine(@'

## Return contract

Always end with a WORK RESULT block (format in `.github/agent-docs/working-flow-reference.md`):

```
WORK RESULT
status: DONE | DONE WITH RISKS | NEEDS APPROVAL | NEEDS INPUT | NEEDS ARCHITECT | OUT OF SCOPE | FAILED
changed: <files / live objects, or none>
validation: <what was run and the outcome - never claim a check you did not run>
risks: <or none>
request: <exact approval token, question, design decision, or correct owner - only when status is not DONE>
```
'@)
    }
    # Normalise: exactly one blank line before every section heading.
    $text = [regex]::Replace($sb.ToString(), '(?<=[^\r\n])\r?\n(?=## )', "`n`n")
    return $text.TrimEnd() + "`n"
}

# =====================================================================
# DYNAMIC WORKER SUB-AGENT DISCOVERY
# ---------------------------------------------------------------------
# Microsoft ships its own bundled worker agents inside each plugin at
# power-platform-skills/plugins/<plugin>/agents/*.md (e.g. canvas-app-planner,
# canvas-screen-builder). We do NOT fork them. After the skills clone/refresh we
# scan each Lead's plugin, and for every worker we generate a HIDDEN wrapper agent
# in .github/agents/ that simply tells a sub-agent to read Microsoft's file
# verbatim (resolving ${PLUGIN_ROOT} to the plugin folder). Each wrapper is wired
# into its owning Lead's `agents:` list so the Lead can dispatch it as a subagent.
# New upstream workers are picked up automatically on the next refresh; wrappers
# for workers Microsoft removed are pruned. Emit/dry-run mode never clones, so this
# is a no-op there (and existing tests keep seeing exactly the 12 core agents).

# Parse a Microsoft worker's YAML front matter: its name, whether it writes files,
# whether it runs commands, and which MCP servers ITS OWN tool list names - so the
# wrapper mirrors the worker's least-privilege intent, never the Lead's grants.
# Microsoft tool spellings: `mcp__<server>__<tool>` / `<server>/<tool>` -> `<server>/*`;
# Write/Edit/create/edit -> edit; Bash -> execute.
function Read-WorkerFrontmatter ([string]$Path, [string]$FallbackName) {
    $name = $FallbackName
    $canEdit = $false
    $canExecute = $false
    $hasToolsKey = $false
    $mcp = New-Object 'System.Collections.Generic.List[string]'
    try {
        $inFm = $false; $inTools = $false
        foreach ($ln in [System.IO.File]::ReadAllLines($Path)) {
            if ($ln -match '^\s*---\s*$') { if (-not $inFm) { $inFm = $true; continue } else { break } }
            if (-not $inFm) { continue }
            if ($ln -match '^\s*name\s*:\s*(.+?)\s*$') { $name = $Matches[1].Trim().Trim('"').Trim("'") }
            $toolText = $null
            if ($ln -match '^\s*tools\s*:\s*(.*)$') { $inTools = $true; $hasToolsKey = $true; $toolText = $Matches[1] }
            elseif ($inTools) {
                if ($ln -match '^\s*-\s*(.+?)\s*$') { $toolText = $Matches[1] }
                elseif ($ln -match '^\S') { $inTools = $false }
            }
            if ($null -eq $toolText) { continue }
            foreach ($tok in ($toolText -split '[,\[\]]' | ForEach-Object { $_.Trim().Trim('"').Trim("'") } | Where-Object { $_ })) {
                $s = $null
                if ($tok -match '^mcp__([^_]+(?:_[^_]+)*?)__') { $s = $Matches[1] }
                elseif ($tok -match '^([A-Za-z0-9][A-Za-z0-9 ._-]*)/[^/]+$') { $s = $Matches[1] }
                if ($s) {
                    # Claude plugin runtimes namespace a plugin's own MCP as plugin_<plugin>_<server>; we register the bare server name.
                    if ($s -match '^plugin_[a-z0-9-]+_(.+)$') { $s = $Matches[1] }
                    if (-not $mcp.Contains($s)) { $mcp.Add($s) }
                    continue
                }
                if ($tok -match '^(?i)(edit|write|create|multiedit|notebookedit|apply_patch)$') { $canEdit = $true; continue }
                if ($tok -match '^(?i)(bash|execute|powershell|shell)$') { $canExecute = $true; continue }
            }
        }
    } catch { }
    # Microsoft omits `tools:` on some workers, which in its runtime means "inherit everything".
    # We map that to a bounded default (read/search/edit/execute, no MCP) instead of read-only,
    # so e.g. an architect that runs `node --version` or writes a plan file is not silently crippled.
    if (-not $hasToolsKey) { $canEdit = $true; $canExecute = $true }
    return [pscustomobject]@{ Name = $name; CanEdit = $canEdit; CanExecute = $canExecute; McpServers = @($mcp); HasToolsKey = $hasToolsKey }
}

# Build one hidden wrapper .agent.md that points at (never copies) a Microsoft worker.
# Workers get the LEAN tier contract: the WORK ORDER is their complete brief, they
# never delegate, cannot ask the user, and need a literal token for destructive work.
function New-WorkerWrapperContent ([string]$RegisteredName, [string]$WorkerName, [string]$Plugin, [string]$WorkerRelPath, [bool]$CanEdit, [string[]]$McpServers, [bool]$CanExecute = $false, [string]$PluginRoot = '') {
    if (-not $PluginRoot) { $PluginRoot = "power-platform-skills/plugins/$Plugin" }
    $tools = @('read', 'search')
    if ($CanEdit) { $tools += 'edit' }
    if ($CanExecute) { $tools += 'execute' }
    foreach ($m in $McpServers) { if ($m -and ($tools -notcontains "$m/*")) { $tools += "$m/*" } }
    $toolsYaml = ConvertTo-AgentYamlList $tools
    $nameEsc = $RegisteredName -replace "'", "''"
    $descEsc = ("Microsoft $Plugin worker '$WorkerName' - runs its authoritative bundled procedure. Dispatched by its Team Lead; not user-invocable.") -replace "'", "''"
    $fm = "---`nname: '$nameEsc'`ndescription: '$descEsc'`nuser-invocable: false`ntools: $toolsYaml`nagents: []`n---`n`n"
    $tpl = @'
# %%NAME%% - Microsoft %%PLUGIN%% worker (delegated)

You are a hidden worker sub-agent dispatched by your Team Lead as `%%REGISTERED%%`. Your
authoritative instructions are Microsoft's own bundled agent definition in the cloned
skills repo - follow them verbatim and never fork, summarise, or improvise them.

## Operating contract

- Your WORK ORDER from the Team Lead is your complete brief: do not re-run startup and do
  not re-read the flow documents. You cannot ask the user questions: if something is
  missing or needs approval, return it in your WORK RESULT (`NEEDS INPUT` / `NEEDS APPROVAL`).
- Microsoft's file targets another agent runtime. Translate, do not copy:
  - `Task` / `Agent` (delegation) - you do NOT have it and never delegate; if the procedure
    requires another agent, stop and return `NEEDS INPUT` naming the agent and what it should do.
  - `AskUserQuestion` - return `NEEDS INPUT` with the exact question and options.
  - `EnterPlanMode` / `ExitPlanMode` (plan approval) - write the plan in your result and return
    `NEEDS APPROVAL` with it attached; resume only when re-dispatched with the approval.
  - `TaskCreate` / `TaskUpdate` / `TaskList` / `TodoWrite` (task lists) - keep an inline
    checklist in your working notes or plan file; there is no task tool.
  - `Write` / `Edit` / `MultiEdit` / `apply_patch` - your `edit` tool; `Bash` - your `execute` tool.
  - `Skill` tool / `<plugin>:<skill>` references (e.g. `mcs-assistant:publish-agent`) - read
    `%%PLUGINROOT%%/skills/<skill>/SKILL.md` and follow it inline; you do not have a skill tool.
  - `${PLUGIN_ROOT}` / `${CLAUDE_PLUGIN_ROOT}` / a `pluginRoot` looked up from
    `plugin-paths.json` is `%%PLUGINROOT%%` (so `reference/x.md` means `%%PLUGINROOT%%/reference/x.md`).
- Stay within the tools granted in your front matter (they mirror what Microsoft gave
  this worker; when Microsoft declared none, you hold a bounded read/search/edit/execute
  set and no MCP servers). Do not request anything broader; if the procedure needs a tool
  you do not hold, stop and return `NEEDS INPUT` naming it.
- Destructive actions need an explicit approval token in your WORK ORDER
  (`approvals granted: <token>`). Deleting or dropping any screen, control, flow, table,
  column, form, view, page or file counts as destructive even when the user asked for it
  in plain words - the user's phrasing is NOT the token. Without the token: stop, change
  nothing, return `NEEDS APPROVAL` with the exact action and a proposed token such as
  `APPROVED:DELETE:<artifact>`. Execute only what the token names.
- Never edit files under `%%PLUGINROOT%%` (read-only vendor clone). Never touch Production.

## Procedure

1. Read your instruction file in full and do exactly what it says:
   `%%WORKERPATH%%`
2. Wherever it refers to `${PLUGIN_ROOT}`, resolve it to `%%PLUGINROOT%%`
   (so `${PLUGIN_ROOT}/references/Foo.md` means `%%PLUGINROOT%%/references/Foo.md`).
3. Read the guides, templates and references it points to for the step you are on,
   honouring its own "read X only if Y" conditions - do not pre-load every file.
4. Validate your own change the way the file specifies (self-QA line, compile, tests).
5. If the instruction file is missing, stop and return `FAILED` saying that
   the vendor clone `%%PLUGINROOT%%` needs a refresh (Workspace Maintainer) instead of guessing.

## Scope boundary

You own exactly the artifact named in your WORK ORDER. Do not create or invoke other
agents. Refuse and escalate instead of improvising when a request falls outside that
artifact or needs a tool you were not granted.

## Return contract

Return exactly the hand-off Microsoft's worker definition specifies (its plan, its screen
file + QA line, etc.), then end with a WORK RESULT block:

```
WORK RESULT
status: DONE | DONE WITH RISKS | NEEDS APPROVAL | NEEDS INPUT | OUT OF SCOPE | FAILED
changed: <files touched, or none>
validation: <what was run and the outcome - never claim a check you did not run>
risks: <or none>
request: <exact approval token, question, or correct owner - only when status is not DONE>
```
'@
    $body = $tpl.Replace('%%NAME%%', $WorkerName).Replace('%%REGISTERED%%', $RegisteredName).Replace('%%PLUGIN%%', $Plugin).Replace('%%WORKERPATH%%', $WorkerRelPath).Replace('%%PLUGINROOT%%', $PluginRoot)
    return $fm + $body
}

# Build the per-Lead discovery descriptors from the manifest (Lead -> its plugins).
function Get-DiscoveryLeadDescriptors ($OrderedAgents, $ThreeDigitById) {
    $out = @()
    foreach ($a in $OrderedAgents) {
        if ($a.level -ne 'team-lead') { continue }
        $plugins = @($a.primarySkills) | Where-Object { $_ }
        if ($plugins.Count -eq 0) { continue }
        $prefix = $ThreeDigitById[$a.id]
        $file = [string]$a.filename -replace '^\d+', $prefix
        $out += [pscustomobject]@{ Prefix = $prefix; File = $file; McpServers = @($a.mcpServers); Plugins = $plugins }
    }
    return , $out
}

# Scan plugins, (re)generate hidden wrappers, wire each into its Lead (agents: list +
# `## Your team` roster), prune stale. Wrapper filenames use a "<leadPrefix>-sub-<slug>"
# marker so pruning only ever touches discovery-generated files, never the 12 core
# agents. Returns a summary.
function Invoke-WorkerAgentDiscovery ([string]$WorkspaceRoot, $Leads) {
    $agentsDir   = Join-Path $WorkspaceRoot '.github\agents'
    $res = [pscustomobject]@{ Skipped = $true; Wrappers = @(); LeadWorkers = @{} }
    $roots = Get-PluginRoots $WorkspaceRoot
    if ($roots.Count -eq 0) { return $res }
    $res.Skipped = $false
    if (-not (Test-Path -LiteralPath $agentsDir)) { New-Item -ItemType Directory -Path $agentsDir -Force | Out-Null }

    $wanted = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($lead in $Leads) {
        $names = @()
        $rosterRows = @()
        foreach ($plugin in $lead.Plugins) {
            if (-not $roots.Contains($plugin)) { continue }
            $pluginRoot = [string]$roots[$plugin]
            $agentsFolder = Join-Path $WorkspaceRoot (Join-Path ($pluginRoot -replace '/', '\') 'agents')
            if (-not (Test-Path -LiteralPath $agentsFolder)) { continue }
            foreach ($wf in @(Get-ChildItem -LiteralPath $agentsFolder -Filter '*.md' -File -ErrorAction SilentlyContinue)) {
                $info = Read-WorkerFrontmatter $wf.FullName $wf.BaseName
                $workerName = $info.Name
                $slug = ($workerName.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
                if (-not $slug) { continue }
                $wrapperFile = "$($lead.Prefix)-sub-$slug.agent.md"
                $registered = "$($lead.Prefix)-$slug"
                $workerRel = "$pluginRoot/agents/$($wf.Name)"
                # Mirror the worker's OWN tools (Microsoft's least-privilege intent), never the Lead's MCP grants.
                $content = New-WorkerWrapperContent $registered $workerName $plugin $workerRel ([bool]$info.CanEdit) @($info.McpServers) ([bool]$info.CanExecute) $pluginRoot
                Write-ManagedFile (Join-Path $agentsDir $wrapperFile) $content
                [void]$wanted.Add($wrapperFile)
                $res.Wrappers += ".github\agents\$wrapperFile"
                if ($names -notcontains $registered) {
                    $names += $registered
                    $wt = @('read', 'search'); if ($info.CanEdit) { $wt += 'edit' }; if ($info.CanExecute) { $wt += 'execute' }; foreach ($m in @($info.McpServers)) { if ($m) { $wt += "$m/*" } }
                    $rosterRows += "| $bt$registered$bt | $bt$workerName$bt ($plugin) | $($wt -join ', ') | $bt$workerRel$bt |"
                }
            }
        }
        if ($names.Count -gt 0) {
            $res.LeadWorkers[$lead.Prefix] = $names
            $leadPath = Join-Path $agentsDir $lead.File
            if (Test-Path -LiteralPath $leadPath) {
                $raw = [System.IO.File]::ReadAllText($leadPath)
                # MERGE with the Lead's authored list (Architect / QA escalation targets), never overwrite it.
                $existingAgents = @()
                $curLine = [regex]::Match($raw, '(?m)^agents:\s*\[(.*)\]\s*$')
                if ($curLine.Success) {
                    foreach ($mm in [regex]::Matches($curLine.Groups[1].Value, "'((?:[^']|'')*)'")) { $v = $mm.Groups[1].Value -replace "''", "'"; if ($v -and $v -notmatch '^\d{3}-') { $existingAgents += $v } }
                }
                $agentsLine = 'agents: ' + (ConvertTo-AgentYamlList (@($existingAgents) + @($names) | Select-Object -Unique))
                $patched = ([regex]'(?m)^agents:.*$').Replace($raw, { param($m) $agentsLine }, 1)
                # Roster: the Lead must know its workers by DISPATCH name (Microsoft's SKILL.md uses the bare name).
                $roster = @(
                    'Dispatch by the **Dispatch name** (the registered agent name); Microsoft''s SKILL.md refers to the bare name in the second column. One worker per artifact.',
                    '',
                    '| Dispatch name | Microsoft worker (plugin) | Tools | Definition |',
                    '|---|---|---|---|'
                ) + $rosterRows
                $rosterText = "<!-- team-roster:start -->`n" + ($roster -join "`n") + "`n<!-- team-roster:end -->"
                $patched = [regex]::Replace($patched, '(?s)<!-- team-roster:start -->.*?<!-- team-roster:end -->', { param($m) $rosterText }, 1)
                Write-ManagedFile $leadPath $patched
            }
        }
    }
    # Prune only files WE generated: three-digit lead prefix + "-sub-" AND our wrapper
    # marker in the body. A user agent that merely contains "-sub-" in its name is kept.
    foreach ($f in @(Get-ChildItem -LiteralPath $agentsDir -Filter '*-sub-*.agent.md' -File -ErrorAction SilentlyContinue)) {
        if ($wanted.Contains($f.Name)) { continue }
        if ($f.Name -notmatch '^\d{3}-sub-.+\.agent\.md$') { continue }
        $head = (Get-Content -LiteralPath $f.FullName -TotalCount 12 -ErrorAction SilentlyContinue) -join "`n"
        if ($head -notmatch 'Microsoft .+ worker \(delegated\)') { continue }
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
    }
    return $res
}

$totalSteps = 8

# -- STEP 1 - Workspace configuration ---------------------------------
Show-Step 1 $totalSteps "Workspace Configuration"

$updateMode = $false
if ($EmitAgentsTo) {
    # Non-interactive generation mode (CI / tests): target folder is given.
    $rootPath = [System.IO.Path]::GetFullPath($EmitAgentsTo)
    if (-not (Test-Path -LiteralPath $rootPath)) { New-Item -ItemType Directory -Path $rootPath -Force | Out-Null }
    # A target that already carries our manifest is an UPDATE (prune, migration and refresh paths apply).
    if (Test-Path -LiteralPath (Join-Path $rootPath '.github\installed-manifest.json')) { $updateMode = $true }
    Write-Host "  [emit mode] Generating into: $rootPath$(if ($updateMode) { ' (update)' })" -ForegroundColor Cyan
} else {

$defaultName = "Power Platform"
$folderName = Read-Host "Enter a name for your workspace folder (default: $defaultName)"
if ([string]::IsNullOrWhiteSpace($folderName)) { $folderName = $defaultName }

$rootPath = Join-Path $env:USERPROFILE $folderName

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

}  # end interactive STEP 1

# -- STEP 2 - Prerequisites check --------------------------------------
if (-not $EmitAgentsTo) {
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
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $installerScript + '"'),
                '-Channel', '10.0', '-InstallDir', ('"' + $dotnetInstallDir + '"'), '-NoPath'
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

# -- Azure CLI (az) - installed by default -----------------------------
# 'az' has two jobs here: it authenticates the Power Automate FlowAgent MCP
# server ('az login') for live cloud-flow authoring, and it auto-resolves a
# Power Apps visual's live appId from Dataverse during the pbi-powerapps-
# integration repoint workflow. We install it by default (via winget), the
# same way the .NET 10 SDK and Node.js are installed for the live MCP servers.
# It never blocks setup - everything else works without it, and the repoint
# workflow still has maker-portal / sibling-report fallbacks.
Write-Host ""
Write-Host "  -- Azure CLI (Power Automate MCP auth + Power BI <-> Power Apps repoint) --" -ForegroundColor DarkGray

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

function Find-RealPython {
    # Return the first alias that runs a genuine Python 3 (skips the Microsoft
    # Store execution-alias stub, which exits non-zero on --version).
    foreach ($cand in @('py', 'python', 'python3')) {
        if (-not (Get-Command $cand -ErrorAction SilentlyContinue)) { continue }
        try {
            $v = (& $cand --version 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -eq 0 -and $v -match 'Python\s+3') { return $cand }
        } catch { }
    }
    return $null
}

function Install-AzCliViaVenv {
    # Locked-down fallback for when winget is blocked (the common exit 1603 on
    # managed PCs): install azure-cli into an isolated venv under a short
    # profile-root path (%USERPROFILE%\.pp-az). A plain 'pip install azure-cli'
    # overflows the Windows 260-char MAX_PATH limit because azure-cli has a very
    # deep package tree; a short venv path sidesteps it. Needs a real Python 3;
    # returns $true if 'az' resolves afterwards. Never throws.
    $ErrorActionPreference = 'Continue'
    $python = Find-RealPython
    if (-not $python) { return $false }

    $venv    = Join-Path $env:USERPROFILE '.pp-az'
    $scripts = Join-Path $venv 'Scripts'
    $venvPy  = Join-Path $scripts 'python.exe'

    # Already installed by a previous run? Re-use it (fast + idempotent).
    $azExisting = Get-ChildItem $scripts -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -match '^az\.(cmd|bat|exe)$' } | Select-Object -First 1
    if ($azExisting) { Add-DirToPath $scripts; return $true }

    Write-Host "  Installing Azure CLI into an isolated environment (no admin; sidesteps the" -ForegroundColor DarkGray
    Write-Host "  Windows 260-char path limit)... this can take a few minutes." -ForegroundColor DarkGray

    if (-not (Test-Path $venvPy)) {
        try { & $python -m venv $venv 2>&1 | Out-Null } catch { }
    }
    if (-not (Test-Path $venvPy)) { return $false }

    try { & $venvPy -m pip install --upgrade pip --quiet 2>&1 | Out-Null } catch { }
    try { & $venvPy -m pip install --upgrade --retries 5 --timeout 120 azure-cli 2>&1 | Out-Null } catch { }

    $azWrapper = Get-ChildItem $scripts -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -match '^az\.(cmd|bat|exe)$' } | Select-Object -First 1
    if ($azWrapper) { Add-DirToPath $scripts; return $true }
    return $false
}

$azLink = "https://aka.ms/installazurecli"
if (Test-AzCli) {
    Write-Host "  Azure CLI (az): detected" -ForegroundColor Green
} else {
    Write-Host "  Azure CLI (az) not found - attempting install (FlowAgent MCP auth + repoint auto-resolve)..." -ForegroundColor Yellow

    # 1) winget (per-machine MSI). Silent, no admin where allowed; commonly
    #    blocked with exit 1603 on locked-down PCs, in which case we fall through.
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "  Trying winget (Microsoft.AzureCLI)..." -ForegroundColor DarkGray
        try { & winget install --silent --accept-package-agreements --accept-source-agreements -e --id Microsoft.AzureCLI 2>$null | Out-Null } catch { }
    }

    # 2) Isolated-venv pip install - the reliable no-admin route for locked-down
    #    machines where winget is blocked (needs a real Python 3; see above).
    if (Test-AzCli) {
        Write-Host "  Azure CLI installed via winget (open a new terminal if 'az' isn't found right away)." -ForegroundColor Green
    } elseif (Install-AzCliViaVenv) {
        Write-Host "  Azure CLI installed (isolated environment)." -ForegroundColor Green
    } else {
        $warnings += "Azure CLI (az) could not be installed automatically (winget blocked and no Python 3" + [Environment]::NewLine +
                     "             for the isolated-venv fallback). Live flow authoring (FlowAgent MCP) and the" + [Environment]::NewLine +
                     "             Power BI <-> Power Apps repoint auto-resolve need it - install it from" + [Environment]::NewLine +
                     "             $azLink, then re-run this installer."
    }
}

if ($missing.Count -gt 0) {
    Write-Host "`nMissing prerequisites:" -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host "`nInstall the above and re-run this script."
    exit 1
}

# -- Node.js (Power Automate FlowAgent MCP server) ---------------------
# The FlowAgent MCP server (bundled in the cloned power-platform-skills repo)
# runs on Node.js 18+ and authenticates with 'az login'. We install it by
# default (via winget) so live cloud-flow authoring works out of the box, the
# same way the .NET 10 SDK is installed for live canvas authoring. It never
# blocks setup - the Power Automate Lead falls back to pac CLI + offline
# authoring when it is unavailable (same non-blocking pattern as canvas / dnx).
function Test-NodeJs {
    # Resilient node probe: a fresh winget install updates the registry PATH but
    # not this running process, so refresh PATH from Machine+User before giving up.
    $c = Get-Command node -ErrorAction SilentlyContinue
    if (-not $c) {
        try {
            $machine = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
            $user    = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
            $env:PATH = (@($env:PATH, $machine, $user) | Where-Object { $_ }) -join ';'
        } catch { }
        $c = Get-Command node -ErrorAction SilentlyContinue
    }
    if ($c) {
        try {
            $v = (& node --version) 2>$null
            if ($v -match 'v(\d+)\.' -and [int]$Matches[1] -ge 18) { return $true }
        } catch { }
    }
    return $false
}

Write-Host ""
Write-Host "  -- Power Automate FlowAgent MCP (Node.js) --" -ForegroundColor DarkGray
if (Test-NodeJs) {
    $nodeVer = (& node --version) 2>$null
    Write-Host "  Node.js ${nodeVer}: detected (Power Automate FlowAgent MCP ready)" -ForegroundColor Green
} else {
    Write-Host "  Node.js 18+ not found - attempting install (for the Power Automate FlowAgent MCP)..." -ForegroundColor Yellow
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "  Installing Node.js LTS via winget (OpenJS.NodeJS.LTS)..." -ForegroundColor DarkGray
        try { & winget install --silent --accept-package-agreements --accept-source-agreements -e --id OpenJS.NodeJS.LTS 2>$null | Out-Null } catch { }
    }
    if (Test-NodeJs) {
        $nodeVer = (& node --version) 2>$null
        Write-Host "  Node.js ${nodeVer} installed (Power Automate FlowAgent MCP ready; open a new terminal if 'node' isn't found right away)." -ForegroundColor Green
    } else {
        $warnings += "Offline flow authoring is ready, but the LIVE Power Automate FlowAgent MCP is NOT" + [Environment]::NewLine +
                     "             enabled yet - it needs Node.js 18+ (https://nodejs.org). Install it, open a" + [Environment]::NewLine +
                     "             new terminal, then re-run this installer to enable live flow authoring."
    }
}

if ($warnings.Count -gt 0) {
    Write-Host ""
    $warnings | ForEach-Object { Write-Host "  WARNING: $_" -ForegroundColor Yellow }
    Write-Host ""
}

Write-Host "All prerequisites found." -ForegroundColor Green
Read-Host "`nPress Enter to continue setup..."

}  # end STEP 2 prerequisites (skipped in emit mode)

# -- STEP 3 - Create folder structure ----------------------------------
Show-Step 3 $totalSteps "Creating Folder Structure"
$dirs = @(
    $rootPath
    "$rootPath\exports"
    "$rootPath\deploy"
    "$rootPath\scripts"
    "$rootPath\.github\agents"
    "$rootPath\.github\agent-docs"
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
if (-not $EmitAgentsTo) { Read-Host "`nPress Enter to continue..." }

# -- STEP 4 - Clone / refresh the Microsoft vendor repositories ---------
# Runs BEFORE agent generation so the skill paths written into each agent
# resolve against the real upstream tree and worker discovery can see the
# plugins. Emit mode (CI / tests) never touches the network and skips this.
Show-Step 4 $totalSteps "Microsoft Vendor Repositories"
foreach ($vendor in $vendorClones) {
    $vendorPath = Join-Path $rootPath $vendor.Name
    if ($EmitAgentsTo) {
        Write-Host "  [emit mode] $($vendor.Name) clone skipped (no network)." -ForegroundColor DarkGray
    } elseif (-not (Test-Path -LiteralPath $vendorPath)) {
        Write-Host "  Cloning $($vendor.Url -replace '^https://github.com/', '' -replace '\.git$', '') from GitHub..."
        Write-Host "  (this may take a minute depending on your connection)" -ForegroundColor DarkGray
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { & git clone $vendor.Url "$vendorPath" 2>$null | Out-Null } catch { }
        $ErrorActionPreference = $prevEAP
        $marker = if ($vendor.Layout -eq 'plugins') { Join-Path $vendorPath 'plugins' } else { Join-Path $vendorPath 'skills' }
        if (Test-Path -LiteralPath $marker) {
            $head = (& git -C $vendorPath log -1 --format='%h %cd' --date=short 2>$null)
            Write-Host "  $($vendor.Name) cloned successfully ($head)." -ForegroundColor Green
        } else {
            Write-Host "  Warning: could not clone $($vendor.Name). Its Lead will re-discover skills by keyword; re-run the installer when online." -ForegroundColor Yellow
        }
    } elseif ($updateMode) {
        Write-Host "  $($vendor.Name)/ already exists - force-refreshing to upstream..." -ForegroundColor White
        # The installer is authoritative for vendor code: the clone must always
        # mirror published upstream. Update-VendorClone stashes any local edits
        # (recoverable via 'git stash list') then hard-resets to the upstream commit.
        if (Update-VendorClone $vendorPath $vendor.Name) {
            Write-Host "  $($vendor.Name) mirrors upstream." -ForegroundColor Green
        } else {
            Write-Host "  Note: $($vendor.Name) could not be refreshed (offline or git error)." -ForegroundColor Yellow
            Write-Host "  Inspect with 'git -C $($vendor.Name) status'." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  $($vendor.Name)/ already exists - skipping clone." -ForegroundColor Green
    }
}

# -- STEP 5 - Generate configuration files -----------------------------
Show-Step 5 $totalSteps "Generating Configuration Files"

# -- .gitignore --------------------------------------------------------
$gitignorePath = "$rootPath\.gitignore"
if ($updateMode -or -not (Test-Path $gitignorePath)) {
    $gitignoreContent = @"
*.zip
exports/
node_modules/
.env
*.log
*.user
power-platform-skills/
copilot-studio-plugin/
.github/agent-docs/tool-status.json
.github/agent-docs/guardrail-status.json
.github/installed-manifest.json
"@
    Write-ManagedFile $gitignorePath $gitignoreContent
    Write-Host "  $(if ($updateMode) {'Updated'} else {'Created'}) .gitignore"
}

# -- scripts/pac-workflows.ps1 ----------------------------------------
$pacWorkflowsPath = "$rootPath\scripts\pac-workflows.ps1"
if ($updateMode -or -not (Test-Path $pacWorkflowsPath)) {
    $pacWorkflowsContent = @'
# Power Platform PAC CLI helper workflows
# Used by Power Platform Master Agent - can also be run manually.
#
# Safety model:
#   * Every pac / git step is exit-code checked; the script stops at the first failure
#     and never commits after a failed step.
#   * Paths are anchored to THIS workspace (the script's own location), never to the
#     caller's current directory, and names cannot contain path separators or '..'.
#   * The push package is built fresh (any previous zip is deleted first) so a failed
#     pack can never import yesterday's package.
#   * The REAL target is resolved from `pac org who` and pinned on every remote
#     command. For push/pull it must match the environment map or -EnvironmentUrl;
#     an unmapped label is refused (no "whatever profile is active" imports).
#   * Production is classified from the environment map (`.github/agent-docs/environments.json`,
#     user-owned) or `-EnvironmentUrl`; the name heuristic ('prod' in label/URL/name) is a
#     supplementary guard, not the gate. A push to Production needs -ConfirmProd.
#   * After import the solution is verified by exact unique name in `pac solution list --json`.
#   * Only the solution's own folder is staged and committed, never the whole workspace.

param(
  [ValidateSet('pull', 'push', 'init')]
  [string]$Action,
  [string]$SolutionName,
  [string]$Environment,        # DEV | TEST | PROD  (local folder label; mapped to a URL in environments.json)
  [string]$EnvironmentUrl,     # explicit https://<org>.crm.dynamics.com target - verified against `pac org who`
  [string]$PackageType = "Unmanaged",
  [string]$PublisherName = "PowerPlatformDev",
  [string]$PublisherPrefix = "pp",
  [switch]$ConfirmProd         # required for 'push' when the verified target is Production
)

$ErrorActionPreference = 'Stop'
function Fail([string]$Message, [int]$Code = 1) { Write-Host "ERROR: $Message" -ForegroundColor Red; exit $Code }
function Invoke-Step([string]$What, [scriptblock]$Command) {
    Write-Host "  > $What" -ForegroundColor DarkGray
    & $Command
    if ($LASTEXITCODE -ne 0) { Fail "$What failed (exit $LASTEXITCODE). Nothing was committed." $LASTEXITCODE }
}
# Native commands write progress to stderr; capture stdout only and judge by exit code.
function Invoke-Native([string[]]$CommandLine) {
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = (& $CommandLine[0] @($CommandLine[1..($CommandLine.Count - 1)]) 2>$null | Out-String); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prev }
    return [pscustomobject]@{ Output = $out; Exit = $code }
}

if ([string]::IsNullOrWhiteSpace($Action) -or [string]::IsNullOrWhiteSpace($SolutionName) -or [string]::IsNullOrWhiteSpace($Environment)) {
    Fail "Usage: pac-workflows.ps1 -Action pull|push|init -SolutionName <name> -Environment <DEV|TEST|PROD> [-EnvironmentUrl <url>] [-ConfirmProd]"
}
foreach ($nm in @($SolutionName, $Environment)) {
    if ($nm -match '[\\/:*?"<>|]' -or $nm -eq '.' -or $nm -eq '..' -or $nm -match '^\.|\.$|\s') { Fail "SolutionName / Environment must be plain names (letters, digits, - _), no path characters or dots." }
}

# -- Anchor every path to the workspace root (scripts/ sits directly under it) ----------
$workspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if (-not (Test-Path -LiteralPath (Join-Path $workspaceRoot '.github\agents'))) { Fail "This script must live in <workspace>\scripts\ (no .github\agents next to it): $workspaceRoot" }
Set-Location -LiteralPath $workspaceRoot
$exportsPath = Join-Path $workspaceRoot 'exports'
$deployPath  = Join-Path $workspaceRoot 'deploy'
$solutionDir = Join-Path (Join-Path $workspaceRoot $Environment) $SolutionName
$solutionRel = "$Environment/$SolutionName"
if (-not ([System.IO.Path]::GetFullPath($solutionDir)).StartsWith($workspaceRoot, [System.StringComparison]::OrdinalIgnoreCase)) { Fail "Resolved solution path escapes the workspace." }

# -- Verify git identity is configured (required for commits) ----------
$gitUser  = (Invoke-Native @('git', 'config', 'user.name')).Output.Trim()
$gitEmail = (Invoke-Native @('git', 'config', 'user.email')).Output.Trim()
if ([string]::IsNullOrWhiteSpace($gitUser) -or [string]::IsNullOrWhiteSpace($gitEmail)) {
    Write-Host "  Run:  git config --global user.name 'Your Name'" -ForegroundColor Yellow
    Write-Host "  Run:  git config --global user.email 'you@example.com'" -ForegroundColor Yellow
    Fail "git user.name and user.email must be configured before committing."
}
$inRepo = Invoke-Native @('git', 'rev-parse', '--is-inside-work-tree')
if ($inRepo.Exit -ne 0) { Fail "$workspaceRoot is not a git repository." }

# -- Environment map: label -> { url, production } (user-owned, optional) ---------------
# .github/agent-docs/environments.json, e.g.
#   { "DEV":  { "url": "https://orgdev.crm.dynamics.com",  "production": false },
#     "PROD": { "url": "https://orgprod.crm.dynamics.com", "production": true } }
$envMapPath = Join-Path $workspaceRoot '.github\agent-docs\environments.json'
$envEntry = $null
if (Test-Path -LiteralPath $envMapPath) {
    try { $envMap = Get-Content -LiteralPath $envMapPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Fail "environments.json is not valid JSON: $($_.Exception.Message)" }
    $prop = $envMap.PSObject.Properties | Where-Object { $_.Name -ieq $Environment } | Select-Object -First 1
    if ($prop) { $envEntry = $prop.Value }
}
$expectedUrl = $null
if ($EnvironmentUrl) { $expectedUrl = $EnvironmentUrl.TrimEnd('/') }
elseif ($envEntry -and $envEntry.url) { $expectedUrl = ([string]$envEntry.url).TrimEnd('/') }

# -- Resolve and verify the REAL target (pull/push only; init is local) --
$activeUrl = $null; $who = ''
if ($Action -ne 'init') {
    $whoRes = Invoke-Native @('pac', 'org', 'who')
    $who = $whoRes.Output
    if ($whoRes.Exit -ne 0 -or $who -notmatch 'https://[^\s]+') { Fail "No active pac environment. Run 'pac auth list' / 'pac org select --environment <url>' first." 3 }
    $activeUrl = ($Matches[0]).TrimEnd('/')
    if (-not $expectedUrl) {
        Fail "Label '$Environment' is not mapped to an environment. Pass -EnvironmentUrl <url> or add the label to .github/agent-docs/environments.json. Refusing to use whatever profile happens to be active ($activeUrl)." 5
    }
    if ($activeUrl -ne $expectedUrl) {
        Fail "Active pac environment is $activeUrl but '$Environment' expects $expectedUrl. Select the right environment (pac org select --environment $expectedUrl) and retry." 4
    }
    Write-Host "  Target environment: $activeUrl (label: $Environment)" -ForegroundColor DarkGray
}

# -- Production gate: map classification first, name heuristic as a supplementary guard --
$isProdMapped = ($null -ne $envEntry) -and ($envEntry.PSObject.Properties['production']) -and ([bool]$envEntry.production)
$labelIsProd  = $Environment -match '(?i)^prod'
$orgLooksProd = ($null -ne $activeUrl) -and (($activeUrl -match '(?i)prod') -or ($who -match '(?im)^\s*(Org|Environment|Friendly)\s*(Name|Display)?[^\r\n]*\bprod'))
$unclassified = ($Action -eq 'push') -and ($null -eq $envEntry) -and -not $labelIsProd -and -not $orgLooksProd
if ($Action -eq 'push' -and ($isProdMapped -or $labelIsProd -or $orgLooksProd) -and -not $ConfirmProd) {
    Write-Host "BLOCKED: this push targets a Production environment (label '$Environment', org $activeUrl)." -ForegroundColor Red
    Write-Host "         Re-run with -ConfirmProd only after the user has typed 'confirm push to prod'." -ForegroundColor Red
    exit 2
}
if ($unclassified) {
    Write-Host "  NOTE: '$Environment' has no entry in environments.json, so its Production status is unknown; proceeding because -EnvironmentUrl was given explicitly. Add it to the map to make this deterministic." -ForegroundColor Yellow
}

function Test-SolutionListed([string]$Name, [string]$Url) {
    $list = Invoke-Native @('pac', 'solution', 'list', '--environment', $Url, '--json')
    if ($list.Exit -ne 0) { return 'list-failed' }
    # PS 5.1 ConvertFrom-Json emits a JSON array as ONE Object[]; the ForEach-Object unrolls it.
    try { $items = @($list.Output | ConvertFrom-Json | ForEach-Object { $_ }) } catch { return 'unparseable' }
    if ($items.Count -eq 1 -and $items[0].PSObject.Properties['value']) { $items = @($items[0].value | ForEach-Object { $_ }) }  # tolerate a {"value":[...]} envelope
    foreach ($it in $items) {
        $u = $null
        foreach ($k in 'SolutionUniqueName', 'UniqueName', 'uniquename') { if ($it.PSObject.Properties[$k]) { $u = [string]$it.$k; break } }
        if ($u -and $u -eq $Name) { return 'present' }
    }
    return 'absent'
}

switch ($Action) {
  "pull" {
    Write-Host "Exporting $SolutionName from $Environment ($activeUrl)..."
    $zip = Join-Path $exportsPath "$SolutionName.zip"
    New-Item -ItemType Directory -Path $exportsPath -Force | Out-Null
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Invoke-Step "pac solution export" { pac solution export --name $SolutionName --path $zip --environment $activeUrl }
    if (-not (Test-Path $zip)) { Fail "Export reported success but $zip is missing." }
    Invoke-Step "pac solution unpack" { pac solution unpack --zipfile $zip --folder $solutionDir }
    if (-not (Test-Path (Join-Path $solutionDir 'Other\Solution.xml'))) { Fail "Unpack did not produce $solutionRel/Other/Solution.xml." }
    Invoke-Step "git add $solutionRel" { git add -- $solutionRel }
    $staged = Invoke-Native @('git', 'diff', '--cached', '--name-only', '--', $solutionRel)
    if ($staged.Exit -ne 0) { Fail "git diff --cached failed (exit $($staged.Exit))." }
    if ($staged.Output.Trim()) { Invoke-Step "git commit" { git commit -m "chore: pull $SolutionName from $Environment" -- $solutionRel } }
    else { Write-Host "  No changes to commit (local source already matches the export)." -ForegroundColor DarkGray }
    Write-Host "Pull complete." -ForegroundColor Green
  }
  "push" {
    if (-not (Test-Path (Join-Path $solutionDir 'Other\Solution.xml'))) { Fail "$solutionRel is not an unpacked solution (Other/Solution.xml missing). Pull it first." }
    Write-Host "Packing $SolutionName..."
    $zip = Join-Path $deployPath "$SolutionName.zip"
    New-Item -ItemType Directory -Path $deployPath -Force | Out-Null
    if (Test-Path $zip) { Remove-Item $zip -Force }   # never import a stale package
    Invoke-Step "pac solution pack" { pac solution pack --zipfile $zip --folder $solutionDir --packagetype $PackageType }
    if (-not (Test-Path $zip)) { Fail "Pack reported success but $zip is missing." }
    Write-Host "Importing to $Environment ($activeUrl)..."
    Invoke-Step "pac solution import" { pac solution import --path $zip --environment $activeUrl }
    switch (Test-SolutionListed $SolutionName $activeUrl) {
        'present'     { }
        'absent'      { Fail "Import returned success but '$SolutionName' is not listed in $activeUrl. Inspect the environment before retrying; the import may have partially applied." 6 }
        default       { Fail "Import completed but post-import verification could not run (pac solution list failed). Verify '$SolutionName' in $activeUrl manually before committing." 7 }
    }
    Invoke-Step "git add $solutionRel" { git add -- $solutionRel }
    $staged = Invoke-Native @('git', 'diff', '--cached', '--name-only', '--', $solutionRel)
    if ($staged.Exit -ne 0) { Fail "git diff --cached failed (exit $($staged.Exit))." }
    if ($staged.Output.Trim()) { Invoke-Step "git commit" { git commit -m "feat: push $SolutionName to $Environment" -- $solutionRel } }
    else { Write-Host "  No source changes to commit." -ForegroundColor DarkGray }
    Write-Host "Push complete." -ForegroundColor Green
  }
  "init" {
    Write-Host "Initialising new solution $SolutionName (publisher $PublisherName / prefix $PublisherPrefix)..."
    if (Test-Path $solutionDir) { Fail "$solutionRel already exists - refusing to overwrite." }
    New-Item -ItemType Directory -Path $solutionDir -Force | Out-Null
    Invoke-Step "pac solution init" { pac solution init --publisher-name $PublisherName --publisher-prefix $PublisherPrefix --output-directory $solutionDir }
    Invoke-Step "git add $solutionRel" { git add -- $solutionRel }
    Invoke-Step "git commit" { git commit -m "chore: init solution $SolutionName" -- $solutionRel }
    Write-Host "Init complete." -ForegroundColor Green
  }
}
'@
    Write-ManagedFile $pacWorkflowsPath $pacWorkflowsContent
    Write-Host "  $(if ($updateMode) {'Updated'} else {'Created'}) scripts/pac-workflows.ps1"
} else {
    Write-Host "  Exists: scripts/pac-workflows.ps1" -ForegroundColor DarkGray
}

# -- Manifest ordering + label maps (used by docs and agent generation) -
# Executives first (000-003), then Team Leads (010-080), then any workers.
# Filenames carry a 3-digit, team-grouped prefix so the dropdown sorts by
# hierarchy. These maps are consumed by copilot-instructions.md, AGENTS.md and
# the agent-file generation loop below.
$orderedAgents = @(
    @($agentManifest.agents | Where-Object { $_.level -eq 'executive' })
    @($agentManifest.agents | Where-Object { $_.level -eq 'team-lead' })
    @($agentManifest.agents | Where-Object { $_.level -eq 'worker' })
)
$displayLabelById = @{}
$threeDigitById = @{}
$agentByDisplayName = @{}
foreach ($entry in $orderedAgents) {
    $num3 = '{0:D3}' -f [int]([regex]::Match([string]$entry.filename, '^\d+').Value)
    $threeDigitById[$entry.id] = $num3
    $displayLabelById[$entry.id] = "$num3 - $($entry.displayName)"
    $agentByDisplayName[$entry.displayName] = $entry
}

# =====================================================================
# Agent knowledge catalog -- what makes each agent a specialist.
# Skill refs are workspace-relative paths resolved at install time (the clone
# already exists at this point in a normal run). A missing path is emitted with
# a "re-discover by keyword" hint instead of being dropped, so renamed upstream
# folders - and emit mode, which never clones - degrade gracefully.
# =====================================================================
$bt = [string][char]96
$PS = 'power-platform-skills/plugins'
$CSP = 'copilot-studio-plugin'
$CS = '.github/skills'
$AD = '.github/agent-docs'

$agentKnowledge = @{
    'power-platform-master' = @{
        skills = @(
            @{ ref = "$AD/starting-flow.md"; why = 'session startup (once): status script, sign-in / environment only if missing' },
            @{ ref = "$AD/working-flow-reference.md"; why = 'team protocol, routing map, WORK ORDER / WORK RESULT, approval tokens, capabilities' },
            @{ ref = "$AD/Get-SessionStatus.ps1"; why = 'the one-call status script you run at startup' }
        )
        playbook = @(
            'Run the starting flow once, then act on the request in the same turn.',
            'Classify: artifact(s), department(s), offline / live, destructive / Production / shared-environment elements.',
            'Cross-type or design change -> dispatch 001 Solution Architect first for a PLAN; otherwise go straight to the owning Team Lead.',
            'Write one WORK ORDER per Team Lead; independent Leads may run in parallel.',
            'Relay NEEDS APPROVAL / NEEDS INPUT to the user verbatim, get the answer, re-dispatch the same Lead with it.',
            'Two or more artifacts changed, a shared environment touched, or any Production import -> dispatch 002 QA before answering.',
            'Consolidate: what changed, where, validation evidence, risks, open decisions. Keep the session ledger.'
        )
        validate = @('Every Lead result contains validation evidence; never report success from a result that lacks it.', 'One writer per artifact across all dispatched Leads.')
        tools = @('agent (dispatch) is your primary tool; read/search only to classify; execute only for the status script and the Phase 2 pac auth / pac org commands.')
        avoid = @('Editing, packing, importing or live-editing any Power Platform artifact yourself.', 'Menus, dropdown-switch instructions, or re-running startup mid-session.', 'Dispatching the Architect for single-team, single-artifact work.', 'Pulling every solution in an environment (SYNC is gated).')
    }
    'solution-architect' = @{
        skills = @(
            @{ ref = "$AD/working-flow-reference.md"; why = 'team protocol, two authoring models, promotion path' },
            @{ ref = "$PS/power-pages/skills/plan-alm"; why = 'worked example of ALM / environment promotion planning (written for Pages sites - take the pattern, not the Pages-specific steps; the generic pac path is in working-flow-reference.md)' },
            @{ ref = "$PS/canvas-apps/skills/canvas-app"; why = 'what canvas authoring can and cannot do (plan realistically)' },
            @{ ref = "$PS/power-automate/references/definition-reference.md"; why = 'flow definition shape and connection references' },
            @{ ref = "$PS/model-apps/skills/app-builder"; why = 'model-driven app / Dataverse schema design' },
            @{ ref = "$PS/code-apps/skills/create-code-app"; why = 'when a code app is the right component' },
            @{ ref = "$CS/pbi-powerapps-integration/SKILL.md"; why = 'Power BI-embedded app constraints (1000 rows, DirectQuery refresh, repoint per branch)' }
        )
        playbook = @(
            'Inspect the affected solution(s) and dependencies (connection references, environment variables, Dataverse tables, managed vs unmanaged) before proposing anything.',
            'Produce a PLAN: ordered steps, one owning Team Lead per step, artifact paths, the SKILL.md each step follows, validation per step, rollback per step, open decisions for the user.',
            'Name the risks explicitly: breaking formulas, connection ownership, solution layering, shared-environment exposure, Production.',
            'When a Team Lead consults you mid-work, answer only the design question asked and return control.'
        )
        validate = @('Every step in the PLAN has an owner, an artifact, a skill, a validation and a rollback.', 'No step asks two Team Leads to write the same artifact.')
        tools = @('read/search only, plus microsoft-learn for current Microsoft guidance. You never edit artifacts and never run state-changing commands.', 'You may dispatch Team Leads only when the Master explicitly says `run the plan`; otherwise return the PLAN.')
        avoid = @('Implementing anything yourself.', 'Plans without rollback.', 'Assuming environment names or URLs - use the ones in the WORK ORDER context.')
    }
    'integration-qa-change-controller' = @{
        skills = @(
            @{ ref = "$AD/working-flow-reference.md"; why = 'approval tokens, Production gate, promotion path' },
            @{ ref = "$PS/power-pages/skills/security-review"; why = 'security review checklist (apply the mindset to every component)' },
            @{ ref = "$PS/power-pages/skills/audit-permissions"; why = 'table-permission / access audit' },
            @{ ref = "$PS/canvas-apps/references/QAChecks.md"; why = 'canvas screen QA checks a builder must have run' },
            @{ ref = "$PS/power-pages/references/approval-gates.md"; why = 'gate patterns before deployment' }
        )
        playbook = @(
            'Collect the WORK RESULTs of every team involved; list all changed artifacts.',
            'git status / git diff: exactly what changed; no raw .zip committed; no vendor files edited.',
            'Cross-references: formulas vs renamed / deleted controls, connection references, environment variables, solution dependencies, managed vs unmanaged.',
            'Auth + environment alignment: pac auth list / pac org who match the WORK ORDER; nothing targeted Production without `confirm push to prod`.',
            'Security and privacy: no secrets; no hardcoded environment identifiers outside an explicit repoint task.',
            'Return ACCEPT / ACCEPT WITH RISKS / REJECT with the exact defects and the owning Team Lead for each.'
        )
        validate = @('Every changed artifact has evidence; every defect names an owner.')
        tools = @('read/search/execute for read-only checks (git diff, pac solution pack to a temp path, pac org who). Never edit artifacts.')
        avoid = @('Fixing defects yourself - send them back to the owning team.', 'Accepting results that only claim success without evidence.')
    }
    'workspace-maintainer' = @{
        skills = @(
            @{ ref = "$AD/Get-SessionStatus.ps1"; why = 'one-call health / freshness check (also self-registers new skill folders)' },
            @{ ref = "$PS/canvas-apps/skills/configure-canvas-mcp"; why = 'canvas-authoring MCP configuration and troubleshooting' },
            @{ ref = "$PS/power-automate/skills/setup"; why = 'FlowAgent MCP prerequisites (Node.js, az login)' },
            @{ ref = "$CS/pbi-powerapps-integration/SKILL.md"; why = 'the custom skill you keep current (source of truth is the installer)' }
        )
        playbook = @(
            'Run the status script first; it tells you freshness, registrations, nested dispatch and tool availability.',
            'Light maintenance: mirror both vendor clones (power-platform-skills, copilot-studio-plugin) from upstream (stash-then-reset), re-register skill folders, refresh tool-status.json.',
            'Deep maintenance: light + `-VerifyRoot` drift report, mcp.json / settings.json check, worker-wrapper freshness (re-run the installer when Microsoft added or removed workers).',
            'Explain the authoritative-overwrite contract; steer user edits into NEW files under .github/.'
        )
        validate = @('After a refresh: `git -C power-platform-skills status` and `git -C copilot-studio-plugin status` are clean and each HEAD equals its origin/HEAD.', 'settings.json still parses and contains chat.subagents.allowInvocationsFromSubagents = true.')
        tools = @('execute for git / pac / dnx / node / az probes; edit only for .vscode/*, .github/skills/* and .github/agent-docs/tool-status.json.')
        avoid = @('Editing user solution source or the vendor clone.', 'Softening the installer contract.', 'Hand-editing the generated *-sub-*.agent.md wrappers.')
    }
    'canvas-apps-lead' = @{
        skills = @(
            @{ ref = "$CS/pbi-powerapps-integration/SKILL.md"; why = 'house skill: Power BI-embedded apps, stale schema, compile_canvas false positives, cross-environment repoint' },
            @{ ref = "$PS/canvas-apps/skills/canvas-app"; why = 'THE create / edit workflow: working directory, sync_canvas, planner -> builders in waves of 3, compile convergence' },
            @{ ref = "$PS/canvas-apps/skills/add-data-source"; why = 'adding a data source / connector via Studio' },
            @{ ref = "$PS/canvas-apps/skills/configure-canvas-mcp"; why = 'when the canvas-authoring MCP is not connecting' },
            @{ ref = "$PS/canvas-apps/references/YamlSyntax.md"; why = '.pa.yaml structure and parse-error triage' },
            @{ ref = "$PS/canvas-apps/references/PowerFxGuide.md"; why = 'Power Fx state, events, named formulas' },
            @{ ref = "$PS/canvas-apps/references/ControlGuide.md"; why = 'control selection and per-control properties' }
        )
        playbook = @(
            'Live (Studio open, coauthoring on): connect -> sync_canvas into a working folder -> follow canvas-app SKILL.md (planner, builders, compile) -> compile_canvas commits.',
            'Offline (source-controlled): pull the solution, edit the unpacked .pa.yaml with the same guides, pack + import with the environment token.',
            'Power BI-embedded app: read the custom skill first; PowerBIIntegration errors during live authoring are expected and clear on relaunch from the Service.',
            'Repoint task (dev/stage/prod visual ids): follow the custom skill phases exactly; confirm DEV ids with the user before editing.'
        )
        validate = @('compile_canvas clean on the controls you touched (ignore PowerBIIntegration false positives); every builder returned a complete QA line.', 'git diff shows only the intended screens / controls.')
        tools = @('canvas-authoring MCP (live) -> pac solution export/unpack/pack/import (offline). microsoft-learn for current guidance.')
        avoid = @('Deleting PowerBIIntegration references to "fix" red formulas.', 'Dispatching more than three builders at once.', 'Telling the user a capability does not exist before confirming a live session.')
    }
    'power-automate-lead' = @{
        skills = @(
            @{ ref = "$PS/power-automate/skills/build-flow"; why = 'autonomous flow build from a description' },
            @{ ref = "$PS/power-automate/skills/create-flow"; why = 'guided flow creation' },
            @{ ref = "$PS/power-automate/skills/debug-flow"; why = 'failed run troubleshooting' },
            @{ ref = "$PS/power-automate/skills/diagnose-flow"; why = 'deep autonomous diagnosis of a run' },
            @{ ref = "$PS/power-automate/skills/manage-flows"; why = 'publish / test / batch / inventory' },
            @{ ref = "$PS/power-automate/skills/browse-flows"; why = 'list environments and flows' },
            @{ ref = "$PS/power-automate/skills/manage-desktop-flows"; why = 'desktop (RPA) flows and machine groups' },
            @{ ref = "$PS/power-automate/skills/route-environments"; why = 'environment routing / default environment' },
            @{ ref = "$PS/power-automate/references/definition-reference.md"; why = 'flow definition JSON shape' },
            @{ ref = "$PS/power-automate/references/connection-patterns.md"; why = 'connections and connection references' },
            @{ ref = "$PS/power-automate/references/error-troubleshooting.md"; why = 'common errors and fixes' }
        )
        playbook = @(
            'Live: probe the flow-agent MCP with one cheap call (browse); if callable, follow the matching SKILL.md; if not, say so and fall back.',
            'Offline: pull the solution, edit the unpacked Workflows/*.json with definition-reference.md, pack + import with the environment token.',
            'Always confirm the target environment; flows carry connection references that differ per environment.'
        )
        validate = @('A test run (or pac solution pack) succeeds; the run / diff is what was asked.', 'Connection references resolve in the target environment.')
        tools = @('flow-agent MCP (needs Node.js + az login) -> pac solution export/unpack/pack/import. microsoft-learn for current guidance.')
        avoid = @('Publishing a flow into a shared environment without the token.', 'Editing connection references by hand without checking the target environment.')
    }
    'power-pages-lead' = @{
        skills = @(
            @{ ref = "$PS/power-pages/skills/create-site"; why = 'new site / code site scaffold' },
            @{ ref = "$PS/power-pages/skills/setup-datamodel"; why = 'Dataverse data model for the site' },
            @{ ref = "$PS/power-pages/skills/setup-auth"; why = 'authentication providers' },
            @{ ref = "$PS/power-pages/skills/create-webroles"; why = 'web roles and table permissions' },
            @{ ref = "$PS/power-pages/skills/integrate-webapi"; why = 'Web API integration' },
            @{ ref = "$PS/power-pages/skills/add-server-logic"; why = 'server-side logic' },
            @{ ref = "$PS/power-pages/skills/deploy-site"; why = 'upload / deploy' },
            @{ ref = "$PS/power-pages/skills/test-site"; why = 'site testing' },
            @{ ref = "$PS/power-pages/skills/security-review"; why = 'security review before deploy' },
            @{ ref = "$PS/power-pages/references/framework-conventions.md"; why = 'React / Angular / Vue / Astro conventions' }
        )
        playbook = @(
            'Follow the SKILL.md for the exact task; site work is mostly its own CLI flow (pac pages), not solution pack / import.',
            'Run security-review and audit-permissions before any deploy to a shared environment.',
            'Dispatch Microsoft''s Pages workers (data model, table permissions, Web API) one artifact each.'
        )
        validate = @('Build succeeds; test-site checks pass; permissions audited.')
        tools = @('pac pages / the plugin CLI flow -> pac solution for solution-bound pieces. microsoft-learn for current guidance.')
        avoid = @('Deploying to a shared environment without the token.', 'Skipping the security review.')
    }
    'code-apps-lead' = @{
        skills = @(
            @{ ref = "$PS/code-apps/skills/create-code-app"; why = 'React + Vite + TypeScript scaffold and SDK wiring' },
            @{ ref = "$PS/code-apps/skills/add-datasource"; why = 'routes to the right connector skill' },
            @{ ref = "$PS/code-apps/skills/add-dataverse"; why = 'Dataverse tables with generated models / services' },
            @{ ref = "$PS/code-apps/skills/add-connector"; why = 'generic connector fallback' },
            @{ ref = "$PS/code-apps/skills/list-connections"; why = 'connection IDs in the current environment' },
            @{ ref = "$PS/code-apps/skills/deploy"; why = 'build + deploy to Power Platform' }
        )
        playbook = @(
            'Scaffold or open the project as create-code-app says; run the app locally before deploying.',
            'Add data via the specific add-* skill; confirm connection IDs with list-connections.',
            'Deploy only with the environment token.'
        )
        validate = @('npm run build succeeds; TypeScript compiles; the deployed app opens.')
        tools = @('npm / Vite + the Power Apps CLI installed by the template (`@microsoft/power-apps-cli`): resolve `pa` vs `power-apps` per code-apps/shared/cli-binary.md and ALWAYS call it as `npx --no-install pa ...` from the project folder (never bare `npx pa`). Needs Node.js 22+ (the installer only guarantees 18+ for the flow MCP - check `node --version` first). microsoft-learn for current guidance.')
        avoid = @('Deploying to a shared environment without the token.', 'Committing node_modules or .env.', 'Guessing a CLI verb - `pa` and `power-apps` have different verb paths; use the mapping table.')
    }
    'model-apps-lead' = @{
        skills = @(
            @{ ref = "$PS/model-apps/skills/app-builder"; why = 'model-driven app from intent: tables, columns, relationships, forms, views, sitemap' },
            @{ ref = "$PS/model-apps/skills/genpage"; why = 'generative pages (React v17 + Fluent UI v9)' },
            @{ ref = "$PS/model-apps/references/authoring-flow.md"; why = 'the genpage authoring loop' },
            @{ ref = "$PS/model-apps/references/rules.md"; why = 'hard rules for generated pages' },
            @{ ref = "$PS/model-apps/references/troubleshooting.md"; why = 'common genpage failures' }
        )
        playbook = @(
            'Schema changes (tables / columns) are destructive-adjacent: list them and get the token before applying to a shared environment.',
            'Generative pages: follow genpage SKILL.md and dispatch Microsoft''s genpage planner / builders one page each.',
            'Solution-bound components (forms, views, sitemap): pull, edit the unpacked XML per the SKILL.md, pack + import.'
        )
        validate = @('Page builds and deploys; solution pack succeeds; the app opens with the expected form / view.')
        tools = @('plugin CLI flow for genpage -> pac solution export/unpack/pack/import for forms / views / sitemap. microsoft-learn for current guidance.')
        avoid = @('Dropping a column or table without `APPROVED:DELETE:<table.column>`.', 'Importing into a shared environment without the token.')
    }
    'mobile-apps-lead' = @{
        skills = @(
            @{ ref = "$PS/mobile-apps/skills/create-mobile-app"; why = 'new Expo / React Native app' },
            @{ ref = "$PS/mobile-apps/skills/edit-app"; why = 'iterate on a generated app' },
            @{ ref = "$PS/mobile-apps/skills/setup-datamodel"; why = 'Dataverse schema and connector plan' },
            @{ ref = "$PS/mobile-apps/skills/add-dataverse"; why = 'Dataverse tables in the app' },
            @{ ref = "$PS/mobile-apps/skills/setup-offline-profile"; why = 'Mobile Offline Profile design' },
            @{ ref = "$PS/mobile-apps/skills/add-native"; why = 'camera, scanner, files and other native capabilities' },
            @{ ref = "$PS/mobile-apps/skills/deploy"; why = 'publish to the tenant' },
            @{ ref = "$PS/mobile-apps/skills/debug-app"; why = 'monitor a running app for errors' },
            @{ ref = "$PS/power-apps-mobile-extension/skills/generate-ppmplugin"; why = 'end-to-end .ppmplugin native extension build (the recommended entry point)' },
            @{ ref = "$PS/power-apps-mobile-extension/skills/design-native-extension-feature"; why = 'PRD + ARCHITECTURE before any native code' }
        )
        playbook = @(
            'Apps: follow create-mobile-app / edit-app; dispatch Microsoft''s mobile workers (planner, screen builder, data model, offline profile) one artifact each.',
            'Offline profiles change what syncs to devices - preview the scope and get the token before assigning users.',
            'Native extensions (.ppmplugin): design first, then generate, build, assemble, audit, in the order the extension skills define. Some steps need JDK / Android SDK / Xcode - check tool-status.json and say what is missing.'
        )
        validate = @('npm run dev starts clean; preview-screens renders; for a deploy task the deploy skill''s own verification passes (both platform bundles present); for extensions the audit skill reports no CRITICAL findings. Deploying is NOT part of validating an edit.')
        tools = @('Expo / npm (Node.js 22+, npm 10+ per mobile-apps/shared/version-check.md - the installer only guarantees Node 18+) / pac; JDK + Android SDK / Xcode for native binaries. microsoft-learn for current guidance.')
        avoid = @('Assigning an offline profile to users without the token.', 'Shipping an unaudited .ppmplugin.')
    }
    'mcp-apps-lead' = @{
        skills = @(
            @{ ref = "$PS/mcp-apps/skills/generate-mcp-app-ui"; why = 'MCP App widget (self-contained HTML) for a tool' },
            @{ ref = "$PS/mcp-apps/references/mcp-apps-reference.md"; why = 'MCP Apps spec and constraints' },
            @{ ref = "$PS/mcp-apps/references/design-guidelines.md"; why = 'visual guidelines' }
        )
        playbook = @('Get the tool''s test output from the user (NEEDS INPUT if missing), then follow generate-mcp-app-ui. The skill supports two runtime modes - bundled code or user-approved public CDN imports; carry the user''s CDN policy into the WORK ORDER, and if none was given let the skill ask (return NEEDS INPUT).')
        validate = @('The widget renders the sample payload; it is a single self-contained .html; network imports exist only when the user approved the CDN policy.')
        tools = @('read/search/edit; microsoft-learn for current guidance.')
        avoid = @('Inventing tool schemas the user did not provide.')
    }
    'solution-alm-environments-lead' = @{
        skills = @(
            @{ ref = 'scripts/pac-workflows.ps1'; why = 'THE pull / push / init helper for any solution: verifies the target, enforces the Production gate, commits only the solution folder' },
            @{ ref = "$AD/working-flow-reference.md"; why = 'PULL / PUSH / SYNC / COMPARE / NEW capabilities, the generic pac commands and their tokens (authoritative for non-Pages solutions)' },
            @{ ref = "$PS/power-pages/skills/export-solution"; why = 'Pages-flavoured export walkthrough - reuse the pre-checks, ignore the site-specific steps' },
            @{ ref = "$PS/power-pages/skills/import-solution"; why = 'Pages-flavoured import walkthrough and pre-checks (same caveat)' },
            @{ ref = "$PS/power-pages/skills/setup-solution"; why = 'publisher / solution setup example' },
            @{ ref = "$PS/power-pages/skills/plan-alm"; why = 'environment strategy and promotion example' },
            @{ ref = "$PS/power-pages/skills/setup-pipeline"; why = 'Power Platform pipelines host and setup' },
            @{ ref = "$PS/power-pages/skills/deploy-pipeline"; why = 'running a deployment pipeline' },
            @{ ref = "$PS/power-pages/skills/diagnose-deployment"; why = 'deployment failure diagnosis' },
            @{ ref = "$PS/power-pages/references/deployment-error-catalog.md"; why = 'import / deployment error catalog (pac errors are the same for every solution type)' }
        )
        playbook = @(
            'Always `pac auth list` + `pac org who` first; state the environment you are about to touch.',
            'Prefer `scripts/pac-workflows.ps1` for pull / push / init: it verifies the active org against the label (environments.json or -EnvironmentUrl), refuses unmapped targets, enforces -ConfirmProd, verifies the import by unique name and commits only the solution folder. Map labels once in `.github/agent-docs/environments.json` (`{ "DEV": { "url": "https://...", "production": false } }`).',
            'PULL: export -> unpack into <Env>/<Solution>/; overwrite of local edits needs `APPROVED:OVERWRITE:<env>/<solution>`.',
            'PUSH: pack -> import; TEST/UAT needs `APPROVED:IMPORT:<env>/<solution>`; Production needs the user''s literal `confirm push to prod` AND a QA VERDICT of ACCEPT.',
            'SYNC: filter out managed and Microsoft / system publishers, show the list, pull only what the user picked (`APPROVED:SYNC:<env>` for more than one).',
            'COMPARE: pull the same solution from two environments and diff the unpacked folders.',
            'Never commit raw .zip; unmanaged for dev work, managed for production deployments.'
        )
        validate = @('pac solution pack / import exit 0; `pac solution list` shows the new version in the target; git diff is only the intended solution.')
        tools = @('pac solution / pac org / pac auth (exact path from tool-status.json); scripts/pac-workflows.ps1. microsoft-learn for current guidance.')
        avoid = @('Importing anywhere without the matching token.', 'Pulling every solution in an environment.', 'Switching the active pac profile without restoring it.')
    }
    'copilot-studio-lead' = @{
        skills = @(
            @{ ref = "$CSP/skills/create-agent"; why = 'new MCS2 agent + PAC-connected workspace (`pac copilot init`), instructions-only or guided design' },
            @{ ref = "$CSP/skills/clone-agent"; why = 'bring an existing cloud agent into a local workspace (`pac copilot clone`)' },
            @{ ref = "$CSP/skills/pull-agent"; why = 'sync remote changes into the workspace before editing' },
            @{ ref = "$CSP/skills/push-agent"; why = 'pull-before-push upload of local YAML changes' },
            @{ ref = "$CSP/skills/publish-agent"; why = 'make the cloud draft live - needs the token' },
            @{ ref = "$CSP/skills/delete-agent"; why = 'destructive - needs `APPROVED:DELETE:<agent>`' },
            @{ ref = "$CSP/skills/add-knowledge"; why = 'knowledge sources (SharePoint, websites, uploaded files)' },
            @{ ref = "$CSP/skills/add-skill"; why = 'inline / uploaded agent skills under behaviors/' },
            @{ ref = "$CSP/reference/knowledge-schema.md"; why = 'authoritative knowledge-source YAML schema' },
            @{ ref = "$CSP/reference/skill-schema.md"; why = 'authoritative skill YAML schema' }
        )
        playbook = @(
            'The unit of work is an MCS2 agent workspace (settings.mcs.yml, agent.sync.yaml, behaviors/, capabilities/, infrastructure/, .mcs/). Resolve it first (project dir or its .mcs/conn.json); never hand-edit .mcs/.',
            'New agent from a description: dispatch Microsoft''s Copilot Studio Architect worker with the initialized project dir + behaviour description; it writes the YAML and never packs or publishes. Migrating a classic agent: Describer first (behaviour report), then Architect.',
            'ALM (list / pull / push / publish / delete): follow the matching SKILL.md step by step (the Manage worker routes to them). Push is pull-before-push; a no-op push is not publish readiness.',
            'Publish makes the agent live for its users -> treat as a shared-environment action: `APPROVED:PUBLISH:<agent>@<env>`. Delete -> `APPROVED:DELETE:<agent>`. Production environments keep `confirm push to prod`.',
            'Every authored *.mcs.yml must follow its schema and carry mcs.metadata; validate against reference/*.md before pushing. Review `git diff` of the workspace and say what changed.',
            'Needs pac CLI 2.9.3+ with `pac copilot` (check `pac copilot init --help`); the environment is an ID or Dataverse URL - never silently the active profile''s default.'
        )
        validate = @('`pac copilot push` succeeds and the final `pac copilot pull` leaves the workspace clean; every new component has mcs.metadata and a schema-valid shape; no `.mcs/` edits; publish ran only with the token.')
        tools = @('pac copilot (init / clone / pull / push / publish / delete / list) via the exact pac path in tool-status.json; read/search/edit for the YAML workspace. microsoft-learn for current Copilot Studio guidance.')
        avoid = @('Publishing or deleting without the literal token.', 'Running `pac copilot publish` from the create flow (the publish skill owns the confirmation).', 'Editing `.mcs/` or `agent.sync.yaml` by hand.', 'Inventing connector / tool metadata the user did not provide.')
    }
}

# Keyword hints per agent for auto-discovering NEW upstream skills (name hit = 2,
# description hit = 1; threshold 2) so Microsoft additions attach on the next run
# without a catalog edit. Matching is SCOPED: a Lead only sees skills from its own
# plugins ($agentSkillScope), so a keyword like 'dataverse' or 'deploy' cannot pull
# another team's skill into its list. Executives see every plugin (advisory reads).
$agentSkillKeywords = @{
    'solution-architect'              = @('plan', 'alm', 'setup-solution', 'datamodel', 'architecture')
    'integration-qa-change-controller'= @('security', 'audit', 'scan', 'permissions', 'test', 'diagnose')
    'workspace-maintainer'            = @('setup', 'configure', 'mcp', 'check-updates', 'report-issue', 'telemetry')
    'canvas-apps-lead'                = @('canvas', 'data-source', 'mcp')
    'power-automate-lead'             = @('flow', 'flows', 'desktop', 'environments', 'automate')
    'power-pages-lead'                = @('site', 'pages', 'webapi', 'webroles', 'seo', 'firewall', 'headers', 'bootstrap', 'auth', 'server-logic', 'cloud-flow', 'env-variables')
    'code-apps-lead'                  = @('code-app', 'code app', 'connector', 'dataverse', 'sharepoint', 'teams', 'office365', 'onedrive', 'excel', 'azuredevops', 'workiq', 'mcscopilot', 'connections')
    'model-apps-lead'                 = @('model-driven', 'genpage', 'generative', 'app-builder', 'forms', 'views', 'sitemap')
    'mobile-apps-lead'                = @('mobile', 'offline', 'native', 'expo', 'wrap', 'ppmplugin', 'pcf', 'android', 'ios', 'design-system', 'preview', 'sample-data', 'app-registration', 'app-insights')
    'mcp-apps-lead'                   = @('mcp app', 'mcp-app', 'widget')
    'solution-alm-environments-lead'  = @('solution', 'export', 'import', 'pipeline', 'deploy', 'alm', 'environment', 'publisher')
    'copilot-studio-lead'             = @('copilot studio', 'copilot-studio', 'mcs', 'agent', 'knowledge', 'publish', 'clone', 'pull', 'push', 'topic', 'evaluation')
}
# Plugin scope per agent (plugin ids from Get-PluginRoots). Leads default to their
# manifest primarySkills; the ALM Lead draws on the Pages ALM skills; executives are
# unscoped. The scope is what keeps a broad keyword like 'agent' inside its own vendor.
$agentSkillScope = @{
    'solution-alm-environments-lead' = @('power-pages')
}
foreach ($la in $agentManifest.agents) {
    if ($la.level -eq 'team-lead' -and -not $agentSkillScope.ContainsKey($la.id)) {
        $sc = @($la.primarySkills | Where-Object { $_ })
        if ($sc.Count -gt 0) { $agentSkillScope[$la.id] = $sc }
    }
}

# Index every upstream skill once (folder, name, description) for keyword matching.
$pluginRoots = Get-PluginRoots $rootPath
$upstreamSkillIndex = @()
foreach ($containerRel in @(Get-SkillContainerDirs -RootPath $rootPath -SearchSubPaths $vendorSkillSearchPaths)) {
    $containerFull = Join-Path $rootPath ($containerRel -replace '/', '\')
    # Plugin id = the plugin root this container sits under (longest match wins).
    $pluginName = $null
    foreach ($plid in @($pluginRoots.Keys | Sort-Object { $pluginRoots[$_].Length } -Descending)) {
        if ($containerRel -eq $pluginRoots[$plid] -or $containerRel.StartsWith("$($pluginRoots[$plid])/")) { $pluginName = $plid; break }
    }
    if (-not $pluginName) { $pluginName = ($containerRel -split '/')[0] }
    Get-ChildItem -LiteralPath $containerFull -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $skillFile = Join-Path $_.FullName 'SKILL.md'
        if (-not (Test-Path -LiteralPath $skillFile)) { return }
        $head = (Get-Content -LiteralPath $skillFile -TotalCount 40 -ErrorAction SilentlyContinue) -join "`n"
        $fm = [regex]::Match($head, '(?s)^---\s*\n(.*?)\n---')
        $fmText = if ($fm.Success) { $fm.Groups[1].Value } else { '' }
        $nameM = [regex]::Match($fmText, '(?m)^name:\s*["'']?([^\r\n"'']+)')
        $descM = [regex]::Match($fmText, '(?s)description:\s*[>|]?-?\s*["'']?(.*?)(?=\n[A-Za-z_-]+:|\z)')
        $desc = if ($descM.Success) { ($descM.Groups[1].Value -replace '\s+', ' ').Trim().Trim('"', "'") } else { '' }
        $fullDesc = $desc
        if ($desc.Length -gt 160) { $desc = $desc.Substring(0, 160).TrimEnd() + '...' }
        $upstreamSkillIndex += [pscustomobject]@{
            rel     = "$containerRel/$($_.Name)"
            plugin  = $pluginName
            name    = if ($nameM.Success) { $nameM.Groups[1].Value.Trim() } else { $_.Name }
            desc    = $desc
            nameHay = ("$($_.Name) " + $(if ($nameM.Success) { $nameM.Groups[1].Value } else { '' })).ToLowerInvariant()
            descHay = $fullDesc.ToLowerInvariant()
        }
    }
}
if ($upstreamSkillIndex.Count -gt 0) { Write-Host "  Indexed $($upstreamSkillIndex.Count) upstream skills for keyword mapping." -ForegroundColor DarkGray }

function Get-AutoDiscoveredSkills {
    param([string]$AgentId, [string[]]$AlreadyPinned, [int]$Max = 6, [int]$MinScore = 2)
    if (-not $agentSkillKeywords.ContainsKey($AgentId) -or $upstreamSkillIndex.Count -eq 0) { return @() }
    $hits = @()
    $scope = if ($agentSkillScope.ContainsKey($AgentId)) { @($agentSkillScope[$AgentId]) } else { @() }
    foreach ($skill in $upstreamSkillIndex) {
        if ($AlreadyPinned -contains $skill.rel) { continue }
        if ($scope.Count -gt 0 -and ($scope -notcontains $skill.plugin)) { continue }
        if ($skill.rel -match '/(report-issue|telemetry)$' -and $AgentId -ne 'workspace-maintainer') { continue }
        $matched = @(); $score = 0
        foreach ($kw in $agentSkillKeywords[$AgentId]) {
            $k = $kw.ToLowerInvariant().Trim()
            $pattern = '(?<![a-z0-9])' + [regex]::Escape($k)
            if ($skill.nameHay -match $pattern) { $score += 2; $matched += $kw }
            elseif ($skill.descHay -match $pattern) { $score += 1; $matched += $kw }
        }
        if ($score -ge $MinScore) { $hits += [pscustomobject]@{ skill = $skill; score = $score; matched = $matched } }
    }
    return @($hits | Sort-Object -Property @{Expression='score';Descending=$true}, @{Expression={$_.skill.rel};Descending=$false} | Select-Object -First $Max)
}

function Resolve-KnowledgeRef {
    param([string]$Rel)
    # Installer-managed files are written in this same run, so treat them as present.
    if ($Rel -like '.github/agent-docs/*' -or $Rel -like '.github/skills/*' -or $Rel -eq 'scripts/pac-workflows.ps1') { return "$bt$Rel$bt" }
    $full = Join-Path $rootPath ($Rel -replace '/', '\')
    if (Test-Path -LiteralPath $full) { return "$bt$Rel$bt" }
    # Self-heal upstream renames: a sibling folder sharing the leading token of the missing one.
    $leaf = Split-Path $Rel -Leaf
    $parentRel = ($Rel -replace '/[^/]+$', '')
    $parentFull = Join-Path $rootPath ($parentRel -replace '/', '\')
    if (Test-Path -LiteralPath $parentFull) {
        $stem = ($leaf -split '[-.]')[0]
        $candidates = @(Get-ChildItem -LiteralPath $parentFull -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "$stem*" -and ($_.PSIsContainer -eq $false -or (Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md'))) } |
            Sort-Object { $_.Name.Length } | Select-Object -First 1)
        if ($candidates.Count -eq 1) {
            return "$bt$parentRel/$($candidates[0].Name)$bt *(upstream renamed $bt$leaf$bt - resolved at install time)*"
        }
    }
    return "$bt$Rel$bt *(not present at install time - re-discover by keyword $bt$leaf$bt)*"
}

function New-KnowledgeSection {
    param($Agent, $Knowledge)
    if (-not $Knowledge) { return '' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('## Knowledge and skills')
    [void]$sb.AppendLine('')
    $artifacts = @($Agent.artifactTypes) | Where-Object { $_ }
    if ($artifacts.Count -gt 0) { [void]$sb.AppendLine("Artifacts you own: $($artifacts -join ', ').") }
    $writePerm = if (@($Agent.tools) -contains 'edit') { 'edit files inside your owned artifact paths' }
        elseif (@($Agent.tools) -contains 'execute') { 'run commands / CLI; no file edits' }
        else { 'read-only (analysis, plans, reports)' }
    [void]$sb.AppendLine("Write permission: $writePerm.")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Start from these (custom skills win on style, upstream skills win on syntax/spec). Read the SKILL.md that owns the task first; open its references only for the step you are on and honour its own "read X only if Y" conditions - do not pre-load the whole list:')
    foreach ($s in @($Knowledge.skills)) { [void]$sb.AppendLine("- $(Resolve-KnowledgeRef $s.ref) - $($s.why)") }
    $pinned = @(@($Knowledge.skills) | ForEach-Object { [string]$_.ref })
    $auto = @(Get-AutoDiscoveredSkills -AgentId $Agent.id -AlreadyPinned $pinned)
    if ($auto.Count -gt 0) {
        [void]$sb.AppendLine('')
        [void]$sb.AppendLine('Also relevant - auto-discovered from the upstream skill catalog at install time (re-running the installer refreshes this list):')
        foreach ($h in $auto) {
            $descText = if ($h.skill.desc) { " - $($h.skill.desc)" } else { '' }
            [void]$sb.AppendLine("- $bt$($h.skill.rel)$bt$descText *(matched: $($h.matched -join ', '))*")
        }
    }
    if ($Knowledge.playbook) {
        [void]$sb.AppendLine(''); [void]$sb.AppendLine('## Playbook'); [void]$sb.AppendLine('')
        $i = 0; foreach ($p in @($Knowledge.playbook)) { $i++; [void]$sb.AppendLine("$i. $p") }
    }
    if ($Knowledge.validate) {
        [void]$sb.AppendLine(''); [void]$sb.AppendLine('## Validation you must run before reporting'); [void]$sb.AppendLine('')
        foreach ($v in @($Knowledge.validate)) { [void]$sb.AppendLine("- $v") }
    }
    if ($Knowledge.tools) {
        [void]$sb.AppendLine(''); [void]$sb.AppendLine('## Tool ladder'); [void]$sb.AppendLine('')
        foreach ($t in @($Knowledge.tools)) { [void]$sb.AppendLine("- $t") }
        [void]$sb.AppendLine("- Check $bt.github/agent-docs/tool-status.json$bt first; use the recorded $bt" + 'path' + "$bt; if a tool is missing, use the next rung and say so in your result.")
    }
    if ($Knowledge.avoid) {
        [void]$sb.AppendLine(''); [void]$sb.AppendLine('## Avoid'); [void]$sb.AppendLine('')
        foreach ($a in @($Knowledge.avoid)) { [void]$sb.AppendLine("- $a") }
    }
    return $sb.ToString().TrimEnd()
}

# -- .github/copilot-instructions.md -----------------------------------
$copilotInstructionsPath = "$rootPath\.github\copilot-instructions.md"
if ($updateMode -or -not (Test-Path $copilotInstructionsPath)) {
    Write-ManagedFile $copilotInstructionsPath @'
# Copilot Workspace Instructions

This is a Power Platform development workspace driven by a hierarchy of VS Code
custom agents under `.github/agents/` (generated by the installer from its embedded
manifest; regenerated on every update).

## Agents

Select an agent from the Copilot Chat dropdown. Start with
**`000 - Power Platform Master`** unless you know exactly which specialist you
want - it runs a one-call startup, then coordinates the team (it delegates, it
does not implement).

- **000 - Power Platform Master** - single entry point; startup + routing; the only
  agent that talks to you. Has a "Run workspace maintenance" handoff button.
- **001 - Solution Architect** - cross-type design; returns a PLAN (read-only).
- **002 - Integration QA & Change Controller** - diff/pack review; returns a VERDICT;
  gates Production.
- **003 - Workspace Maintainer** - keeps skills, MCP and config healthy.
- **010-090 - Team Leads** - Canvas Apps, Power Automate, Power Pages, Code Apps,
  Model Apps, Mobile Apps, MCP Apps, Solution ALM & Environments, Copilot Studio.
- **Hidden workers (`0NN-sub-*.agent.md`)** - Microsoft's own bundled plugin agents
  (planners, screen builders, data-model architects, the Copilot Studio architect /
  describer / init / manage, ...), auto-discovered from
  `power-platform-skills/plugins/<plugin>/agents/` and `copilot-studio-plugin/agents/`
  and wired into the owning Lead. Pointer files, never forks; refreshed with the clones.

Nested delegation (Master -> Lead -> worker) requires the VS Code setting
`chat.subagents.allowInvocationsFromSubagents: true`. The installer writes it into
`.vscode/settings.json` (honoured when the folder is opened alone) and into the
`<folder>.code-workspace` it opens VS Code from (required when the folder is one root
of a multi-root window - folder settings are ignored for this window-scoped key). If
you add this folder to another multi-root window, copy the setting into that window's
`.code-workspace`. Dispatched agents cannot ask you questions: approvals and open
questions bubble up to the agent you selected as `NEEDS APPROVAL` / `NEEDS INPUT`.

See `AGENTS.md` for the full table.

## Reference docs (`.github/agent-docs/`, not in the dropdown)

- `Get-SessionStatus.ps1` - the one-call status script (skills freshness, skill
  registrations, nested dispatch, pac identity + environment, live tool re-check that
  refreshes `tool-status.json`).
- `starting-flow.md` - lean startup: one status call, sign-in / environment only if
  missing, straight to work.
- `working-flow-reference.md` - team protocol (WORK ORDER / WORK RESULT), routing map,
  approval tokens, the two authoring models, capabilities (pull / push / sync / edit /
  live canvas coauthoring / compare / status).
- `tool-status.json` - machine-specific tool inventory (gitignored). Agents read
  `<tool>.found` and prefer the recorded executable `path`.

## Skills

All skill folders are registered in `chat.agentSkillsLocations`, so agents see the
catalogue natively:

1. **Microsoft Power Platform skills** (cloned, gitignored) in
   `power-platform-skills/plugins/<plugin>/skills/<skill>/SKILL.md`, with shared
   `references/` per plugin. Plugins: canvas-apps, power-automate, power-pages,
   code-apps, model-apps, mobile-apps, power-apps-mobile-extension, mcp-apps.
2. **Microsoft Copilot Studio skills** (cloned, gitignored) in
   `copilot-studio-plugin/skills/<skill>/SKILL.md` with `reference/` schemas:
   create-agent, clone-agent, pull-agent, push-agent, publish-agent, delete-agent,
   add-knowledge, add-skill (MCS2 YAML agents via `pac copilot`). Owned by
   **090 - Copilot Studio Lead**.
3. **Custom embedded skills** (committed, house style) in `.github/skills/<name>/SKILL.md`.
   Currently `pbi-powerapps-integration` - canvas apps embedded in a Power BI report
   (`PowerBIIntegration`, stale-schema issues) and repointing Power Apps / Flow visuals
   across DevOps branches. Custom skills win on style; upstream skills win on syntax/spec.

## Workspace conventions

- Solutions are unpacked into `<EnvironmentName>/<SolutionName>/` at the root.
- `exports/` holds raw .zip exports (gitignored); `deploy/` holds packed .zip
  files for import; `scripts/pac-workflows.ps1` provides pull/push/init helpers
  (push to PROD requires `-ConfirmProd`).
- Three MCP servers (optional, start on demand): `canvas-authoring` (live canvas
  coauthoring via dnx/.NET 10), `flow-agent` (Power Automate via Node.js + az) and
  `microsoft-learn` (documentation, HTTP). Runtime availability is recorded in
  `.github/agent-docs/tool-status.json`.
- Commits follow Conventional Commits (`chore:` for pulls, `feat:` for pushes).
- Destructive or shared-environment actions need a literal token
  `APPROVED:<ACTION>:<artifact>`; **never import to Production without typing
  `confirm push to prod`.** Plain-words "do it" is not a token.
'@
    Write-Host "  $(if ($updateMode) {'Updated'} else {'Created'}) .github/copilot-instructions.md"
} else {
    Write-Host "  Exists: .github/copilot-instructions.md" -ForegroundColor DarkGray
}

# -- AGENTS.md ---------------------------------------------------------
$agentsReadmePath = "$rootPath\AGENTS.md"
if ($updateMode -or -not (Test-Path $agentsReadmePath)) {
    $agentRows = ($orderedAgents | ForEach-Object {
        "| ``$($displayLabelById[$_.id])`` | $($_.level) | $($_.focus) |"
    }) -join "`n"
    Write-ManagedFile $agentsReadmePath @"
# Power Platform - Agent Guide

## How to use this workspace

Open the ``<folder>.code-workspace`` file in VS Code (the installer does this for
you; opening the bare folder also works when it is the only root). In Copilot Chat,
select an agent from the dropdown -
start with **``000 - Power Platform Master``** unless you know which specialist you
want. Type anything to begin; the Master handles setup and delegation from there.
You never manually switch agents mid-task - the Master routes for you.

## The hierarchy

| Agent | Level | Focus |
|-------|-------|-------|
$agentRows

- **Executives** (000-003) coordinate, advise (PLAN), gate (VERDICT) and maintain.
- **Team Leads** (010-090) each own one component area, validate their own
  output, and dispatch Microsoft's bundled **workers** (hidden ``0NN-sub-*``
  agents, auto-discovered from the vendor clones) one artifact each. Delegation
  flows top-down: Master -> Architect (PLAN) or Master -> Team Lead (WORK ORDER)
  -> worker -> Lead validates -> Master consolidates (WORK RESULT). Only the agent
  you selected can ask you anything; everything else bubbles up as
  ``NEEDS APPROVAL`` / ``NEEDS INPUT``.
- Destructive or shared-environment actions need a literal token
  ``APPROVED:<ACTION>:<artifact>``; Production imports are gated on
  ``confirm push to prod``.

Definitions live in ``.github/agents/*.agent.md`` (regenerated by the installer).
Nested delegation needs ``chat.subagents.allowInvocationsFromSubagents: true``; the
installer writes it to ``.vscode/settings.json`` and to the ``<folder>.code-workspace``
it opens (the latter is what counts in a multi-root window).

## Modes (handled automatically by the Master)

**Starting mode** (`.github/agent-docs/starting-flow.md`):
one status-script call -> sign in / pick environment only if missing -> work

**Working mode** (`.github/agent-docs/working-flow-reference.md`):
team protocol (WORK ORDER / WORK RESULT), routing, approval tokens, full ALM
lifecycle using the power-platform-skills and copilot-studio-plugin skills

## Workspace structure

``````
[EnvironmentName]/
  [SolutionName]/       -> unpacked solution source (XML, JSON, YAML)
exports/                -> raw .zip exports (gitignored)
deploy/                 -> packed .zip files ready to import
scripts/                -> pac-workflows.ps1 helper script (-ConfirmProd for PROD)
power-platform-skills/  -> cloned Microsoft Power Platform skills repo (gitignored)
copilot-studio-plugin/  -> cloned Microsoft Copilot Studio plugin repo (gitignored)
.github/agents/         -> agent definitions (000-090 + hidden 0NN-sub-* workers)
.github/agent-docs/     -> Get-SessionStatus.ps1, flows, tool-status.json
.github/skills/         -> custom embedded skills (committed, house style)
.vscode/mcp.json        -> canvas-authoring + flow-agent + microsoft-learn MCP servers
``````

## Working mode commands (say these to the Master)

``````
"pull [SolutionName]"            -> export + unpack + commit
"push [SolutionName] to TEST"    -> pack + import + commit (token required)
"sync [EnvironmentName]"         -> list unmanaged, non-Microsoft solutions; pull the ones you pick
"edit [component] in [solution]" -> delegates to the owning Team Lead
"live edit [app]"                -> real-time canvas coauthoring (browser + MCP)
"new solution [name]"            -> scaffold new solution
"compare DEV and TEST"           -> diff two environments
"status"                         -> auth + solutions + git summary
"create a Copilot Studio agent"  -> 090 Copilot Studio Lead (pac copilot init / push; publish gated)
"run maintenance"                -> refresh both vendor clones + tool inventory
``````
"@
    Write-Host "  $(if ($updateMode) {'Updated'} else {'Created'}) AGENTS.md"
} else {
    Write-Host "  Exists: AGENTS.md" -ForegroundColor DarkGray
}


# -- .github/agents/*.agent.md  (manifest-driven, 12 agents) -----------
# One .agent.md per manifest entry. Filenames use the 3-digit, team-grouped
# prefix computed above so the dropdown sorts by hierarchy. Written UTF-8 without
# a BOM so the YAML front matter is the 1st byte.

# Legacy cleanup: the v0.2 single-file master agent is replaced by 000-*.
$legacyAgent = "$rootPath\.github\agents\power-platform-master-agent.agent.md"
if (Test-Path $legacyAgent) {
    Remove-Item $legacyAgent -Force
    Write-Host "  Removed legacy power-platform-master-agent.agent.md (replaced by 000-power-platform-master.agent.md)" -ForegroundColor DarkGray
}

$agentCount = 0
foreach ($agent in $orderedAgents) {
    $toolNames = @($agent.tools)
    if (-not $toolNames -or $toolNames.Count -eq 0) { $toolNames = @($agentManifest.defaults.tools) }
    if ($agent.mcpServers) { foreach ($m in $agent.mcpServers) { $toolNames += "$m/*" } }
    $toolsYaml = ConvertTo-AgentYamlList $toolNames

    $childLabels = @()
    foreach ($childName in $agent.allowedChildren) {
        if ($agentByDisplayName.ContainsKey($childName)) {
            $childLabels += $displayLabelById[$agentByDisplayName[$childName].id]
        }
    }
    $childrenYaml = ConvertTo-AgentYamlList $childLabels

    $label = $displayLabelById[$agent.id]
    $safeLabel = $label -replace "'", "''"
    $descEsc = ([string]$agent.focus) -replace "'", "''"
    $uinv = $agent.userInvocable.ToString().ToLowerInvariant()
    # Workspace maintenance is the one legitimate "switch agent" case (it may need
    # interactive install approvals): expose it as a handoff button on the Master.
    # List-valued keys stay LAST in the frontmatter (VS Code parser quirk).
    $handoffsYaml = ''
    if ($agent.id -eq 'power-platform-master' -and $displayLabelById.ContainsKey('workspace-maintainer')) {
        $maintLabel = $displayLabelById['workspace-maintainer'] -replace "'", "''"
        $handoffsYaml = "`nhandoffs:`n  - label: 'Run workspace maintenance'`n    agent: '$maintLabel'`n    prompt: 'Run light maintenance: refresh both Microsoft vendor clones (power-platform-skills, copilot-studio-plugin) to upstream, re-register skill folders, refresh the tool inventory, then report what changed.'`n    send: false"
    }
    $frontMatter = "---`nname: '$safeLabel'`ndescription: '$descEsc'`nuser-invocable: $uinv`ntools: $toolsYaml`nagents: $childrenYaml$handoffsYaml`n---`n`n"
    $body = Get-AgentBody $agent $label $childLabels
    $content = $frontMatter + $body

    $threeName = $agent.filename -replace '^\d+', $threeDigitById[$agent.id]
    $outPath = "$rootPath\.github\agents\$threeName"
    if ($updateMode -or -not (Test-Path $outPath)) {
        Write-ManagedFile $outPath $content
        $agentCount++
    }
}
Write-Host "  $(if ($updateMode) {'Updated'} else {'Created'}) $($orderedAgents.Count) agent definitions in .github/agents/"

# -- Dynamic worker sub-agent discovery ---------------------------------
# Scan each Lead's plugin(s) for Microsoft's bundled worker agents, generate one
# hidden wrapper per worker (mirroring the worker's OWN tools), wire them into the
# owning Lead's `agents:` list and `## Your team` roster, and prune wrappers for
# workers Microsoft removed. No-op when no plugins are present (emit mode / offline).
$disc = Invoke-WorkerAgentDiscovery $rootPath (Get-DiscoveryLeadDescriptors $orderedAgents $threeDigitById)
if (-not $disc.Skipped) {
    $wc = @($disc.Wrappers).Count
    if ($wc -gt 0) { Write-Host "  Wired $wc Microsoft worker sub-agent(s) into their Team Leads (hidden, auto-discovered)." -ForegroundColor Green }
    else { Write-Host "  No bundled worker agents in the current skills - Leads run their skills directly." -ForegroundColor DarkGray }
}

# -- .github/agent-docs/Get-SessionStatus.ps1 --------------------------
# One deterministic script replaces the ~8 shell probes and two blocking menus the
# Master used to run at session start. Resolves the workspace root from its own
# location (CWD-independent), self-heals skill registrations, checks the nested-
# dispatch setting, reads identity from pac, and re-checks tool-status.json live.
$sessionStatusPath = "$rootPath\.github\agent-docs\Get-SessionStatus.ps1"
if ($updateMode -or -not (Test-Path $sessionStatusPath)) {
    $sessionStatusScript = @'
# Get-SessionStatus.ps1 -- one-shot session health for the Power Platform Master.
# Run with its ABSOLUTE path (the terminal CWD is not guaranteed to be the workspace root):
#   powershell -NoProfile -ExecutionPolicy Bypass -File "<workspace>\.github\agent-docs\Get-SessionStatus.ps1"
# Prints a compact status block and refreshes .github/agent-docs/tool-status.json in place.
$ErrorActionPreference = 'SilentlyContinue'
# Workspace root = two levels above this script (.github/agent-docs/), so the CWD does not matter.
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if (-not (Test-Path -LiteralPath (Join-Path $root '.github\agents'))) { $root = (Get-Location).Path }
$out = New-Object System.Collections.Generic.List[string]
$out.Add("ROOT     $root")

function Get-RepoDate([string]$rel) {
    $p = Join-Path $root $rel
    if (-not (Test-Path -LiteralPath $p)) { return 'not installed' }
    $d = & git -C $p log -1 --format=%cd --date=format-local:"%Y-%m-%d" 2>$null
    if ($d -and $d -notmatch 'fatal') { return [string]$d }
    return 'unknown'
}
function Get-FileDate([string]$rel) {
    $p = Join-Path $root $rel
    if (Test-Path -LiteralPath $p) { return (Get-Item -LiteralPath $p).LastWriteTime.ToString('yyyy-MM-dd') }
    return 'not installed'
}
function Get-AgeDays([string]$stamp) {
    $m = [regex]::Match($stamp, '^\d{4}-\d{2}-\d{2}')
    if (-not $m.Success) { return -1 }
    return [int]((Get-Date) - [datetime]::ParseExact($m.Value, 'yyyy-MM-dd', $null)).TotalDays
}

# -- Skills freshness (every Microsoft vendor clone) --
$pbi = Get-FileDate '.github/skills/pbi-powerapps-integration/SKILL.md'
$vendorNames = @(%%VENDORS%%)
$skillSearch = @(%%VENDORSKILLDIRS%%)
$manifestPath = Join-Path $root '.github/installed-manifest.json'
$mf = $null
if (Test-Path -LiteralPath $manifestPath) { try { $mf = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json } catch { } }
$stale = $false; $moved = @(); $parts = @()
foreach ($vn in $vendorNames) {
    $vd = Get-RepoDate $vn
    $vrepo = Join-Path $root $vn
    $behind = ''
    if (Test-Path -LiteralPath $vrepo) {
        $cnt = & git -C $vrepo rev-list --count 'HEAD..origin/HEAD' 2>$null
        if ($cnt -and [int]$cnt -gt 0) { $behind = " ($cnt behind last fetch)" }
        # Agents (worker roster, skill lists) were generated from a specific clone commit; flag drift.
        $headNow = (& git -C $vrepo rev-parse HEAD 2>$null)
        $gen = $null
        if ($mf -and $mf.vendorCommits -and $mf.vendorCommits.PSObject.Properties[$vn]) { $gen = [string]$mf.vendorCommits.$vn }
        if ($headNow -and $gen -and ($gen -ne $headNow)) { $moved += "$vn ($($gen.Substring(0,7)) -> $($headNow.Substring(0,7)))" }
    }
    if ((Get-AgeDays $vd) -gt 30 -or $behind) { $stale = $true }
    $parts += "$vn $vd$behind"
}
$out.Add("SKILLS   Microsoft: $($parts -join ' | ') | custom pbi-powerapps-integration: $pbi")
if ($stale) { $out.Add("         Upstream skills are stale -> say 'run maintenance' (Workspace Maintainer refreshes the clones).") }
if ($moved.Count -gt 0) { $out.Add("         Clone moved since the agents were generated: $($moved -join '; ') -> re-run the installer so the worker roster and skill lists match.") }

# -- Registered skill locations (self-heal: register new plugin skill containers) + nested dispatch --
$settingsPath = Join-Path $root '.vscode/settings.json'
$nesting = 'unknown'
$skillLocCount = 0
$newlyRegistered = @()
if (Test-Path -LiteralPath $settingsPath) {
    try {
        $s = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        $loc = $s.'chat.agentSkillsLocations'
        if (-not $loc) { $loc = New-Object PSObject; $s | Add-Member -NotePropertyName 'chat.agentSkillsLocations' -NotePropertyValue $loc -Force }
        foreach ($sub in $skillSearch) {
            $base = Join-Path $root $sub
            if (-not (Test-Path -LiteralPath $base)) { continue }
            Get-ChildItem -LiteralPath $base -Recurse -Filter 'SKILL.md' -File | ForEach-Object {
                $c = $_.Directory.Parent; if ($null -eq $c) { return }
                $rel = $c.FullName.Substring($root.TrimEnd('\').Length).TrimStart('\').Replace('\', '/')
                if ($rel -and -not $loc.PSObject.Properties[$rel]) { $loc | Add-Member -NotePropertyName $rel -NotePropertyValue $true; $newlyRegistered += $rel }
            }
        }
        if ($newlyRegistered.Count -gt 0) { [IO.File]::WriteAllText($settingsPath, ($s | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false))) }
        $skillLocCount = @($loc.PSObject.Properties | Where-Object { $_.Value -eq $true }).Count
        $n = $s.'chat.subagents.allowInvocationsFromSubagents'
        $nesting = if ($n -eq $true) { 'enabled in .vscode/settings.json (single-root). If this folder is one root of a MULTI-ROOT window, the setting must also be in that window''s .code-workspace or user settings - the shipped <folder>.code-workspace has it' } else { 'NOT set in .vscode/settings.json -> Team Leads cannot dispatch their workers; re-run the installer' }
    } catch { }
}
$out.Add("CONFIG   Skill locations registered: $skillLocCount | Nested dispatch: $nesting")
if ($newlyRegistered.Count -gt 0) { $out.Add("         Newly registered skill folders (reload window to load them): $(($newlyRegistered | Sort-Object -Unique) -join ', ')") }

# -- Identity + environment (pac first, az fallback; never blocks, no network call) --
$identity = 'not signed in (pac auth create --deviceCode)'
$environment = 'none selected (pac org list, then pac org select --environment <url>)'
$authRaw = & pac auth list 2>&1 | Out-String
if ($authRaw -match '(?m)^\s*\[\d+\]\s*\*.*$') {
    $active = $Matches[0]
    if ($active -match '[\w.+-]+@[\w.-]+') { $identity = "pac: $($Matches[0])" } else { $identity = 'pac: active profile (no email shown)' }
    if ($active -match 'https://[^\s]+') { $environment = $Matches[0] }
} elseif ($authRaw -match '(?m)^\s*\[\d+\]') {
    $identity = 'pac: profiles exist but none active (pac auth select --index N)'
} else {
    $azJson = & az account show --output json 2>$null | Out-String
    if ($azJson -match '"name"') { try { $a = $azJson | ConvertFrom-Json; $identity = "az: $($a.user.name) (pac not signed in)" } catch { } }
}
$out.Add("IDENTITY $identity")
$out.Add("ENV      $environment")

# -- Live tool re-check + tool-status.json refresh --
$toolStatusPath = Join-Path $root '.github/agent-docs/tool-status.json'
$present = @(); $missing = @(); $changed = @()
if (Test-Path -LiteralPath $toolStatusPath) {
    try {
        $ts = Get-Content -LiteralPath $toolStatusPath -Raw | ConvertFrom-Json
        foreach ($prop in $ts.tools.PSObject.Properties) {
            $t = $prop.Value
            $ok = $false
            if ($t.path -and (Test-Path -LiteralPath $t.path)) { $ok = $true }
            elseif ($t.command) {
                $cmd = Get-Command $t.command -ErrorAction SilentlyContinue
                if ($cmd) { $ok = $true; $t.path = [string]$cmd.Source }
            }
            if ($ok -ne [bool]$t.found) { $changed += "$($prop.Name): $([bool]$t.found) -> $ok"; $t.found = $ok }
            if ($ok) { $present += $prop.Name } else { $missing += $prop.Name }
        }
        $ts | Add-Member -NotePropertyName lastSessionCheck -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) -Force
        [IO.File]::WriteAllText($toolStatusPath, ($ts | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    } catch { $out.Add("TOOLS    tool-status.json unreadable: $($_.Exception.Message)") }
    $out.Add("TOOLS    available: $($present -join ', ')")
    if ($missing.Count -gt 0) { $out.Add("         missing: $($missing -join ', ') (offline pac path still works; Workspace Maintainer can help)") }
    if ($changed.Count -gt 0) { $out.Add("         changed since install: $($changed -join '; ') -> tool-status.json refreshed") }
} else { $out.Add('TOOLS    tool-status.json not found -> re-run the installer') }

$out | ForEach-Object { Write-Output $_ }
if ($out.Count -le 1) { Write-Output 'STATUS   script ran but collected nothing - check that .vscode/settings.json and .github/agent-docs exist under ROOT' }
'@
    $sessionStatusScript = $sessionStatusScript.Replace('%%VENDORS%%', (($vendorClones | ForEach-Object { "'$($_.Name)'" }) -join ', ')).Replace('%%VENDORSKILLDIRS%%', (($vendorSkillSearchPaths | ForEach-Object { "'$_'" }) -join ', '))
    Write-ManagedFile $sessionStatusPath $sessionStatusScript
    Write-Host "  $(if ($updateMode) {'Updated'} else {'Created'}) .github/agent-docs/Get-SessionStatus.ps1"
} else {
    Write-Host "  Exists: .github/agent-docs/Get-SessionStatus.ps1" -ForegroundColor DarkGray
}

# -- .github/agent-docs/starting-flow.md --------------------------------
$startingFlowPath = "$rootPath\.github\agent-docs\starting-flow.md"
if ($updateMode -or -not (Test-Path $startingFlowPath)) {
    $startingFlowContent = (@'
# Starting Flow - Power Platform Master Agent

Run once, on the first message of every session. Keep it fast: one script call,
one compact status block, no blocking menus. The user came here to work.

---

## Phase 0 - Classify the opening message

- **GREETING** = hello / hi / good morning with no task in it.
- **TASK** = a question, request, or instruction.

Keep the original message: you act on it right after Phase 2.

---

## Phase 1 - One-shot session status (single terminal call)

Run exactly this in ONE terminal call. Use the ABSOLUTE path (the terminal's CWD
is not guaranteed to be the workspace root, especially in a multi-root window):

  powershell -NoProfile -ExecutionPolicy Bypass -File "%%ROOT%%\.github\agent-docs\Get-SessionStatus.ps1"

If that path does not exist (the folder was moved), resolve it from the open
workspace folder that contains `.github/agents/` and use that instead.

It prints SKILLS / CONFIG / IDENTITY / ENV / TOOLS lines and refreshes
`.github/agent-docs/tool-status.json` live. Relay it as one compact block:

"**Session ready.**
- Skills: Microsoft 2026-09-01 | custom pbi-powerapps-integration 2026-07-16
- Signed in: pac: user@contoso.com -> https://org.crm.dynamics.com
- Tools: git, pac, dnx, node, az available
- Nested dispatch: enabled"

Rules:
- Do NOT ask whether to run maintenance. If the script flags stale skills, add
  ONE line: "Upstream skills look stale - say *run maintenance* whenever you want
  them refreshed." Then move on.
- If nested dispatch is NOT set, warn in one line that Team Leads cannot reach
  their Microsoft workers until the installer is re-run, then continue.
- If the script reports a vendor clone is at a different commit than the one
  the agents were generated from, add ONE line: "A Microsoft vendor clone moved
  since the agents were generated - re-run the installer when convenient so the
  worker roster and skill lists match." Then move on.
- If the script itself fails, fall back to `pac auth list` alone and say the
  status script was unavailable. Never block.

---

## Phase 2 - Sign-in and environment: only if missing AND the task needs it

An active `pac` profile pointed at an environment is needed for anything that
touches an environment (pull, push, sync, live canvas / flow authoring, status
of solutions). It is NOT needed to read or edit already-unpacked source, review
diffs, plan, or answer questions. Skip this phase entirely when IDENTITY and ENV
are both populated, or when the opening TASK is local-only (say so in one line:
"Not signed in to pac - fine for this local task; I'll ask when something needs
an environment").

- **Not signed in** -> "Let's get you signed in. What email should I use?" Then
  `pac auth create --deviceCode`, show the URL + code, wait, confirm.
- **No environment** -> `pac org list`, show a short numbered list, ask for a
  number, `pac org select --environment <url>`, confirm "Connected to <env>".
- "switch account" / "switch environment" later in the session repeats only the
  relevant bullet.

Do NOT inventory or pull solutions here. That is the gated SYNC capability in
`working-flow-reference.md` and happens only when the user asks.

---

## Phase 3 - MCP servers: probe lazily, not eagerly

Do NOT probe `canvas-authoring`, `flow-agent` or `microsoft-learn` at startup.
The first time a task needs one, the owning Team Lead makes ONE cheap call
(VS Code auto-starts the server on first use) and falls back to the offline pac
path if it is not callable - saying so. `tool-status.json` proves the runtime
(dnx / node / az) is installed, never that the MCP tools are callable in this
chat session.

---

## Phase 4 - Go to work

- **TASK**: proceed immediately using `.github/agent-docs/working-flow-reference.md`:
  classify, dispatch the owning Team Lead(s) with a WORK ORDER, consolidate.
- **GREETING**: after the status block ask one open question: "What would you
  like to work on? (canvas apps, flows, Power Pages, code / model-driven / mobile
  apps, solutions and environments, or workspace maintenance)". No numbered menu.

The user never has to change agent in the dropdown for normal work. The only
optional switch is workspace maintenance (refreshing the skills clone and MCP
registrations), offered through the handoff button when the user asks for it.
'@).Replace('%%ROOT%%', $rootPath.TrimEnd('\'))
    Write-ManagedFile $startingFlowPath $startingFlowContent
    Write-Host "  $(if ($updateMode) {'Updated'} else {'Created'}) .github/agent-docs/starting-flow.md"
} else {
    Write-Host "  Exists: .github/agent-docs/starting-flow.md" -ForegroundColor DarkGray
}

# -- .github/agent-docs/working-flow-reference.md ----------------------
$workingFlowPath = "$rootPath\.github\agent-docs\working-flow-reference.md"
if ($updateMode -or -not (Test-Path $workingFlowPath)) {
    $workingFlowContent = @'
# Working Flow Reference - Power Platform organisation

Read by the Master for every request after startup, and by Team Leads, the
Architect and QA when they act. Workers do not read this file: their WORK ORDER
is their complete brief.

---

## Skills - registered natively, read before authoring

All skill sources are registered in `chat.agentSkillsLocations`, so every agent
sees the full skill list (name + description) without listing directories:

- **Custom (house style, always wins on style/conventions):** `.github/skills/`
  -> `pbi-powerapps-integration` (canvas apps embedded in Power BI via the Power
  Apps visual: `PowerBIIntegration.Data` / `.Refresh()`, the "re-edit from the
  Power BI SERVICE" golden rule, the 1000-row cap, stale-schema playbook, and the
  cross-environment **repoint** workflow that hardcodes `appId` / `EnvironmentId`
  per DevOps branch).
- **Microsoft power-platform-skills (MIT, read-only vendor clone):**
  `power-platform-skills/plugins/<plugin>/skills/<skill>/SKILL.md` with shared
  guides in `power-platform-skills/plugins/<plugin>/references/`. Plugins:
  canvas-apps, power-automate, power-pages, code-apps, model-apps, mobile-apps,
  power-apps-mobile-extension, mcp-apps.
- **Microsoft copilot-studio-plugin (MIT, read-only vendor clone):**
  `copilot-studio-plugin/skills/<skill>/SKILL.md` (create-agent, clone-agent,
  pull-agent, push-agent, publish-agent, delete-agent, add-knowledge, add-skill)
  with the authoritative YAML schemas in `copilot-studio-plugin/reference/`. These
  drive `pac copilot` for MCS2 (agentic-loop) Copilot Studio agents and belong to
  **090 - Copilot Studio Lead**; its hidden workers are Microsoft's Copilot Studio
  Architect / Describer / Init / Manage agents.

Rules: read the relevant SKILL.md (and the references it points to) BEFORE
generating any YAML, Power Fx, flow definition, TypeScript or solution XML. Read
both the custom and the upstream skill for a topic: custom wins on style,
upstream wins on syntax/spec. If a skill you expect is not in your list,
re-discover it by keyword under `power-platform-skills/plugins/*/skills/` or
`copilot-studio-plugin/skills/` (folders are renamed upstream from time to time) -
never fail because of a path.

Microsoft's plugins were written for another agent runtime. Translate, do not
copy: their `Task` tool is your `agent` tool; `${PLUGIN_ROOT}` is the plugin
folder (`power-platform-skills/plugins/<plugin>` or `copilot-studio-plugin`); a
`<plugin>:<skill>` reference such as `mcs-assistant:publish-agent` means that
plugin's `skills/<skill>/SKILL.md`; `AskUserQuestion` does not exist for a
dispatched agent - return `NEEDS INPUT` / `NEEDS APPROVAL` instead. Skip the
plugin `AGENTS.md` / `CLAUDE.md` files (runtime notes for that other tool); the
`SKILL.md` and references are what you follow.

Two authoring models coexist; the SKILL.md tells you which one applies:

- **Solution-bound (pac CLI, offline):** export -> unpack -> edit source -> pack
  -> import. The source-controlled path for anything that lives in a solution.
- **Live (plugin runtime):** canvas apps through the `canvas-authoring` MCP
  (`sync_canvas` into a working folder, edit `.pa.yaml`, `compile_canvas` commits
  to the open Studio session); cloud flows through the `flow-agent` MCP; code
  apps / mobile apps / Power Pages through their own CLIs as their skills say.
  Live changes are not in git until the solution is pulled again - say so.

Which model fits which component (the Lead decides; this is the default):

| Component | Offline (pac solution) | Live / own CLI |
|---|---|---|
| Canvas app | yes - `.pa.yaml` in the unpacked solution | yes - `canvas-authoring` MCP (open Studio tab) |
| Cloud flow | yes - `definition.json` in the unpacked solution | yes - `flow-agent` MCP (needs Node + `az login`) |
| Desktop flow | metadata only | authored in Power Automate Desktop - edit there |
| Model-driven forms / views / sitemap | yes - XML in the unpacked solution | no |
| Generative pages (model-apps) | packaged by the genpage CLI flow | yes - genpage skill (its CLI) |
| Code app | source lives in its own repo, not the solution | yes - `npx --no-install pa` (Node 22+) |
| Mobile app (Expo) | source lives in its own repo | yes - Expo / mobile-apps CLI flow (Node 22+) |
| Power Pages site | yes - `pac pages download/upload` + solution for tables | yes - code-site tooling |
| Copilot Studio agent (MCS2) | classic agents only (topic YAML inside the solution) | yes - `pac copilot` workspace: init/clone -> edit YAML -> pull/push; publish gated |
| Dataverse tables / columns | yes - solution XML (destructive-adjacent, token) | via the owning skill's CLI |

---

## Team protocol - how a request flows

The Master never implements. Every request is delivered through the teams:

1. **Classify** - which artifact(s), which department(s), offline or live, any
   destructive / Production / shared-environment element.
2. **Architect first only when needed** - dispatch **001 - Solution Architect**
   BEFORE the teams when the request spans two or more component types, changes
   a solution/ALM shape, or needs sequencing/rollback decisions. Single-team,
   single-artifact work goes straight to the Team Lead. The Architect returns a
   PLAN (ownership, order, validation, rollback); it never writes artifacts.
3. **Dispatch the owning Team Lead(s)** with a WORK ORDER (format below). Leads
   that own independent artifacts can run in parallel; dependent ones run in the
   PLAN's order.
4. The **Lead** either does the work with its skills or assigns exactly one
   Microsoft worker per artifact (its `## Your team` table), gives it a WORK
   ORDER, validates the returned work, and returns a WORK RESULT. A Lead may
   dispatch the Architect mid-work for a design question it cannot settle.
5. **QA after multi-team work** - dispatch **002 - Integration QA & Change
   Controller** when two or more artifacts changed, when anything targets a
   shared environment, or before any Production import. Not needed for a single
   validated edit.
6. **Consolidate** one answer to the user: what changed, where, validation
   evidence, risks, and anything still needing the user's decision.

Routing map (topic -> Team Lead; workers are Microsoft's, auto-discovered per Lead):
- Canvas apps, `.pa.yaml`, Power BI-embedded apps, repoint -> **010 - Canvas Apps Lead**
- Cloud / desktop flows, connections, flow runs -> **020 - Power Automate Lead**
- Power Pages sites and code sites -> **030 - Power Pages Lead**
- Code apps (React + Vite + TypeScript) -> **040 - Code Apps Lead**
- Model-driven apps, generative pages, forms, views, sitemap -> **050 - Model Apps Lead**
- Mobile apps (Expo / React Native), offline profiles, `.ppmplugin` -> **060 - Mobile Apps Lead**
- MCP-based apps -> **070 - MCP Apps Lead**
- Solutions, publishers, environments, export/import, promotion -> **080 - Solution ALM & Environments Lead**
- Copilot Studio agents (MCS2 YAML projects, `pac copilot`, knowledge, agent skills, publish) -> **090 - Copilot Studio Lead**
- Skills clones, MCP registration, config drift, installer health -> **003 - Workspace Maintainer**

Route by TOPIC, not by tool availability: if an MCP server or CLI is missing the
request still belongs to the same team, which reads `tool-status.json` and
falls back to the offline pac path.

### WORK ORDER (parent -> child)

```
WORK ORDER
goal: <one sentence, the user's words preserved>
artifact: <exact file path(s) under <Env>/<Solution>/ or live item + environment>; owner: <this child>
mode: offline (pac) | live (MCP / plugin CLI) | hybrid
constraints: <style, naming, environment, must-not-touch>
validation expected: <what evidence to return>
approvals granted: <none | literal tokens the user approved>
context: <facts already established: environment URL, solution, branch, IDs, prior results>
```

### WORK RESULT (child -> parent)

```
WORK RESULT
status: DONE | DONE WITH RISKS | NEEDS APPROVAL | NEEDS INPUT | NEEDS ARCHITECT | OUT OF SCOPE | FAILED
changed: <files / live objects, or none>
validation: <what was run and the outcome>
risks: <or none>
request: <exact approval token, question, design decision, or correct owner - only when status is not DONE>
```

Parents relay a child's `request` upward unchanged. Only the top-level agent asks
the user; it then re-dispatches the same Lead with the answer in `approvals granted`
or `context`. Nobody grants approvals on the user's behalf.

### Approval tokens

Destructive, irreversible or shared-environment actions need a literal token in
`approvals granted` - the user's plain-words request ("do it now", "you are
authorised") is NOT the token:

- General form: `APPROVED:<ACTION>:<artifact>` (e.g. `APPROVED:DELETE:Screen2.pa.yaml`,
  `APPROVED:OVERWRITE:DEV/CrmCore`, `APPROVED:IMPORT:TEST/CrmCore`).
- Production import keeps its dedicated token: **`confirm push to prod`**.
- Destructive here means: deleting or dropping any app, screen, control, flow,
  table, column, form, view, site page, file or branch; overwriting local unpacked
  source with a fresh export; importing into a shared (TEST/UAT/PROD)
  environment; a bulk pull of many solutions.

The token names ONE action on ONE artifact; a worker executes only what the
token covers and returns `NEEDS APPROVAL` for anything else.

---

## Capabilities

### PULL a solution
- Export and unpack a named solution into [env]/[solution]/
- Commands:
  pac solution export --name [SolutionName] --path ./exports/[SolutionName].zip
  pac solution unpack --zipfile ./exports/[SolutionName].zip --folder ./[EnvironmentName]/[SolutionName]
- If [env]/[solution]/ already exists with local edits, this OVERWRITES them:
  needs `APPROVED:OVERWRITE:[env]/[solution]` (show `git status` for that folder first)
- Commit with message: "chore: pull [solution] from [env]"

### PUSH a solution
- Pack [env]/[solution]/ into deploy/[solution].zip
- Commands:
  pac solution pack --zipfile ./deploy/[SolutionName].zip --folder ./[EnvironmentName]/[SolutionName] --packagetype [Unmanaged|Managed]
  pac solution import --path ./deploy/[SolutionName].zip
- Confirm the target environment before importing (`pac org who`)
- Shared environments (TEST/UAT) need `APPROVED:IMPORT:[env]/[solution]`;
  **Production needs the user to type `confirm push to prod`** - route through
  002 - Integration QA & Change Controller first
- Commit: "feat: push [solution] to [env]"

### SYNC an environment (bulk pull - gated)
- Run `pac solution list`; filter OUT managed solutions and Microsoft / system
  publishers (they are hundreds of MB each and not yours to version)
- Show the remaining list (name, version, publisher) and ask which to pull;
  pulling more than one solution needs `APPROVED:SYNC:[env]` in the reply
- Then PULL each chosen solution and commit once: "chore: sync [env]"
- Never pull "everything" silently: a real environment lists 50-150 solutions

### EDIT a component

Two editing modes, both first-class. Pick by component type (matrix above) and what
the user wants.

**Offline authoring - for everything that lives in a solution** (canvas apps,
cloud flows, model-driven forms/views/sitemap, Dataverse schema, Pages tables):
1. Pull the solution (export -> unpack) so the source is local.
2. Read the owning plugin's SKILL.md (registered in your skills list) and the
   references it names for the step you are on - honour its own "read X only if Y"
   conditions instead of pre-loading everything.
3. Edit the unpacked source, then run git diff and summarise what changed.
4. Pack and import to apply (needs the environment's approval token). Changes
   show up in the platform after import + a refresh.

**Live coauthoring - canvas apps** (real-time; no pack/import): drives an
OPEN Power Apps Studio browser tab through the `canvas-authoring` MCP tools - see
"Live canvas coauthoring" below. Cloud flows have the equivalent through the
`flow-agent` MCP; code apps, mobile apps and Pages code sites use their own CLI
flow (their SKILL.md is the authority).

Rule of thumb: solution XML components (forms, views, sitemap, schema) -> offline
only. Canvas apps and cloud flows -> offer either (quick tweaks shine live; larger
or source-controlled changes shine offline). Code / mobile / Pages code sites ->
their CLI flow, then pull the solution so git has the result.
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
- Never hardcode secrets; environment identifiers only where a skill says so (repoint)
- When the user says "switch account", run pac auth create --deviceCode
  with their new email, then `pac org list` / `pac org select`

### Terminal & tooling hygiene

- Reuse ONE terminal per session; kill a wedged terminal ("produced no output")
  instead of leaving it and opening more.
- Use the exact executable `path` recorded in `.github/agent-docs/tool-status.json`
  so an older same-named copy on PATH cannot take precedence.
- Sub-agent dispatch and live MCP calls can hit transient HTTP/2 stream errors
  (`ERR_HTTP2_SERVER_REFUSED_STREAM`, an empty completion). Retry 2-3 times with
  a short pause ONLY for read-only calls and for dispatches whose WORK ORDER has
  no write in it - an empty completion is a transport blip, not proof the work
  did not happen. A dispatch or call that could have WRITTEN (edits, import,
  `compile_canvas` commit, flow publish) is not retry-safe: reconcile first
  (`git status` / `git diff` on the artifact, `pac solution list`, a fresh
  `sync_canvas`, the flow run history) and repeat only what is verifiably absent,
  telling the child what already exists.
- Read fast-changing output files with a terminal `Get-Content`, not the cached
  file reader; prefer unique, single-use output file names.

### Who does the work (summary)

- Master = coordinator, never implementer, the only voice to the user. "You fix it"
  means "make the owning team fix it".
- Team Lead = owns the department outcome; uses its skills directly or assigns
  exactly one Microsoft worker per artifact; validates before reporting; may
  consult the Architect mid-work.
- Worker (Microsoft plugin agent, hidden) = implements one artifact per the
  bundled procedure; validates its own change; returns a WORK RESULT; never
  widens its scope and never delegates.
- Architect = cross-domain design/sequencing/rollback PLANs only. QA = cross-artifact
  VERDICTs and the Production gate only. Neither writes artifacts.
- One writer per artifact, always.

'@
    Write-ManagedFile $workingFlowPath $workingFlowContent
    Write-Host "  $(if ($updateMode) {'Updated'} else {'Created'}) .github/agent-docs/working-flow-reference.md"
} else {
    Write-Host "  Exists: .github/agent-docs/working-flow-reference.md" -ForegroundColor DarkGray
}


# -- .github/skills/pbi-powerapps-integration/SKILL.md -----------------
# Custom, maintainer-authored skill (committed - NOT gitignored). Embedded here
# so it is (re)installed and kept current on every run, layering first-hand
# Power BI <-> Power Apps integration knowledge on top of the cloned Microsoft
# canvas-apps skills. This here-string is the source of truth: edit it and
# re-run, or edit the file directly - its on-disk mtime is the freshness signal.
$pbiPaSkillPath = "$rootPath\.github\skills\pbi-powerapps-integration\SKILL.md"
if ($updateMode -or -not (Test-Path $pbiPaSkillPath)) {
    $pbiPaSkillContent = @'
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
'@
    Write-ManagedFile $pbiPaSkillPath $pbiPaSkillContent
    Write-Host "  $(if ($updateMode) {'Updated'} else {'Created'}) .github/skills/pbi-powerapps-integration/SKILL.md"
} else {
    Write-Host "  Exists: .github/skills/pbi-powerapps-integration/SKILL.md" -ForegroundColor DarkGray
}

# -- .vscode/tasks.json (force terminal warm-up on folder open) --------
$tasksJsonPath = "$rootPath\.vscode\tasks.json"
if ($updateMode -or -not (Test-Path $tasksJsonPath)) {
    $tasksJsonContent = @'
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
'@
    Write-ManagedFile $tasksJsonPath $tasksJsonContent
    Write-Host "  $(if ($updateMode) {'Updated'} else {'Created'}) .vscode/tasks.json (terminal warm-up on open)"
} else {
    Write-Host "  Exists: .vscode/tasks.json" -ForegroundColor DarkGray
}

# -- .vscode/settings.json (merge -- preserves user customisations) -----
# chat.subagents.allowInvocationsFromSubagents is window-scoped and OFF by
# default: without it a Team Lead running as the Master's subagent cannot
# dispatch its workers (tier 3 is dead). Forced true. Skill containers are
# registered natively so agents see the catalogue without listing folders.
$settingsJsonPath = "$rootPath\.vscode\settings.json"
$skillLocations = [ordered]@{ '.github/skills' = $true }
foreach ($loc in @(Get-SkillContainerDirs -RootPath $rootPath -SearchSubPaths $vendorSkillSearchPaths)) { $skillLocations[$loc] = $true }
$searchExclude = @{}
foreach ($v in $vendorClones) { $searchExclude["$($v.Name)/"] = $true }
$requiredSettings = @{
    "task.allowAutomaticTasks" = "on"
    "chat.subagents.allowInvocationsFromSubagents" = $true
    "chat.agentSkillsLocations" = $skillLocations
    "git.ignoreLimitWarning" = $true
    "search.exclude" = $searchExclude
}
$existed = Test-Path $settingsJsonPath
$null = Merge-JsonSettings $settingsJsonPath $requiredSettings
Write-Host "  $(if ($existed) {'Merged'} else {'Created'}) .vscode/settings.json (nested dispatch on, $($skillLocations.Count) skill location(s))"

# -- .vscode/mcp.json (Canvas Authoring + FlowAgent + Microsoft Learn MCP) --
# Registers Microsoft's Canvas Authoring MCP server (live canvas editing,
# launched via 'dnx' from the .NET 10 SDK), the Power Automate FlowAgent MCP
# server (bundled in the cloned power-platform-skills repo, launched via Node.js
# 18+, authenticated with 'az login') and the Microsoft Learn docs MCP (HTTP, no
# install - the same server Microsoft ships in its power-automate plugin). All
# are optional at runtime and start on demand; VS Code ignores a server whose
# command is missing. Merged so any user-added MCP servers are preserved.
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
        "flow-agent" = @{
            "command" = "node"
            "args" = @(
                '${workspaceFolder}/power-platform-skills/plugins/power-automate/server/mcp.mjs'
            )
            "env" = @{
                "PLUGIN_ROOT" = '${workspaceFolder}/power-platform-skills/plugins/power-automate'
                "CLAUDE_PLUGIN_ROOT" = '${workspaceFolder}/power-platform-skills/plugins/power-automate'
            }
        }
        "microsoft-learn" = @{
            "type" = "http"
            "url" = "https://learn.microsoft.com/api/mcp"
        }
    }
}
$mcpExisted = Test-Path $mcpJsonPath
$null = Merge-JsonSettings $mcpJsonPath $requiredMcp
Write-Host "  $(if ($mcpExisted) {'Merged'} else {'Created'}) .vscode/mcp.json (canvas-authoring + flow-agent + microsoft-learn MCP servers)"

# -- <folder>.code-workspace (window-scoped nested dispatch) ------------
# chat.subagents.allowInvocationsFromSubagents is WINDOW-scoped: when the folder is
# opened as one root of a multi-root window, VS Code ignores .vscode/settings.json
# for it and only reads the .code-workspace (or user settings). We ship a workspace
# file with the setting forced true and open VS Code from it, so the default opening
# path is always safe. Existing user folders/settings in the file are preserved.
$workspaceFileName = (Split-Path $rootPath -Leaf) + '.code-workspace'
$workspaceFilePath = Join-Path $rootPath $workspaceFileName
$wsObj = [ordered]@{}
$wsFolders = @()
# Folder renamed since the last run? The previous manifest names the workspace file we
# shipped under the old name; use it as the base so user folders/settings carry over
# (Step 6 prunes the old file afterwards).
$wsSourcePath = $workspaceFilePath
if (-not (Test-Path -LiteralPath $workspaceFilePath) -and $updateMode -and (Test-Path -LiteralPath "$rootPath\.github\installed-manifest.json")) {
    try {
        $prevForWs = Get-Content -LiteralPath "$rootPath\.github\installed-manifest.json" -Raw | ConvertFrom-Json
        $oldWs = @($prevForWs.merged | Where-Object { $_ -and ($_.path -notmatch '[\\/]') -and ($_.path -like '*.code-workspace') } | Select-Object -First 1)
        if ($oldWs.Count -gt 0 -and (Test-Path -LiteralPath (Join-Path $rootPath $oldWs[0].path))) {
            $wsSourcePath = Join-Path $rootPath $oldWs[0].path
            Write-Host "  Folder was renamed: carrying settings over from $($oldWs[0].path)" -ForegroundColor DarkGray
        }
    } catch { }
}
if (Test-Path -LiteralPath $wsSourcePath) {
    $parsedWs = Read-JsonLenient -LiteralPath $wsSourcePath
    if ($null -ne $parsedWs) {
        foreach ($p in $parsedWs.PSObject.Properties) { $wsObj[$p.Name] = $p.Value }
        $wsFolders = @($parsedWs.folders)
    } elseif ($wsSourcePath -eq $workspaceFilePath) {
        $script:unmergedConfigs += $workspaceFilePath
        Write-Host "  $workspaceFileName could not be parsed as JSON - left untouched. Nested dispatch is NOT guaranteed in multi-root windows until it is fixed." -ForegroundColor Yellow
    }
}
if ($script:unmergedConfigs -notcontains $workspaceFilePath) {
    if (-not @($wsFolders | Where-Object { $_ -and ([string]$_.path).Replace('\', '/').TrimEnd('/') -eq '.' }).Count) {
        $wsFolders = @([pscustomobject][ordered]@{ path = '.' }) + @($wsFolders | Where-Object { $_ })
    }
    $wsObj['folders'] = @($wsFolders)
    $wsSettings = [ordered]@{}
    if ($wsObj.Contains('settings') -and $wsObj['settings']) { foreach ($p in $wsObj['settings'].PSObject.Properties) { $wsSettings[$p.Name] = $p.Value } }
    $wsSettings['chat.subagents.allowInvocationsFromSubagents'] = $true
    $wsObj['settings'] = $wsSettings
    $wsExisted = Test-Path -LiteralPath $workspaceFilePath
    Write-ManagedFile $workspaceFilePath (($wsObj | ConvertTo-Json -Depth 10))
    Write-Host "  $(if ($wsExisted) {'Merged'} else {'Created'}) $workspaceFileName (nested dispatch forced on at window scope)"
}

Write-Host "`nAll configuration files ready." -ForegroundColor Green
if ($script:unmergedConfigs.Count -gt 0) {
    $warnings += "These config files could not be parsed and were left untouched (required keys NOT added):" + [Environment]::NewLine +
                 "             " + (($script:unmergedConfigs | ForEach-Object { $_.Substring($rootPath.Length).TrimStart('\') }) -join ', ') + [Environment]::NewLine +
                 "             Fix the JSON and re-run the installer."
}
if (-not $EmitAgentsTo) { Read-Host "`nPress Enter to continue..." }

# =====================================================================
# STEP 6  -- Workspace guidance + integrity manifest + self-test
# =====================================================================
Show-Step 6 $totalSteps "Workspace Guidance and Integrity"

# -- .github/agent-docs/tool-status.json -------------------------------
# Runtime capability snapshot the agents read to decide MCP vs. offline paths.
# Each tool records found + command + path so an agent can invoke the EXACT
# executable (an older same-named copy on PATH cannot take precedence).
$toolStatusPath = "$rootPath\.github\agent-docs\tool-status.json"
$toolExes = [ordered]@{ git = 'git'; pac = 'pac'; dnx = 'dnx'; node = 'node'; az = 'az' }
$toolsMap = [ordered]@{}
foreach ($tk in $toolExes.Keys) {
    $exe = $toolExes[$tk]
    $cmd = Get-Command $exe -ErrorAction SilentlyContinue
    if ($cmd) {
        $toolsMap[$tk] = [ordered]@{ found = $true;  command = $exe; path = [string]$cmd.Source }
    } else {
        $toolsMap[$tk] = [ordered]@{ found = $false; command = $exe; path = $null }
    }
}
$toolStatus = [ordered]@{
    generatedAt   = (Get-Date).ToUniversalTime().ToString('o')
    productVersion = $productVersion
    tools = $toolsMap
    mcpServers = [ordered]@{
        "canvas-authoring" = @{ requires = "dnx (.NET 10 SDK)"; purpose = "live canvas coauthoring" }
        "flow-agent"       = @{ requires = "Node.js 18+ and az login"; purpose = "Power Automate flow authoring" }
    }
    runtimeNotes = [ordered]@{
        node = "The installer guarantees Node.js 18+ (enough for the flow MCP). Code apps and mobile apps (Expo SDK 55) need Node.js 22+ and npm 10+ - check 'node --version' before those tasks."
    }
}
Write-ManagedFile $toolStatusPath (($toolStatus | ConvertTo-Json -Depth 6))
Write-Host "  $(if ($updateMode) {'Updated'} else {'Created'}) .github/agent-docs/tool-status.json"

# -- installed-manifest.json (integrity of managed files) --------------
# The manifest is an authoritative WRITE-LOG: it lists exactly the files this
# installer just wrote (never a directory scan), so orphans can never be
# re-absorbed. Three sections:
#   files      - authored files, SHA256-hashed (agents, docs, scripts, skill).
#   discovered - worker wrappers generated from the skills clone, SHA256-hashed
#                (their lifecycle is discovery's, but they are installer-owned).
#   merged     - settings.json / mcp.json / <folder>.code-workspace. These are
#                MERGE files that legitimately carry user keys, so they are
#                key-checked (required keys present), never hashed.
# Machine-specific artefacts (tool-status.json, guardrail-status.json, the
# manifest itself) are excluded: regenerated every run and .gitignored.
$manifestOut = "$rootPath\.github\installed-manifest.json"
$managedRelFiles = @()
foreach ($a in $orderedAgents) { $managedRelFiles += ".github\agents\$($a.filename)" }
$managedRelFiles += @(
    '.github\copilot-instructions.md',
    'AGENTS.md',
    '.vscode\tasks.json',
    '.gitignore',
    'scripts\pac-workflows.ps1',
    '.github\agent-docs\Get-SessionStatus.ps1',
    '.github\agent-docs\starting-flow.md',
    '.github\agent-docs\working-flow-reference.md',
    '.github\skills\pbi-powerapps-integration\SKILL.md'
)
$manifestFiles = @()
foreach ($rel in $managedRelFiles) {
    $full = Join-Path $rootPath $rel
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        $manifestFiles += [ordered]@{ path = $rel; sha256 = Get-Sha256Hex -LiteralPath $full }
    }
}
$manifestDiscovered = @()
foreach ($rel in @($disc.Wrappers)) {
    $full = Join-Path $rootPath $rel
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        $manifestDiscovered += [ordered]@{ path = $rel; sha256 = Get-Sha256Hex -LiteralPath $full }
    }
}
$manifestMerged = @(
    [ordered]@{ path = '.vscode\settings.json'; requiredKeys = @('chat.subagents.allowInvocationsFromSubagents', 'chat.agentSkillsLocations::.github/skills'); requiredTrue = @('chat.subagents.allowInvocationsFromSubagents', 'chat.agentSkillsLocations::.github/skills') },
    [ordered]@{ path = '.vscode\mcp.json';      requiredKeys = @('servers::canvas-authoring::command', 'servers::flow-agent::command', 'servers::microsoft-learn::url'); requiredTrue = @() },
    [ordered]@{ path = $workspaceFileName;       requiredKeys = @('folders', 'settings::chat.subagents.allowInvocationsFromSubagents'); requiredTrue = @('settings::chat.subagents.allowInvocationsFromSubagents') }
)
$newManifestPaths = @($manifestFiles | ForEach-Object { $_.path }) + @($manifestDiscovered | ForEach-Object { $_.path }) + @($manifestMerged | ForEach-Object { $_.path })

# -- Self-pruning: remove files WE shipped in a past version but no longer do --
# Compare the PREVIOUS manifest (still on disk) against the set we are about to
# write. Only a path that was in our own prior write-log - and is no longer
# shipped - is a candidate. User-created files were never in our manifest, so they
# are structurally excluded. Belt-and-braces: candidates must also sit inside a
# managed root (allow-list) and never be a machine-local artefact.
$prunedPaths = @()
if ($updateMode -and (Test-Path -LiteralPath $manifestOut -PathType Leaf)) {
    $purgeAllowedPrefixes = @('.github\agents\', '.github\skills\', '.github\agent-docs\', '.vscode\', 'scripts\')
    $purgeAllowedExact    = @('.github\copilot-instructions.md', 'AGENTS.md', '.gitignore')
    $purgeExcluded        = @('.github\agent-docs\tool-status.json', '.github\agent-docs\guardrail-status.json', '.github\installed-manifest.json')
    try {
        $prevManifest = Get-Content -LiteralPath $manifestOut -Raw | ConvertFrom-Json
    } catch { $prevManifest = $null }
    if ($prevManifest -and $prevManifest.schemaVersion -eq 1 -and $prevManifest.files) {
        $previousManifestPaths = @(@($prevManifest.files) + @($prevManifest.discovered) + @($prevManifest.merged) | Where-Object { $_ } | ForEach-Object { ($_.path -replace '/', '\') })
        foreach ($old in $previousManifestPaths) {
            if ($newManifestPaths -contains $old) { continue }
            if ($purgeExcluded -contains $old)     { continue }
            # A root-level *.code-workspace we shipped under a previous folder name is also in scope.
            $isOurWorkspaceFile = ($old -notmatch '[\\/]') -and ($old -like '*.code-workspace')
            $inScope = ($purgeAllowedExact -contains $old) -or $isOurWorkspaceFile -or ($purgeAllowedPrefixes | Where-Object { $old.StartsWith($_) })
            if (-not $inScope) { continue }
            $victim = Join-Path $rootPath $old
            if (Test-Path -LiteralPath $victim -PathType Leaf) {
                try {
                    Remove-Item -LiteralPath $victim -Force
                    $prunedPaths += $old
                    Write-Host "  Pruned orphan (no longer shipped): $old" -ForegroundColor DarkGray
                } catch {
                    Write-Host "  Could not prune $old (in use?) - leaving in place." -ForegroundColor Yellow
                }
            }
        }
    } else {
        Write-Host "  (Previous manifest missing or pre-write-log - skipping orphan prune this run.)" -ForegroundColor DarkGray
    }
}

# -- Legacy orphans from pre-manifest installer versions ---------------
# These were produced by older versions BEFORE the write-log manifest existed, so
# the diff above can never see them. Remove them only when their content is
# recognisably ours (a user may have reused the same name for something else).
# `.github\hooks` is deliberately NOT listed: it is VS Code's official hooks
# folder today, so a user may legitimately own files there.
$sessionMarker = Join-Path $rootPath '.session-active'
if (Test-Path -LiteralPath $sessionMarker -PathType Leaf) {
    $len = (Get-Item -LiteralPath $sessionMarker).Length
    if ($len -le 2048) { try { Remove-Item -LiteralPath $sessionMarker -Force; Write-Host "  Removed legacy orphan: .session-active" -ForegroundColor DarkGray } catch { } }
    else { Write-Host "  .session-active is larger than the installer's old marker - left in place." -ForegroundColor DarkGray }
}
$legacyCopilotDir = Join-Path $rootPath '.github\copilot'
if (Test-Path -LiteralPath $legacyCopilotDir -PathType Container) {
    $lfiles = @(Get-ChildItem -LiteralPath $legacyCopilotDir -Recurse -File -ErrorAction SilentlyContinue)
    $allKnownTypes = @($lfiles | Where-Object { $_.Extension -notin @('.md', '.json', '.txt') }).Count -eq 0
    $looksOurs = $false
    foreach ($lf in $lfiles) { if ((Get-Content -LiteralPath $lf.FullName -Raw -ErrorAction SilentlyContinue) -match 'Power Platform (Master|Agent|Workspace)|pac-workflows') { $looksOurs = $true; break } }
    if ($lfiles.Count -eq 0 -or ($allKnownTypes -and $looksOurs)) {
        try { Remove-Item -LiteralPath $legacyCopilotDir -Recurse -Force; Write-Host "  Removed legacy orphan: .github\copilot" -ForegroundColor DarkGray } catch { }
    } else {
        Write-Host "  .github\copilot exists but its content is not recognised as installer output - left in place (review it yourself)." -ForegroundColor Yellow
    }
}

# The vendor clone commits the agents were generated from: the status script compares them
# with each clone's HEAD and tells the user to re-run the installer when they diverge.
$vendorCommits = [ordered]@{}
foreach ($v in $vendorClones) {
    $cloneDir = Join-Path $rootPath $v.Name
    $sc = $null
    if (Test-Path -LiteralPath (Join-Path $cloneDir '.git')) {
        $prevEAP2 = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $raw = (& git -C $cloneDir rev-parse HEAD 2>$null)
        $rc = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP2
        if ($rc -eq 0 -and $raw -match '^[0-9a-f]{40}$') { $sc = $raw }
    }
    $vendorCommits[$v.Name] = $sc
}
$installedManifest = [ordered]@{
    schemaVersion  = 1
    generatedAt    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    generatedBy    = 'installer'
    productVersion = $productVersion
    vendorCommits  = $vendorCommits
    fileCount      = $manifestFiles.Count
    files          = $manifestFiles
    discovered     = $manifestDiscovered
    merged         = $manifestMerged
}
Write-ManagedFile $manifestOut (($installedManifest | ConvertTo-Json -Depth 6))
Write-Host "  $(if ($updateMode) {'Updated'} else {'Created'}) .github/installed-manifest.json ($($manifestFiles.Count) authored + $($manifestDiscovered.Count) discovered hashed, $($manifestMerged.Count) merge files key-checked)"

# -- guardrail-status.json (advisory post-generation self-test) --------
# Validates STRUCTURE (not runtime): every agent file has a front-matter fence,
# a name and a description, and the expected count was written.
$selfTest = @()
$agentFiles = Get-ChildItem -LiteralPath "$rootPath\.github\agents" -Filter '*.agent.md' -File
# All-managed-present (not exact-count): every agent WE ship must exist. Discovered
# worker wrappers are installer-owned too (regenerated from the clone). Anything
# else is a user agent: preserved and reported, never a failure.
$managedAgentNames = @($orderedAgents | ForEach-Object { $_.filename })
$discoveredAgentNames = @($disc.Wrappers | ForEach-Object { Split-Path $_ -Leaf })
$presentNames = @($agentFiles | ForEach-Object { $_.Name })
$missingManaged = @($managedAgentNames | Where-Object { $presentNames -notcontains $_ })
foreach ($m in $missingManaged) { $selfTest += "FAIL: managed agent $m was not written" }
$userAgents = @($presentNames | Where-Object { ($managedAgentNames -notcontains $_) -and ($discoveredAgentNames -notcontains $_) })
foreach ($af in $agentFiles) {
    $txt = Get-Content -LiteralPath $af.FullName -Raw
    if ($txt -notmatch '^\s*---') { $selfTest += "FAIL: $($af.Name) missing front-matter fence" }
    if ($txt -notmatch '(?m)^name:')        { $selfTest += "FAIL: $($af.Name) missing name" }
    if ($txt -notmatch '(?m)^description:') { $selfTest += "FAIL: $($af.Name) missing description" }
}
$guardrail = [ordered]@{
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    productVersion = $productVersion
    result = if ($selfTest.Count -eq 0) { 'PASS' } else { 'FAIL' }
    findings = $selfTest
    note = "Advisory structural self-test - validates generated file structure, not runtime tool availability."
}
Write-ManagedFile "$rootPath\.github\agent-docs\guardrail-status.json" (($guardrail | ConvertTo-Json -Depth 6))
if ($selfTest.Count -eq 0) {
    $discoveredNote = if ($discoveredAgentNames.Count -gt 0) { ", $($discoveredAgentNames.Count) discovered worker(s)" } else { '' }
    $preserved = if ($userAgents.Count -gt 0) { " ($($userAgents.Count) user agent(s) preserved)" } else { '' }
    Write-Host "  Self-test PASSED - all $($managedAgentNames.Count) managed agents present$discoveredNote$preserved." -ForegroundColor Green
} else {
    Write-Host "  Self-test findings:" -ForegroundColor Yellow
    $selfTest | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
}

# In emit mode we are done: exit 0 on a clean self-test, 1 otherwise.
if ($EmitAgentsTo) {
    if ($selfTest.Count -eq 0) { Write-Host "[emit mode] Generation OK." -ForegroundColor Green; exit 0 }
    else { Write-Host "[emit mode] Generation FAILED self-test." -ForegroundColor Red; exit 1 }
}

# -- STEP 7 - Initialise git repository --------------------------------
Show-Step 7 $totalSteps "Initializing Git Repository"

Push-Location $rootPath
try {
    if (-not (Test-Path "$rootPath\.git")) {
        try { & git init 2>&1 | Out-Null } catch { }
        Write-Host "  Initialised git repository"
    }

    # -- Initial / update commit ------------------------------------------
    $gitUser  = git config user.name  2>$null
    $gitEmail = git config user.email 2>$null
    if ([string]::IsNullOrWhiteSpace($gitUser) -or [string]::IsNullOrWhiteSpace($gitEmail)) {
        Write-Host "  Warning: git user.name/email not configured - skipping initial commit." -ForegroundColor Yellow
        Write-Host "  Run:  git config --global user.name 'Your Name'" -ForegroundColor Yellow
        Write-Host "  Run:  git config --global user.email 'you@example.com'" -ForegroundColor Yellow
    } else {
        $prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        $headBefore = (& git rev-parse HEAD 2>$null)
        if ($updateMode) {
            # Commit from an ISOLATED index so whatever the user had staged stays exactly as it
            # was. Only installer-owned paths are added (and owned deletions removed) in that index.
            $tmpIndex = Join-Path $env:TEMP ("pp_installer_index_" + [guid]::NewGuid().ToString('N'))
            $env:GIT_INDEX_FILE = $tmpIndex
            $tracked = @(); $stagePaths = @()
            try {
                & git read-tree HEAD 2>$null | Out-Null
                if ($LASTEXITCODE -ne 0) { & git read-tree --empty 2>$null | Out-Null }
                # Older workspaces committed the three machine-specific files before they were
                # .gitignored; untrack exactly those (files stay on disk). Never the user's ignores.
                $machineFiles = @('.github/agent-docs/tool-status.json', '.github/agent-docs/guardrail-status.json', '.github/installed-manifest.json')
                $tracked = @(& git ls-files -- @($machineFiles) 2>$null | Where-Object { $_ })
                if ($tracked.Count -gt 0) {
                    & git rm -r --cached --quiet -- @($tracked) 2>$null | Out-Null
                    Write-Host "  Untracked $($tracked.Count) machine-specific file(s) the installer owns (kept on disk)." -ForegroundColor DarkGray
                }
                $stagePaths = @($newManifestPaths | ForEach-Object { $_ -replace '\\', '/' })
                $addFail = 0
                foreach ($p in $stagePaths) {
                    if (Test-Path -LiteralPath (Join-Path $rootPath $p)) { & git add -- $p 2>$null | Out-Null; if ($LASTEXITCODE -ne 0) { $addFail++ } }
                }
                foreach ($d in @($prunedPaths | ForEach-Object { $_ -replace '\\', '/' })) { & git rm --cached --quiet --ignore-unmatch -- $d 2>$null | Out-Null }
                $commitMsg = "chore: update workspace scaffolding to v$productVersion"
                $pending = @(& git diff --cached --name-only 2>$null | Where-Object { $_ })
                if ($addFail -gt 0) { Write-Host "  Warning: $addFail installer path(s) could not be staged - review 'git status'." -ForegroundColor Yellow }
                if ($pending.Count -gt 0) {
                    & git commit -m $commitMsg 2>$null | Out-Null
                    $commitExit = $LASTEXITCODE
                    $headAfter = (& git rev-parse HEAD 2>$null)
                    if ($commitExit -eq 0 -and $headAfter -and $headAfter -ne $headBefore) { Write-Host "  Committed: $commitMsg ($($pending.Count) installer-owned path(s); your own staged changes were left untouched)." -ForegroundColor Green }
                    else { Write-Host "  Warning: git commit failed (exit $commitExit) - scaffolding is updated on disk but not committed." -ForegroundColor Yellow }
                } else {
                    Write-Host "  Nothing new to commit." -ForegroundColor DarkGray
                }
            } finally {
                Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath $tmpIndex -Force -ErrorAction SilentlyContinue
            }
            # Bring the user's real index in line with the new HEAD for the installer-owned
            # paths only (so they do not show as spurious staged changes); everything else
            # in the user's index is left exactly as it was.
            $syncPaths = @($stagePaths + $tracked + @($prunedPaths | ForEach-Object { $_ -replace '\\', '/' })) | Select-Object -Unique
            if ($syncPaths.Count -gt 0) { & git reset -q HEAD -- @($syncPaths) 2>$null | Out-Null }
        } else {
            # Fresh install: the folder is new, so everything in it is ours.
            & git add . 2>$null | Out-Null
            & git commit -m "chore: initial workspace setup" 2>$null | Out-Null
            $commitExit = $LASTEXITCODE
            $headAfter = (& git rev-parse HEAD 2>$null)
            if ($commitExit -eq 0 -and $headAfter -and $headAfter -ne $headBefore) { Write-Host "  Committed: chore: initial workspace setup" -ForegroundColor Green }
            else { Write-Host "  Warning: initial commit did not complete (exit $commitExit)." -ForegroundColor Yellow }
        }
        $ErrorActionPreference = $prevEAP
    }
} finally {
    Pop-Location
}

Write-Host "`nGit repository ready." -ForegroundColor Green

# -- STEP 8 - Launch VS Code ------------------------------------------
Show-Step 8 $totalSteps "Launching VS Code"

Write-Host "=============================================" -ForegroundColor Green
Write-Host "  Setup complete!" -ForegroundColor Green
Write-Host "  Workspace: $rootPath" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Green
Write-Host ""
Write-Host "VS Code will now open your workspace (from $workspaceFileName, which keeps" -ForegroundColor White
Write-Host "Master -> Lead -> worker delegation enabled even in a multi-root window)." -ForegroundColor White
Write-Host "Once open, select Power Platform Master Agent from the" -ForegroundColor White
Write-Host "Copilot Chat dropdown and type anything to start." -ForegroundColor White
Write-Host ""
Read-Host "Press Enter to open VS Code and finish setup..."

& $vscodeCmd $workspaceFilePath
