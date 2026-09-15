# VendorClone.Tests.ps1
# -------------------------------------------------------------------
# Regression guard for the vendor-refresh path (hardened in v0.5.0):
# `Update-VendorClone` must genuinely bring a stale clone to origin/HEAD
# even though the installer runs with $ErrorActionPreference = 'Stop'
# and git writes its normal progress to stderr. The Fabric twin shipped
# for months with clones 23/166 commits behind because `2>&1 | Out-Null`
# under EAP=Stop turned that stderr into a swallowed terminating error.
#
# Uses a throwaway local bare repository as "upstream" -- no network.

BeforeAll {
    . "$PSScriptRoot/Manifest.Helpers.ps1"
    $script:Installer = Get-InstallerPath

    # Load only the function under test from the real installer source.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Installer, [ref]$null, [ref]$null)
    $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Update-VendorClone' }, $true) | Select-Object -First 1
    $fn | Should -Not -BeNullOrEmpty -Because 'Update-VendorClone must exist in the installer'
    Invoke-Expression $fn.Extent.Text

    $script:Root     = Join-Path ([System.IO.Path]::GetTempPath()) ("pp_vendor_" + [guid]::NewGuid().ToString('N'))
    $script:Upstream = Join-Path $script:Root 'upstream.git'
    $script:Work     = Join-Path $script:Root 'work'
    $script:Clone    = Join-Path $script:Root 'clone'
    New-Item -ItemType Directory -Path $script:Root | Out-Null

    $env:GIT_AUTHOR_NAME = 'test'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 'test'; $env:GIT_COMMITTER_EMAIL = 't@t'
    & git init --bare -q $script:Upstream 2>$null
    & git clone -q $script:Upstream $script:Work 2>$null
    Set-Content (Join-Path $script:Work 'SKILL.md') 'v1'
    & git -C $script:Work add . 2>$null; & git -C $script:Work commit -q -m v1 2>$null
    & git -C $script:Work push -q origin HEAD 2>$null
    # The "installed" clone at v1; a real clone has origin/HEAD.
    & git clone -q $script:Upstream $script:Clone 2>$null
    # Upstream moves on to v2 while the clone stays stale.
    Set-Content (Join-Path $script:Work 'SKILL.md') 'v2'
    & git -C $script:Work commit -q -am v2 2>$null
    & git -C $script:Work push -q origin HEAD 2>$null
    $script:UpstreamHead = (& git -C $script:Work rev-parse HEAD 2>$null)
}

AfterAll {
    if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Update-VendorClone (power-platform-skills mirrors upstream)' {

    It 'starts from a genuinely stale clone (test precondition)' {
        (& git -C $script:Clone rev-parse HEAD 2>$null) | Should -Not -Be $script:UpstreamHead
    }

    It 'brings a stale clone to origin/HEAD under $ErrorActionPreference = Stop and returns $true' {
        $ErrorActionPreference = 'Stop'
        $result = $null
        { $script:result = Update-VendorClone $script:Clone 'test-clone' } | Should -Not -Throw
        $script:result | Should -BeTrue
        (& git -C $script:Clone rev-parse HEAD 2>$null) | Should -Be $script:UpstreamHead
        (Get-Content (Join-Path $script:Clone 'SKILL.md')) | Should -Be 'v2'
    }

    It 'stashes local edits (tracked and untracked) instead of losing them' {
        Set-Content (Join-Path $script:Clone 'SKILL.md') 'local-edit'
        Set-Content (Join-Path $script:Clone 'untracked.txt') 'mine'
        $ErrorActionPreference = 'Stop'
        Update-VendorClone $script:Clone 'test-clone' | Should -BeTrue
        (Get-Content (Join-Path $script:Clone 'SKILL.md')) | Should -Be 'v2'
        Test-Path (Join-Path $script:Clone 'untracked.txt') | Should -BeFalse
        (& git -C $script:Clone stash list 2>$null) | Should -Match 'installer-autostash'
    }

    It 'is idempotent when already at upstream' {
        $before = (& git -C $script:Clone rev-parse HEAD 2>$null)
        Update-VendorClone $script:Clone 'test-clone' | Should -BeTrue
        (& git -C $script:Clone rev-parse HEAD 2>$null) | Should -Be $before
    }

    It 'leaves the caller''s ErrorActionPreference untouched' {
        $ErrorActionPreference = 'Stop'
        Update-VendorClone $script:Clone 'test-clone' | Out-Null
        $ErrorActionPreference | Should -Be 'Stop'
    }

    It 'returns $false without throwing when the path does not exist' {
        $r = $null
        { $script:r = Update-VendorClone (Join-Path $script:Root 'missing') 'missing' } | Should -Not -Throw
        $script:r | Should -BeFalse
    }
}
