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
}
