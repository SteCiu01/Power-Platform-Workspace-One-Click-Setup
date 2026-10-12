# Generated.Tests.ps1
# -------------------------------------------------------------------
# End-to-end smoke test of the REAL generator. Unlike the other suites
# (which read the embedded manifest without running the installer),
# this one actually RUNS the installer in its dry-run "-EmitAgentsTo"
# mode into a throwaway temp folder and asserts on the agent files it
# produces on disk. This proves the code path that writes agents -- not
# just the manifest data -- is correct and stays in sync.
#
# Emit mode performs NO prerequisite checks, NO repo cloning, NO tool
# installs and NO VS Code launch, so it is safe to run in CI.
#
# Note on filenames: the manifest and the emitted files both use a
# three-digit, team-grouped prefix (e.g. "000-..."). We still pair a
# manifest entry to its generated file by "slug" -- the filename with its
# leading numeric prefix removed -- which is robust to any padding width.

BeforeAll {
    . "$PSScriptRoot/Manifest.Helpers.ps1"

    $script:Manifest    = Get-AgentManifest
    $script:Installer   = Get-InstallerPath
    $script:EmitDir     = Join-Path ([System.IO.Path]::GetTempPath()) ("pp_emit_" + [guid]::NewGuid().ToString('N'))

    # Run the installer's dry-run generator. stdin is fed from NUL so any
    # "Press Enter to continue" prompts in the generation steps return
    # immediately (EOF) instead of blocking the test run.
    # Force Windows PowerShell 5.1 (powershell.exe) for the child so the emit path
    # behaves identically on a PS7 CI host and a local PS5.1 shell.
    $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -EmitAgentsTo "{1}" < NUL' -f $script:Installer, $script:EmitDir
    $script:EmitOutput  = & cmd /c $cmd 2>&1
    $script:EmitExit    = $LASTEXITCODE
    $script:AgentsDir   = Join-Path $script:EmitDir '.github\agents'
    $script:AgentFiles  = @(Get-ChildItem -Path $script:AgentsDir -Filter '*.agent.md' -ErrorAction SilentlyContinue)

    function Get-FrontmatterTools {
        param([string]$Path)
        $head = Get-Content -LiteralPath $Path -TotalCount 15
        $line = $head | Where-Object { $_ -match '^\s*tools:\s*\[' } | Select-Object -First 1
        if (-not $line) { return @() }
        $inner = ($line -replace '^\s*tools:\s*\[', '') -replace '\].*$', ''
        return @($inner -split ',' | ForEach-Object { $_.Trim().Trim("'").Trim('"') } | Where-Object { $_ })
    }

    # Base capability tokens. MCP entries (which contain "/") are additive
    # and excluded from the manifest-vs-generated comparison.
    $script:BaseTools = @('agent', 'read', 'search', 'execute', 'edit')

    # slug (filename without numeric prefix) -> generated file info
    $script:GenBySlug = @{}
    foreach ($f in $script:AgentFiles) {
        $slug = $f.Name -replace '^\d+-', ''
        $script:GenBySlug[$slug] = [pscustomobject]@{
            Name  = $f.Name
            Path  = $f.FullName
            Tools = @(Get-FrontmatterTools -Path $f.FullName)
        }
    }
}

