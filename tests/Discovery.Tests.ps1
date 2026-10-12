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
# other suites) discovery is a no-op, so those suites still see exactly 13 agents.
#
# Two vendor layouts are covered: power-platform-skills/plugins/<plugin>/agents
# (multi-plugin) and copilot-studio-plugin/agents (the clone IS the plugin).

BeforeAll {
    . "$PSScriptRoot/Manifest.Helpers.ps1"
    $script:Installer = Get-InstallerPath

    # $PluginWorkers: plugin id -> (@{ slug = file content }) staged under that plugin's agents/.
    # The id 'copilot-studio-plugin' is the single-plugin vendor clone at the workspace root.
    function Invoke-EmitWithStagedWorkers {
        param([hashtable]$PluginWorkers, [hashtable]$SingleSkills)
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("pp_disc_" + [guid]::NewGuid().ToString('N'))
        foreach ($plugin in $PluginWorkers.Keys) {
            $agentsSrc = if ($plugin -eq 'copilot-studio-plugin') { Join-Path $dir "copilot-studio-plugin\agents" } else { Join-Path $dir "power-platform-skills\plugins\$plugin\agents" }
            New-Item -ItemType Directory -Path $agentsSrc -Force | Out-Null
            foreach ($slug in $PluginWorkers[$plugin].Keys) {
                [System.IO.File]::WriteAllText((Join-Path $agentsSrc "$slug.md"), $PluginWorkers[$plugin][$slug])
            }
        }
        foreach ($sk in @($(if ($SingleSkills) { $SingleSkills.Keys } else { @() }))) {
            $skDir = Join-Path $dir "copilot-studio-plugin\skills\$sk"
            New-Item -ItemType Directory -Path $skDir -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $skDir 'SKILL.md'), "---`nname: $sk`ndescription: $($SingleSkills[$sk])`n---`n# $sk")
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
        param([string]$Name, [switch]$ReadOnly, [switch]$EditNoMcp, [switch]$PluginNamespacedLearn, [switch]$NoToolsKey)
        if ($NoToolsKey) { return "---`nname: $Name`ndescription: >-`n  Fake $Name without a tools key.`ncolor: cyan`n---`n`n# $Name`n`nBody." }
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
        'code-apps' = @{
            'code-app-architect'    = (New-FakeWorker -Name 'code-app-architect' -NoToolsKey)
        }
        'copilot-studio-plugin' = @{
            'copilot-studio-architect' = (New-FakeWorker -Name 'Copilot Studio Architect' -NoToolsKey)
            'copilot-studio-manage'    = (New-FakeWorker -Name 'Copilot Studio Manage' -NoToolsKey)
        }
    } -SingleSkills @{ 'publish-agent' = 'Publish a Copilot Studio agent draft with pac copilot publish.'; 'create-agent' = 'Create a new MCS2 Copilot Studio agent with pac copilot init.' }
    $script:PlannerWrapper  = Join-Path $script:Run.AgentsDir '010-sub-canvas-app-planner.agent.md'
    $script:BuilderWrapper  = Join-Path $script:Run.AgentsDir '010-sub-canvas-screen-builder.agent.md'
    $script:ReviewerWrapper = Join-Path $script:Run.AgentsDir '010-sub-canvas-reviewer.agent.md'
    $script:PagesWrapper    = Join-Path $script:Run.AgentsDir '030-sub-webapi-integration.agent.md'
    $script:NoToolsWrapper  = Join-Path $script:Run.AgentsDir '040-sub-code-app-architect.agent.md'
    $script:CspArchWrapper  = Join-Path $script:Run.AgentsDir '090-sub-copilot-studio-architect.agent.md'
    $script:CspLeadFile     = Join-Path $script:Run.AgentsDir '090-copilot-studio-lead.agent.md'
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

    It 'maps a worker that declares no tools: key to a bounded default, not read-only' {
        # Microsoft omits tools: on e.g. code-app-architect (inherit-all in its runtime); it must still
        # be able to run `node --version` and write a plan, but never gets MCP servers it never named.
        $w = Get-Content -LiteralPath $script:NoToolsWrapper -Raw
        $w | Should -Match "(?m)^tools: \['read', 'search', 'edit', 'execute'\]"
        $w | Should -Not -Match 'microsoft-learn'
    }

    It 'translates the upstream tool vocabulary (plan mode, task lists, apply_patch) instead of leaving it unmapped' {
        $t = Get-Content -LiteralPath $script:PlannerWrapper -Raw
        foreach ($needle in 'EnterPlanMode', 'TaskCreate', 'TodoWrite', 'apply_patch', 'AskUserQuestion') { $t | Should -Match ([regex]::Escape($needle)) -Because "wrapper must explain what $needle becomes" }
        $t | Should -Match 'honouring its own "read X only if Y" conditions' -Because 'workers must not pre-load every reference'
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
    It 'wires the discovered workers into the owning Team Lead as subagents without dropping its escalation targets' {
        $lead = Get-Content -LiteralPath $script:LeadFile -Raw
        $lead | Should -Match "(?m)^agents:.*'010-canvas-app-planner'"
        $lead | Should -Match "(?m)^agents:.*'010-canvas-screen-builder'"
        $lead | Should -Match "(?m)^agents:.*'001 - Solution Architect'" -Because 'the Lead body says it may consult the Architect, so it must be dispatchable'
        $lead | Should -Match "(?m)^agents:.*'002 - Integration QA & Change Controller'"
        ([regex]::Matches($lead, "'010-canvas-app-planner'")).Count | Should -Be 1 -Because 'merging must not duplicate entries on re-run'
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
        $other | Should -Match "(?m)^agents: \['001 - Solution Architect', '002 - Integration QA & Change Controller'\]"
    }

    It 'does not touch the flat 13-agent core (wrappers use the -sub- marker only)' {
        $core = @(Get-ChildItem -LiteralPath $script:Run.AgentsDir -Filter '*.agent.md' -File |
                  Where-Object { $_.Name -notmatch '-sub-' })
        $core.Count | Should -Be 13
    }
}

