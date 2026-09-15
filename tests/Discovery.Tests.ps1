# Discovery.Tests.ps1
# -------------------------------------------------------------------
# Validates the DYNAMIC worker sub-agent discovery pass. Microsoft ships its own
# bundled worker agents under power-platform-skills/plugins/<plugin>/agents/*.md.
# The installer scans those after the clone and generates one HIDDEN wrapper agent
# per worker, wired into the owning Team Lead - never copying Microsoft's text.
#
# We can't clone the network repo in CI, so we STAGE a fake plugin agents folder
# inside the emit dir and run the installer's dry-run (-EmitAgentsTo) mode, which
# runs discovery against whatever skills are present. With no staged skills (the
# other suites) discovery is a no-op, so those suites still see exactly 12 agents.

BeforeAll {
    . "$PSScriptRoot/Manifest.Helpers.ps1"
    $script:Installer = Get-InstallerPath

    # $PluginWorkers: plugin name -> (@{ slug = file content }) staged under that plugin's agents/.
    function Invoke-EmitWithStagedWorkers {
        param([hashtable]$PluginWorkers)
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("pp_disc_" + [guid]::NewGuid().ToString('N'))
        foreach ($plugin in $PluginWorkers.Keys) {
            $agentsSrc = Join-Path $dir "power-platform-skills\plugins\$plugin\agents"
            New-Item -ItemType Directory -Path $agentsSrc -Force | Out-Null
            foreach ($slug in $PluginWorkers[$plugin].Keys) {
                [System.IO.File]::WriteAllText((Join-Path $agentsSrc "$slug.md"), $PluginWorkers[$plugin][$slug])
            }
        }
        $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -EmitAgentsTo "{1}" < NUL' -f $script:Installer, $dir
        $null = & cmd /c $cmd 2>&1
        return [pscustomobject]@{
            Dir       = $dir
            Exit      = $LASTEXITCODE
            AgentsDir = Join-Path $dir '.github\agents'
        }
    }

    function New-FakeWorker {
        param([string]$Name, [switch]$ReadOnly, [switch]$EditNoMcp, [switch]$PluginNamespacedLearn)
        $toolLines = if ($ReadOnly) { "  - Read`n  - Grep" }
                     elseif ($EditNoMcp) { "  - Read`n  - Write`n  - Edit" }
                     elseif ($PluginNamespacedLearn) { "  - Read`n  - Edit`n  - Bash`n  - mcp__plugin_power-pages_microsoft-learn__microsoft_docs_search" }
                     else { "  - Read`n  - Write`n  - Edit`n  - Bash`n  - mcp__canvas-authoring__compile_canvas`n  - canvas-authoring/list_controls" }
        return "---`nname: $Name`ndescription: >-`n  Fake $Name for tests.`ncolor: cyan`nuser-invocable: false`ntools:`n$toolLines`n---`n`n# $Name`n`nBody."
    }

    $script:Run = Invoke-EmitWithStagedWorkers @{
        'canvas-apps' = @{
            'canvas-app-planner'    = (New-FakeWorker -Name 'canvas-app-planner')
            'canvas-screen-builder' = (New-FakeWorker -Name 'canvas-screen-builder' -EditNoMcp)
            'canvas-reviewer'       = (New-FakeWorker -Name 'canvas-reviewer' -ReadOnly)
        }
        'power-pages' = @{
            'webapi-integration'    = (New-FakeWorker -Name 'webapi-integration' -PluginNamespacedLearn)
        }
    }
    $script:PlannerWrapper  = Join-Path $script:Run.AgentsDir '010-sub-canvas-app-planner.agent.md'
    $script:BuilderWrapper  = Join-Path $script:Run.AgentsDir '010-sub-canvas-screen-builder.agent.md'
    $script:ReviewerWrapper = Join-Path $script:Run.AgentsDir '010-sub-canvas-reviewer.agent.md'
    $script:PagesWrapper    = Join-Path $script:Run.AgentsDir '030-sub-webapi-integration.agent.md'
    $script:LeadFile        = Join-Path $script:Run.AgentsDir '010-canvas-apps-lead.agent.md'
}