AfterAll {
    if ($script:EmitDir -and (Test-Path -LiteralPath $script:EmitDir)) {
        Remove-Item -LiteralPath $script:EmitDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Installer emit mode (real generator dry-run)' {

    It 'exits successfully (self-test gate passed)' {
        $script:EmitExit | Should -Be 0 -Because "the emit dry-run must exit 0; installer output was:`n$(($script:EmitOutput | Out-String))"
    }

    It 'creates exactly one agent file per manifest entry' {
        $script:AgentFiles.Count | Should -Be $script:Manifest.agents.Count
    }

    It 'writes exactly one generated file per manifest slug (no missing, no extras)' {
        $generatedSlugs = $script:GenBySlug.Keys | Sort-Object
        $manifestSlugs  = $script:Manifest.agents.filename | ForEach-Object { $_ -replace '^\d+-', '' } | Sort-Object
        $generatedSlugs | Should -Be $manifestSlugs
    }

    It 'names every generated file with a three-digit ordered prefix' {
        foreach ($f in $script:AgentFiles) {
            $f.Name | Should -Match '^\d{3}-[a-z0-9-]+\.agent\.md$'
        }
    }
}

Describe 'Generated agent frontmatter' {

    It 'every agent file opens with a YAML frontmatter fence' {
        foreach ($f in $script:AgentFiles) {
            (Get-Content -LiteralPath $f.FullName -TotalCount 1) | Should -Be '---'
        }
    }

    It 'every generated file has a name and description in its frontmatter' {
        foreach ($f in $script:AgentFiles) {
            $head = (Get-Content -LiteralPath $f.FullName -TotalCount 15) -join "`n"
            $head | Should -Match '(?m)^name:\s*'
            $head | Should -Match '(?m)^description:\s*'
        }
    }

    It 'each generated file exposes exactly the base capability tokens declared in the manifest' {
        foreach ($agent in $script:Manifest.agents) {
            $slug = $agent.filename -replace '^\d+-', ''
            $script:GenBySlug.ContainsKey($slug) | Should -BeTrue -Because "manifest lists $($agent.filename)"

            $generatedBase = @($script:GenBySlug[$slug].Tools | Where-Object { $script:BaseTools -contains $_ } | Sort-Object)
            $expectedBase  = @($agent.tools | Where-Object { $script:BaseTools -contains $_ } | Sort-Object)

            ($generatedBase -join ',') | Should -Be ($expectedBase -join ',') -Because "tools drift in $($agent.filename)"
        }
    }

    It 'each MCP server binding is appended as a wildcard tool token' {
        foreach ($agent in ($script:Manifest.agents | Where-Object { $_.mcpServers })) {
            $slug = $agent.filename -replace '^\d+-', ''
            foreach ($srv in $agent.mcpServers) {
                $script:GenBySlug[$slug].Tools | Should -Contain "$srv/*" -Because "$($agent.filename) binds MCP server '$srv'"
            }
        }
    }

    It 'no worker agent exposes the delegation (agent) token' {
        foreach ($agent in ($script:Manifest.agents | Where-Object { $_.level -eq 'worker' })) {
            $slug = $agent.filename -replace '^\d+-', ''
            $script:GenBySlug[$slug].Tools | Should -Not -Contain 'agent' -Because "$($agent.filename) is a worker and must not delegate"
        }
    }

    It 'the Master lists exactly its declared children in agents: and carries a maintenance handoff' {
        $master = $script:Manifest.agents | Where-Object { $_.id -eq 'power-platform-master' }
        $slug = $master.filename -replace '^\d+-', ''
        $head = (Get-Content -LiteralPath $script:GenBySlug[$slug].Path -TotalCount 25) -join "`n"
        $line = [regex]::Match($head, '(?m)^agents:\s*\[(.*)\]').Groups[1].Value
        $listed = @($line -split ',' | ForEach-Object { $_.Trim().Trim("'") } | Where-Object { $_ })
        $listed.Count | Should -Be @($master.allowedChildren).Count
        $head | Should -Match '(?m)^handoffs:'
        $head | Should -Match 'Workspace Maintainer'
    }
}

Describe 'Generated agent content (specialist knowledge and team protocol)' {

    BeforeAll {
        $script:BodyBySlug = @{}
        foreach ($k in $script:GenBySlug.Keys) {
            $script:BodyBySlug[$k] = Get-Content -LiteralPath $script:GenBySlug[$k].Path -Raw
        }
    }

    It 'every agent has a Knowledge and skills section with at least one skill reference' {
        foreach ($agent in $script:Manifest.agents) {
            $slug = $agent.filename -replace '^\d+-', ''
            $body = $script:BodyBySlug[$slug]
            $body | Should -Match '(?m)^## Knowledge and skills' -Because "$($agent.filename) must not be an empty shell"
            $body | Should -Match '(?m)^- `[^`]+` ' -Because "$($agent.filename) must list at least one skill path"
        }
    }

    It 'every agent has a Playbook and a Validation section' {
        foreach ($agent in $script:Manifest.agents) {
            $slug = $agent.filename -replace '^\d+-', ''
            $body = $script:BodyBySlug[$slug]
            $body | Should -Match '(?m)^## Playbook' -Because $agent.filename
            $body | Should -Match '(?m)^## Validation you must run before reporting' -Because $agent.filename
        }
    }

    It 'every non-Master agent ends with the WORK RESULT return contract' {
        foreach ($agent in ($script:Manifest.agents | Where-Object { $_.id -ne 'power-platform-master' })) {
            $slug = $agent.filename -replace '^\d+-', ''
            $body = $script:BodyBySlug[$slug]
            $body | Should -Match 'WORK RESULT' -Because $agent.filename
            $body | Should -Match 'NEEDS APPROVAL' -Because $agent.filename
        }
    }

    It 'every agent carries the approval-token rule (plain words are not the token)' {
        foreach ($k in $script:BodyBySlug.Keys) {
            $script:BodyBySlug[$k] | Should -Match 'APPROVED:<ACTION>:<artifact>' -Because $k
            $script:BodyBySlug[$k] | Should -Match 'request itself is not the approval' -Because $k
            $script:BodyBySlug[$k] | Should -Match 'confirm push to prod' -Because $k
        }
    }

    It 'every team lead has a roster placeholder, dispatch rules and the dispatch-name instruction' {
        foreach ($agent in ($script:Manifest.agents | Where-Object { $_.level -eq 'team-lead' })) {
            $slug = $agent.filename -replace '^\d+-', ''
            $body = $script:BodyBySlug[$slug]
            $body | Should -Match '(?m)^## Your team' -Because $agent.filename
            $body | Should -Match '<!-- team-roster:start -->' -Because "$($agent.filename) must carry the roster markers discovery fills"
            $body | Should -Match '(?m)^## How you dispatch' -Because $agent.filename
            $body | Should -Match 'never the bare Microsoft name' -Because $agent.filename
            $body | Should -Not -Match 'Read the plugin ``AGENTS\.md``' -Because 'plugin AGENTS.md is Claude Code runtime noise'
        }
    }

    It 'the Architect returns a PLAN and QA returns a VERDICT' {
        $arch = ($script:Manifest.agents | Where-Object { $_.id -eq 'solution-architect' }).filename -replace '^\d+-', ''
        $qa   = ($script:Manifest.agents | Where-Object { $_.id -eq 'integration-qa-change-controller' }).filename -replace '^\d+-', ''
        $script:BodyBySlug[$arch] | Should -Match '(?m)^## Your output: a PLAN'
        $script:BodyBySlug[$qa]   | Should -Match '(?m)^## Your output: a VERDICT'
    }

    It 'the Master describes the three loops, the session ledger and the destructive-request confirmation' {
        $slug = ($script:Manifest.agents | Where-Object { $_.id -eq 'power-platform-master' }).filename -replace '^\d+-', ''
        $body = $script:BodyBySlug[$slug]
        $body | Should -Match '(?m)^## The three loops you run'
        $body | Should -Match '(?m)^## Session ledger'
        $body | Should -Match 'Confirm destructive requests up front'
        $body | Should -Match '(?m)^## You are the only voice to the client'
        $body | Should -Not -Match 'Degraded-mode' -Because 'the direct-dispatch fallback was removed'
        $body | Should -Not -Match 'Routing is invisible' -Because 'approvals now bubble up instead of being hidden'
        $body | Should -Not -Match '\[S\] set me up' -Because 'the blocking startup menu was removed'
    }

    It 'the Master carries the dispatch-health rule for nested delegation' {
        $slug = ($script:Manifest.agents | Where-Object { $_.id -eq 'power-platform-master' }).filename -replace '^\d+-', ''
        $script:BodyBySlug[$slug] | Should -Match 'chat\.subagents\.allowInvocationsFromSubagents'
    }

    It 'managed-file references always resolve (no re-discover marker on .github or scripts paths)' {
        foreach ($k in $script:BodyBySlug.Keys) {
            $script:BodyBySlug[$k] | Should -Not -Match '`(\.github|scripts)/[^`]+` \*\(not present' -Because "$k references a managed file the installer always writes"
        }
    }

    It 'the Workspace Maintainer no longer claims to purge .github/hooks' {
        $slug = ($script:Manifest.agents | Where-Object { $_.id -eq 'workspace-maintainer' }).filename -replace '^\d+-', ''
        $script:BodyBySlug[$slug] | Should -Not -Match 'legacy orphans \(``\.github/hooks/``'
        $script:BodyBySlug[$slug] | Should -Match 'leaves `\.github/hooks/` alone'
    }

    It 'every section heading is preceded by a blank line (markdown renders correctly)' {
        foreach ($k in $script:BodyBySlug.Keys) {
            $lines = $script:BodyBySlug[$k] -split "`r?`n"
            for ($i = 1; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -like '## *') { $lines[$i - 1].Trim() | Should -Be '' -Because "$k line $($i + 1)" }
            }
        }
    }
}

