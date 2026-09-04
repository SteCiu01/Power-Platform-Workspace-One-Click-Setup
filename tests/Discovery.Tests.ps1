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
        param([string]$Name, [switch]$ReadOnly)
        $toolLines = if ($ReadOnly) { "  - Read`n  - Grep" } else { "  - Read`n  - Write`n  - Edit`n  - canvas-authoring/compile_canvas" }
        return "---`nname: $Name`ndescription: >-`n  Fake $Name for tests.`ncolor: cyan`nuser-invocable: false`ntools:`n$toolLines`n---`n`n# $Name`n`nBody."
    }

    $script:Run = Invoke-EmitWithStagedWorkers @{
        'canvas-apps' = @{
            'canvas-app-planner'    = (New-FakeWorker -Name 'canvas-app-planner')
            'canvas-screen-builder' = (New-FakeWorker -Name 'canvas-screen-builder' -ReadOnly)
        }
    }
    $script:PlannerWrapper = Join-Path $script:Run.AgentsDir '010-sub-canvas-app-planner.agent.md'
    $script:BuilderWrapper = Join-Path $script:Run.AgentsDir '010-sub-canvas-screen-builder.agent.md'
    $script:LeadFile       = Join-Path $script:Run.AgentsDir '010-canvas-apps-lead.agent.md'
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

    It 'mirrors Microsoft''s tool intent (edit worker gets edit + MCP; read-only stays read-only)' {
        $planner = Get-Content -LiteralPath $script:PlannerWrapper -Raw
        $planner | Should -Match "(?m)^tools:.*'edit'"
        $planner | Should -Match "(?m)^tools:.*'canvas-authoring/\*'"
        $builder = Get-Content -LiteralPath $script:BuilderWrapper -Raw
        $builder | Should -Not -Match "(?m)^tools:.*'edit'"
    }

    It 'gives each wrapper a prefix-namespaced registered name' {
        (Get-Content -LiteralPath $script:PlannerWrapper -Raw) | Should -Match "(?m)^name:\s*'010-canvas-app-planner'"
    }
}

Describe 'Dynamic worker discovery - Lead wiring' {
    It 'wires the discovered workers into the owning Team Lead as subagents' {
        $lead = Get-Content -LiteralPath $script:LeadFile -Raw
        $lead | Should -Match "(?m)^agents:.*'010-canvas-app-planner'"
        $lead | Should -Match "(?m)^agents:.*'010-canvas-screen-builder'"
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
                'canvas-screen-builder' = (New-FakeWorker -Name 'canvas-screen-builder' -ReadOnly)
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