AfterAll {
    if ($script:Run -and (Test-Path $script:Run.Dir)) {
        Remove-Item -LiteralPath $script:Run.Dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Dynamic worker discovery - wrapper generation' {
    It 'exits successfully' {
        $script:Run.Exit | Should -Be 0
    }

    It 'generates one hidden wrapper per staged Microsoft worker' {
        (Test-Path $script:PlannerWrapper) | Should -BeTrue
        (Test-Path $script:BuilderWrapper) | Should -BeTrue
    }

    It 'marks every wrapper non-user-invocable (hidden from the dropdown)' {
        foreach ($w in @($script:PlannerWrapper, $script:BuilderWrapper)) {
            (Get-Content -LiteralPath $w -Raw) | Should -Match '(?m)^user-invocable:\s*false'
        }
    }

    It 'points at Microsoft''s file instead of forking it' {
        $planner = Get-Content -LiteralPath $script:PlannerWrapper -Raw
        $planner | Should -Match 'power-platform-skills/plugins/canvas-apps/agents/canvas-app-planner\.md'
        $planner | Should -Match '\$\{PLUGIN_ROOT\}'
    }

    It 'mirrors the worker''s OWN tools, never the Lead''s MCP grants (least privilege)' {
        # planner: Write/Edit + Bash + canvas-authoring MCP (two spellings) -> edit, execute, canvas-authoring/*
        $planner = Get-Content -LiteralPath $script:PlannerWrapper -Raw
        $planner | Should -Match "(?m)^tools:.*'edit'"
        $planner | Should -Match "(?m)^tools:.*'execute'"
        $planner | Should -Match "(?m)^tools:.*'canvas-authoring/\*'"
        # builder: Write/Edit but NO MCP tools of its own -> edit, and NOT the Lead's canvas-authoring grant
        $builder = Get-Content -LiteralPath $script:BuilderWrapper -Raw
        $builder | Should -Match "(?m)^tools:.*'edit'"
        $builder | Should -Not -Match "(?m)^tools:.*canvas-authoring" -Because 'Microsoft gave this worker no MCP tools'
        $builder | Should -Not -Match "(?m)^tools:.*'execute'"
        # reviewer: Read/Grep only -> read + search, nothing else
        $reviewer = Get-Content -LiteralPath $script:ReviewerWrapper -Raw
        $reviewer | Should -Match "(?m)^tools: \['read', 'search'\]"
        # canvas wrappers never inherit the Lead-only microsoft-learn grant
        foreach ($w in @($planner, $builder, $reviewer)) { $w | Should -Not -Match 'microsoft-learn' }
    }

    It 'normalises Claude plugin-namespaced MCP names (plugin_<plugin>_<server>) to the registered server' {
        # Microsoft's power-pages workers spell the Learn MCP as mcp__plugin_power-pages_microsoft-learn__...;
        # our mcp.json registers it as microsoft-learn, so the grant must be microsoft-learn/*.
        $pages = Get-Content -LiteralPath $script:PagesWrapper -Raw
        $pages | Should -Match "(?m)^tools:.*'microsoft-learn/\*'"
        $pages | Should -Not -Match 'plugin_power-pages'
        $pages | Should -Match "(?m)^tools:.*'execute'"
    }

    It 'gives each wrapper a prefix-namespaced registered name' {
        (Get-Content -LiteralPath $script:PlannerWrapper -Raw) | Should -Match "(?m)^name:\s*'010-canvas-app-planner'"
    }

    It 'gives every wrapper the lean worker contract: token rule, no delegation, WORK RESULT' {
        foreach ($w in @($script:PlannerWrapper, $script:BuilderWrapper, $script:ReviewerWrapper)) {
            $t = Get-Content -LiteralPath $w -Raw
            $t | Should -Match 'APPROVED:DELETE' -Because "$w must know the token format"
            $t | Should -Match 'phrasing is NOT the token' -Because "$w must not treat user wording as approval"
            $t | Should -Match 'WORK RESULT' -Because $w
            $t | Should -Match '(?m)^## Scope boundary' -Because $w
            $t | Should -Match '(?m)^agents: \[\]' -Because 'workers never delegate'
        }
    }
}

Describe 'Dynamic worker discovery - Lead wiring' {
    It 'wires the discovered workers into the owning Team Lead as subagents' {
        $lead = Get-Content -LiteralPath $script:LeadFile -Raw
        $lead | Should -Match "(?m)^agents:.*'010-canvas-app-planner'"
        $lead | Should -Match "(?m)^agents:.*'010-canvas-screen-builder'"
    }

    It 'fills the Lead''s roster with dispatch name -> Microsoft name -> tools' {
        $lead = Get-Content -LiteralPath $script:LeadFile -Raw
        $roster = [regex]::Match($lead, '(?s)<!-- team-roster:start -->(.*?)<!-- team-roster:end -->').Groups[1].Value
        $roster | Should -Match '\| Dispatch name \| Microsoft worker \(plugin\) \| Tools \|'
        $roster | Should -Match '`010-canvas-screen-builder` \| `canvas-screen-builder` \(canvas-apps\)'
        $roster | Should -Match '`010-canvas-app-planner`.*canvas-authoring/\*'
        $roster | Should -Not -Match 'No Microsoft worker agents were found' -Because 'the placeholder must be replaced'
        ([regex]::Matches($lead, 'team-roster:start')).Count | Should -Be 1 -Because 'roster injection must be idempotent'
    }

    It 'leaves Leads without discovered workers on the placeholder roster' {
        $other = Get-Content -LiteralPath (Join-Path $script:Run.AgentsDir '020-power-automate-lead.agent.md') -Raw
        $other | Should -Match 'No Microsoft worker agents were found'
        $other | Should -Match '(?m)^agents: \[\]'
    }

    It 'does not touch the flat 12-agent core (wrappers use the -sub- marker only)' {
        $core = @(Get-ChildItem -LiteralPath $script:Run.AgentsDir -Filter '*.agent.md' -File |
                  Where-Object { $_.Name -notmatch '-sub-' })
        $core.Count | Should -Be 12
    }
}

Describe 'Dynamic worker discovery - self-pruning' {
    It 'removes wrappers for workers Microsoft no longer ships' {
        # First stage two workers, then re-run against the SAME dir with only one:
        # the vanished worker's wrapper must be pruned.
        $run = Invoke-EmitWithStagedWorkers @{
            'canvas-apps' = @{
                'canvas-app-planner'    = (New-FakeWorker -Name 'canvas-app-planner')
                'canvas-screen-builder' = (New-FakeWorker -Name 'canvas-screen-builder' -EditNoMcp)
            }
        }
        try {
            (Test-Path (Join-Path $run.AgentsDir '010-sub-canvas-screen-builder.agent.md')) | Should -BeTrue

            $agentsSrc = Join-Path $run.Dir 'power-platform-skills\plugins\canvas-apps\agents'
            Remove-Item -LiteralPath (Join-Path $agentsSrc 'canvas-screen-builder.md') -Force
            $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -EmitAgentsTo "{1}" < NUL' -f $script:Installer, $run.Dir
            $null = & cmd /c $cmd 2>&1

            (Test-Path (Join-Path $run.AgentsDir '010-sub-canvas-app-planner.agent.md')) | Should -BeTrue
            (Test-Path (Join-Path $run.AgentsDir '010-sub-canvas-screen-builder.agent.md')) | Should -BeFalse
        } finally {
            if (Test-Path $run.Dir) { Remove-Item -LiteralPath $run.Dir -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

Describe 'Dynamic worker discovery - name collisions across plugins' {
    It 'gives same-named workers in different plugins unique, prefix-namespaced names' {
        # Microsoft ships a worker literally named "data-model-architect" in more than
        # one plugin. Flattened into .github/agents, the registered name must stay unique
        # per owning Lead so a Lead never dispatches the wrong plugin's worker.
        $run = Invoke-EmitWithStagedWorkers @{
            'canvas-apps' = @{ 'data-model-architect' = (New-FakeWorker -Name 'data-model-architect') }
            'mobile-apps' = @{ 'data-model-architect' = (New-FakeWorker -Name 'data-model-architect') }
        }
        try {
            $run.Exit | Should -Be 0
            $canvasWrap = Get-Content -LiteralPath (Join-Path $run.AgentsDir '010-sub-data-model-architect.agent.md') -Raw
            $mobileWrap = Get-Content -LiteralPath (Join-Path $run.AgentsDir '060-sub-data-model-architect.agent.md') -Raw
            $canvasWrap | Should -Match "(?m)^name:\s*'010-data-model-architect'"
            $mobileWrap | Should -Match "(?m)^name:\s*'060-data-model-architect'"
            (Get-Content -LiteralPath (Join-Path $run.AgentsDir '010-canvas-apps-lead.agent.md') -Raw) | Should -Match "(?m)^agents:.*'010-data-model-architect'"
            (Get-Content -LiteralPath (Join-Path $run.AgentsDir '060-mobile-apps-lead.agent.md') -Raw) | Should -Match "(?m)^agents:.*'060-data-model-architect'"
        } finally {
            if (Test-Path $run.Dir) { Remove-Item -LiteralPath $run.Dir -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}