Describe 'Generated configuration (settings, MCP, docs, status script)' {

    It 'enables nested subagent dispatch and registers the custom skill location in .vscode/settings.json' {
        $p = Join-Path $script:EmitDir '.vscode\settings.json'
        Test-Path -LiteralPath $p | Should -BeTrue
        $s = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        $s.'chat.subagents.allowInvocationsFromSubagents' | Should -BeTrue
        $s.'chat.agentSkillsLocations'.'.github/skills' | Should -BeTrue
    }

    It 'emits a <folder>.code-workspace with nested dispatch forced on (window scope) and key-checks it in the manifest' {
        $files = @(Get-ChildItem -LiteralPath $script:EmitDir -Filter '*.code-workspace' -File)
        $files.Count | Should -Be 1
        $files[0].Name | Should -Be ((Split-Path $script:EmitDir -Leaf) + '.code-workspace')
        $w = Get-Content -LiteralPath $files[0].FullName -Raw | ConvertFrom-Json
        @($w.folders.path) | Should -Contain '.'
        $w.settings.'chat.subagents.allowInvocationsFromSubagents' | Should -BeTrue -Because 'folder settings are ignored for this key in a multi-root window'
        $manifest = Get-Content -LiteralPath (Join-Path $script:EmitDir '.github\installed-manifest.json') -Raw | ConvertFrom-Json
        @($manifest.merged.path) | Should -Contain $files[0].Name
    }

    It 'the manifest hashes authored files but key-checks merge files (settings, mcp, workspace)' {
        $manifest = Get-Content -LiteralPath (Join-Path $script:EmitDir '.github\installed-manifest.json') -Raw | ConvertFrom-Json
        $hashed = @($manifest.files.path)
        $merged = @($manifest.merged.path)
        foreach ($p in '.vscode\settings.json', '.vscode\mcp.json') {
            $hashed | Should -Not -Contain $p -Because "$p legitimately carries user keys"
            $merged | Should -Contain $p
        }
        $hashed | Should -Contain '.github\agents\000-power-platform-master.agent.md'
        $hashed | Should -Contain 'scripts\pac-workflows.ps1'
        $manifest.PSObject.Properties.Name | Should -Contain 'discovered'
        # A user key added to settings.json is NOT drift; a removed required key IS.
        $sp = Join-Path $script:EmitDir '.vscode\settings.json'
        $s = Get-Content -LiteralPath $sp -Raw | ConvertFrom-Json
        $s | Add-Member -NotePropertyName 'editor.fontSize' -NotePropertyValue 14
        [System.IO.File]::WriteAllText($sp, ($s | ConvertTo-Json -Depth 10))
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Installer -VerifyRoot $script:EmitDir 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
        $s.PSObject.Properties.Remove('chat.subagents.allowInvocationsFromSubagents')
        [System.IO.File]::WriteAllText($sp, ($s | ConvertTo-Json -Depth 10))
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Installer -VerifyRoot $script:EmitDir 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 1
        $out | Should -Match 'KEY MISSING: .*settings\.json -> chat\.subagents\.allowInvocationsFromSubagents'
    }

    It 're-running over an existing settings.json preserves user keys, including nested skill locations' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('pp_merge_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $dir '.vscode') -Force | Out-Null
        $pre = @{
            'editor.fontSize' = 13
            'chat.agentSkillsLocations' = @{ '~/.vscode/extensions/my-ext/skills' = $true }
            'search.exclude' = @{ 'node_modules/' = $true }
        } | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText((Join-Path $dir '.vscode\settings.json'), $pre)
        try {
            $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -EmitAgentsTo "{1}" < NUL' -f $script:Installer, $dir
            $null = & cmd /c $cmd 2>&1
            $s = Get-Content -LiteralPath (Join-Path $dir '.vscode\settings.json') -Raw | ConvertFrom-Json
            $s.'editor.fontSize' | Should -Be 13
            $s.'chat.agentSkillsLocations'.'~/.vscode/extensions/my-ext/skills' | Should -BeTrue -Because '[ordered] required values must merge, not replace'
            $s.'chat.agentSkillsLocations'.'.github/skills' | Should -BeTrue
            $s.'search.exclude'.'node_modules/' | Should -BeTrue
            $s.'search.exclude'.'power-platform-skills/' | Should -BeTrue
        } finally { if (Test-Path $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue } }
    }

    It 'registers canvas-authoring, flow-agent and the microsoft-learn HTTP server in .vscode/mcp.json' {
        $p = Join-Path $script:EmitDir '.vscode\mcp.json'
        $m = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
        $m.servers.'canvas-authoring'.command | Should -Be 'dnx'
        $m.servers.'flow-agent'.command | Should -Be 'node'
        $m.servers.'microsoft-learn'.type | Should -Be 'http'
        $m.servers.'microsoft-learn'.url | Should -Match '^https://learn\.microsoft\.com/'
    }

    It 'emits Get-SessionStatus.ps1, lists it in the manifest, and it parses' {
        $p = Join-Path $script:EmitDir '.github\agent-docs\Get-SessionStatus.ps1'
        Test-Path -LiteralPath $p | Should -BeTrue
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($p, [ref]$null, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
        $manifest = Get-Content -LiteralPath (Join-Path $script:EmitDir '.github\installed-manifest.json') -Raw | ConvertFrom-Json
        @($manifest.files.path) | Should -Contain '.github\agent-docs\Get-SessionStatus.ps1'
    }

    It 'emits the lean starting flow (one status call, no inventory / sync-all, no blocking menu)' {
        $text = Get-Content -LiteralPath (Join-Path $script:EmitDir '.github\agent-docs\starting-flow.md') -Raw
        $text | Should -Match 'Get-SessionStatus\.ps1'
        $text | Should -Not -Match 'Phase 6 - Sync the local folder'
        $text | Should -Not -Match 'pulling\s+everything down'
        $text | Should -Not -Match '\[S\] set me up'
    }

    It 'emits the working-flow reference with the team protocol, contracts and the gated SYNC capability' {
        $text = Get-Content -LiteralPath (Join-Path $script:EmitDir '.github\agent-docs\working-flow-reference.md') -Raw
        $text | Should -Match '(?m)^## Team protocol'
        $text | Should -Match '(?m)^### WORK ORDER'
        $text | Should -Match '(?m)^### WORK RESULT'
        $text | Should -Match '(?m)^### Approval tokens'
        $text | Should -Match '(?m)^### SYNC an environment \(bulk pull - gated\)'
        $text | Should -Not -Match 'Read the plugin''s ``AGENTS\.md``'
    }

    It 'pac-workflows.ps1 enforces the Production gate in code (-ConfirmProd) and exit-code discipline' {
        $text = Get-Content -LiteralPath (Join-Path $script:EmitDir 'scripts\pac-workflows.ps1') -Raw
        $text | Should -Match '\[switch\]\$ConfirmProd'
        $text | Should -Match 'BLOCKED'
        $text | Should -Match 'pac org who' -Because 'the real target must be resolved, not inferred from the label'
        $text | Should -Match '\$LASTEXITCODE -ne 0'
        $text | Should -Not -Match '(?m)^\s*git add \.\s*$' -Because 'only the solution folder may be staged'
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:EmitDir 'scripts\pac-workflows.ps1'), [ref]$null, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
    }

    It 'copilot-instructions.md no longer references the repo-only schema file' {
        $text = Get-Content -LiteralPath (Join-Path $script:EmitDir '.github\copilot-instructions.md') -Raw
        $text | Should -Not -Match 'schema/agent-manifest\.schema\.json'
        $text | Should -Match 'allowInvocationsFromSubagents'
    }

    It 'the starting flow invokes the status script by absolute path and makes pac sign-in conditional on the task' {
        $text = Get-Content -LiteralPath (Join-Path $script:EmitDir '.github\agent-docs\starting-flow.md') -Raw
        $text | Should -Match ([regex]::Escape((Join-Path $script:EmitDir '.github\agent-docs\Get-SessionStatus.ps1')))
        $text | Should -Not -Match '-File \.github/agent-docs/Get-SessionStatus\.ps1' -Because 'a relative path breaks when the terminal CWD is not the workspace root'
        $text | Should -Match 'local-only'
        $text | Should -Not -Match 'Everything in this workspace needs an active'
    }

    It 'the working-flow reference carries the component capability matrix instead of "offline works for every component"' {
        $text = Get-Content -LiteralPath (Join-Path $script:EmitDir '.github\agent-docs\working-flow-reference.md') -Raw
        $text | Should -Match '\| Component \| Offline \(pac solution\) \| Live / own CLI \|'
        $text | Should -Not -Match 'works for EVERY component'
        $text | Should -Not -Match 'non-canvas components -> offline only'
    }

    It 'records a vendorCommits slot per Microsoft clone in the manifest and the status script compares them' {
        $manifest = Get-Content -LiteralPath (Join-Path $script:EmitDir '.github\installed-manifest.json') -Raw | ConvertFrom-Json
        @($manifest.vendorCommits.PSObject.Properties.Name) | Should -Contain 'power-platform-skills'
        @($manifest.vendorCommits.PSObject.Properties.Name) | Should -Contain 'copilot-studio-plugin'
        $status = Get-Content -LiteralPath (Join-Path $script:EmitDir '.github\agent-docs\Get-SessionStatus.ps1') -Raw
        $status | Should -Match 'vendorCommits'
        $status | Should -Match "'copilot-studio-plugin'" -Because 'freshness must be reported for both clones'
    }

    It 'documents Copilot Studio as a first-class department (090) with its own vendor skills' {
        $ci = Get-Content -LiteralPath (Join-Path $script:EmitDir '.github\copilot-instructions.md') -Raw
        $ci | Should -Match 'copilot-studio-plugin/skills'
        $ci | Should -Match '090 - Copilot Studio Lead'
        $wf = Get-Content -LiteralPath (Join-Path $script:EmitDir '.github\agent-docs\working-flow-reference.md') -Raw
        $wf | Should -Match '-> \*\*090 - Copilot Studio Lead\*\*'
        $wf | Should -Match '\| Copilot Studio agent \(MCS2\)'
        (Get-Content -LiteralPath (Join-Path $script:EmitDir '.gitignore') -Raw) | Should -Match '(?m)^copilot-studio-plugin/\r?$'
    }
}