Describe 'Dynamic worker discovery - single-plugin vendor clone (copilot-studio-plugin)' {
    It 'discovers workers from <clone>/agents and wires them into the 090 Copilot Studio Lead with namespaced names' {
        (Test-Path $script:CspArchWrapper) | Should -BeTrue
        (Test-Path (Join-Path $script:Run.AgentsDir '090-sub-copilot-studio-manage.agent.md')) | Should -BeTrue
        $w = Get-Content -LiteralPath $script:CspArchWrapper -Raw
        $w | Should -Match "(?m)^name:\s*'090-copilot-studio-architect'"
        $w | Should -Match 'copilot-studio-plugin/agents/copilot-studio-architect\.md' -Because 'the wrapper points at the vendor file in the single-plugin layout'
        $w | Should -Not -Match 'power-platform-skills/plugins/copilot-studio-plugin' -Because 'the plugin root must not be assumed to live under power-platform-skills'
        $w | Should -Match 'mcs-assistant:publish-agent' -Because 'the <plugin>:<skill> reference style used by this vendor must be translated'
        $w | Should -Match '`copilot-studio-plugin/skills/<skill>/SKILL\.md`'
        $w | Should -Match "(?m)^tools: \['read', 'search', 'edit', 'execute'\]" -Because 'Microsoft declares no tools: on these workers; they need pac + file edits'
        $lead = Get-Content -LiteralPath $script:CspLeadFile -Raw
        $lead | Should -Match "(?m)^agents:.*'090-copilot-studio-architect'"
        $lead | Should -Match "(?m)^agents:.*'090-copilot-studio-manage'"
        $lead | Should -Match "(?m)^agents:.*'001 - Solution Architect'"
        $lead | Should -Match '`090-copilot-studio-manage` \| `Copilot Studio Manage` \(copilot-studio-plugin\)'
    }

    It 'registers copilot-studio-plugin/skills in chat.agentSkillsLocations and attaches its skills to the 090 Lead only' {
        $s = Get-Content -LiteralPath (Join-Path $script:Run.Dir '.vscode\settings.json') -Raw | ConvertFrom-Json
        $s.'chat.agentSkillsLocations'.'copilot-studio-plugin/skills' | Should -BeTrue
        $s.'search.exclude'.'copilot-studio-plugin/' | Should -BeTrue
        $lead = Get-Content -LiteralPath $script:CspLeadFile -Raw
        $lead | Should -Match 'copilot-studio-plugin/skills/create-agent'
        $lead | Should -Match 'copilot-studio-plugin/skills/publish-agent'
        $other = Get-Content -LiteralPath (Join-Path $script:Run.AgentsDir '080-solution-alm-environments-lead.agent.md') -Raw
        $other | Should -Not -Match 'copilot-studio-plugin/skills/publish-agent' -Because 'keyword discovery is scoped to each Lead''s own plugins'
    }

    It 'prunes a Copilot Studio wrapper when Microsoft removes the worker' {
        $run = Invoke-EmitWithStagedWorkers @{ 'copilot-studio-plugin' = @{ 'copilot-studio-init' = (New-FakeWorker -Name 'Copilot Studio Init' -NoToolsKey); 'copilot-studio-describer' = (New-FakeWorker -Name 'Copilot Studio Describer' -NoToolsKey) } }
        try {
            (Test-Path (Join-Path $run.AgentsDir '090-sub-copilot-studio-describer.agent.md')) | Should -BeTrue
            Remove-Item -LiteralPath (Join-Path $run.Dir 'copilot-studio-plugin\agents\copilot-studio-describer.md') -Force
            $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -EmitAgentsTo "{1}" < NUL' -f $script:Installer, $run.Dir
            $null = & cmd /c $cmd 2>&1
            (Test-Path (Join-Path $run.AgentsDir '090-sub-copilot-studio-init.agent.md')) | Should -BeTrue
            (Test-Path (Join-Path $run.AgentsDir '090-sub-copilot-studio-describer.agent.md')) | Should -BeFalse
            (Get-Content -LiteralPath (Join-Path $run.AgentsDir '090-copilot-studio-lead.agent.md') -Raw) | Should -Not -Match '090-copilot-studio-describer'
        } finally { if (Test-Path $run.Dir) { Remove-Item -LiteralPath $run.Dir -Recurse -Force -ErrorAction SilentlyContinue } }
    }
}