Describe 'Generated configuration - integrity and merge robustness' {

    It '-VerifyRoot rejects a required key whose value was flipped to false and a manifest with no hashed files' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('pp_verify_' + [guid]::NewGuid().ToString('N'))
        try {
            $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -EmitAgentsTo "{1}" < NUL' -f $script:Installer, $dir
            $null = & cmd /c $cmd 2>&1
            $sp = Join-Path $dir '.vscode\settings.json'
            $s = Get-Content -LiteralPath $sp -Raw | ConvertFrom-Json
            $s.'chat.subagents.allowInvocationsFromSubagents' = $false
            [System.IO.File]::WriteAllText($sp, ($s | ConvertTo-Json -Depth 10))
            $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Installer -VerifyRoot $dir 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 1 -Because 'a present-but-disabled key silently kills nested dispatch'
            $out | Should -Match 'KEY DISABLED: .*settings\.json -> chat\.subagents\.allowInvocationsFromSubagents'
            $mp = Join-Path $dir '.github\installed-manifest.json'
            $m = Get-Content -LiteralPath $mp -Raw | ConvertFrom-Json
            $m.files = @(); $m.discovered = @()
            [System.IO.File]::WriteAllText($mp, ($m | ConvertTo-Json -Depth 6))
            $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Installer -VerifyRoot $dir 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 1
            $out | Should -Match 'EMPTY MANIFEST'
        } finally { if (Test-Path $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue } }
    }

    It 'merges a settings.json with comments and trailing commas (JSONC) instead of replacing it' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('pp_jsonc_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $dir '.vscode') -Force | Out-Null
        $jsonc = "{`n  // my editor prefs`n  `"editor.fontSize`": 15, /* keep */`n  `"files.exclude`": { `"**/.git`": true, },`n}`n"
        [System.IO.File]::WriteAllText((Join-Path $dir '.vscode\settings.json'), $jsonc, (New-Object System.Text.UTF8Encoding($true)))
        try {
            $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -EmitAgentsTo "{1}" < NUL' -f $script:Installer, $dir
            $null = & cmd /c $cmd 2>&1
            $s = Get-Content -LiteralPath (Join-Path $dir '.vscode\settings.json') -Raw | ConvertFrom-Json
            $s.'editor.fontSize' | Should -Be 15 -Because 'user keys must survive a JSONC file'
            $s.'files.exclude'.'**/.git' | Should -BeTrue
            $s.'chat.subagents.allowInvocationsFromSubagents' | Should -BeTrue
            Test-Path (Join-Path $dir '.vscode\settings.json.bak') | Should -BeTrue -Because 'the commented original is kept'
        } finally { if (Test-Path $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue } }
    }

    It 'leaves a genuinely unparseable mcp.json untouched and reports it instead of overwriting it' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('pp_badjson_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $dir '.vscode') -Force | Out-Null
        $broken = '{ "servers": { "mine": { "command": "x" '
        [System.IO.File]::WriteAllText((Join-Path $dir '.vscode\mcp.json'), $broken)
        try {
            $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -EmitAgentsTo "{1}" < NUL' -f $script:Installer, $dir
            $out = (& cmd /c $cmd 2>&1) -join "`n"
            (Get-Content -LiteralPath (Join-Path $dir '.vscode\mcp.json') -Raw) | Should -Be $broken -Because 'the installer must not destroy a file it cannot read'
            $out | Should -Match 'mcp\.json could not be parsed'
        } finally { if (Test-Path $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue } }
    }

    It 'carries user settings over from the old <folder>.code-workspace when the folder was renamed' {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('pp_rename_' + [guid]::NewGuid().ToString('N'))
        try {
            $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -EmitAgentsTo "{1}" < NUL' -f $script:Installer, $dir
            $null = & cmd /c $cmd 2>&1
            $oldName = (Split-Path $dir -Leaf) + '.code-workspace'
            $w = Get-Content -LiteralPath (Join-Path $dir $oldName) -Raw | ConvertFrom-Json
            $w.settings | Add-Member -NotePropertyName 'editor.rulers' -NotePropertyValue @(100) -Force
            $w.folders = @($w.folders) + @([pscustomobject]@{ path = '../other-root' })
            [System.IO.File]::WriteAllText((Join-Path $dir $oldName), ($w | ConvertTo-Json -Depth 10))
            $renamed = "$dir-renamed"
            Rename-Item -LiteralPath $dir -NewName (Split-Path $renamed -Leaf)
            $dir = $renamed
            $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -EmitAgentsTo "{1}" < NUL' -f $script:Installer, $dir
            $null = & cmd /c $cmd 2>&1
            $newName = (Split-Path $dir -Leaf) + '.code-workspace'
            Test-Path (Join-Path $dir $newName) | Should -BeTrue
            Test-Path (Join-Path $dir $oldName) | Should -BeFalse -Because 'the old workspace file is pruned after migration'
            $w2 = Get-Content -LiteralPath (Join-Path $dir $newName) -Raw | ConvertFrom-Json
            @($w2.settings.'editor.rulers') | Should -Contain 100 -Because 'user settings must survive the rename'
            @($w2.folders.path) | Should -Contain '../other-root'
            $w2.settings.'chat.subagents.allowInvocationsFromSubagents' | Should -BeTrue
        } finally { if (Test-Path $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue } }
    }
}