Describe 'Dynamic worker discovery - integrity ownership' {
    It 'records every wrapper in the manifest discovered section and -VerifyRoot catches a modified wrapper' {
        $m = Get-Content -LiteralPath (Join-Path $script:Run.Dir '.github\installed-manifest.json') -Raw | ConvertFrom-Json
        $paths = @($m.discovered.path)
        $paths | Should -Contain '.github\agents\010-sub-canvas-app-planner.agent.md'
        $paths | Should -Contain '.github\agents\030-sub-webapi-integration.agent.md'
        @($m.files.path) | Should -Not -Contain '.github\agents\010-sub-canvas-app-planner.agent.md' -Because 'wrappers live in their own section'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Installer -VerifyRoot $script:Run.Dir 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
        Add-Content -LiteralPath $script:BuilderWrapper -Value 'tampered'
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Installer -VerifyRoot $script:Run.Dir 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 1 -Because 'an edited wrapper must be reported as drift'
        $out | Should -Match 'CHANGED: .*010-sub-canvas-screen-builder'
    }

    It 'the self-test reports wrappers as discovered workers and only true extras as user agents' {
        $run = Invoke-EmitWithStagedWorkers @{ 'canvas-apps' = @{ 'canvas-app-planner' = (New-FakeWorker -Name 'canvas-app-planner') } }
        try {
            [System.IO.File]::WriteAllText((Join-Path $run.AgentsDir 'my-sub-agent.agent.md'), "---`nname: my-sub-agent`ndescription: mine`n---`nuser file")
            $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -EmitAgentsTo "{1}" < NUL' -f $script:Installer, $run.Dir
            $out = (& cmd /c $cmd 2>&1) -join "`n"
            $out | Should -Match '1 discovered worker\(s\)'
            $out | Should -Match '1 user agent\(s\) preserved'
        } finally { if (Test-Path $run.Dir) { Remove-Item -LiteralPath $run.Dir -Recurse -Force -ErrorAction SilentlyContinue } }
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

    It 'never prunes a user agent whose name merely contains "-sub-"' {
        $run = Invoke-EmitWithStagedWorkers @{ 'canvas-apps' = @{ 'canvas-app-planner' = (New-FakeWorker -Name 'canvas-app-planner') } }
        try {
            $userFile = Join-Path $run.AgentsDir 'my-sub-agent.agent.md'
            $lookalike = Join-Path $run.AgentsDir '010-sub-mine.agent.md'   # our prefix pattern but NOT our content
            [System.IO.File]::WriteAllText($userFile, "---`nname: my-sub-agent`ndescription: mine`n---`nuser file")
            [System.IO.File]::WriteAllText($lookalike, "---`nname: 010-sub-mine`ndescription: also mine`n---`nhand-written")
            $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -EmitAgentsTo "{1}" < NUL' -f $script:Installer, $run.Dir
            $null = & cmd /c $cmd 2>&1
            (Test-Path $userFile) | Should -BeTrue -Because 'the prune must be scoped to installer-generated wrappers'
            (Test-Path $lookalike) | Should -BeTrue -Because 'the body marker must match, not only the filename'
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
