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

    $script:SavedGitEnv = @{}
    foreach ($k in 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL') { $script:SavedGitEnv[$k] = [Environment]::GetEnvironmentVariable($k) }
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

    # A `git.cmd` shim placed first on PATH: fails (exit 1) when the sub-command equals -FailOn,
    # otherwise forwards to the real git. Lets us force stash/reset failures deterministically.
    $script:RealGit = (Get-Command git.exe -ErrorAction SilentlyContinue).Source
    function New-GitShim {
        param([string]$FailOn)
        $dir = Join-Path $script:Root ("gitshim_" + $FailOn)
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        # Sub-command is the first arg not starting with '-' after an optional "-C <path>".
        $body = @"
@echo off
setlocal
set "SUB=%1"
if "%1"=="-C" set "SUB=%3"
if /I "%SUB%"=="$FailOn" ( echo fatal: shim forced failure of $FailOn 1>&2 & exit /b 1 )
"$($script:RealGit)" %*
exit /b %ERRORLEVEL%
"@
        [System.IO.File]::WriteAllText((Join-Path $dir 'git.cmd'), $body)
        return $dir
    }
}

AfterAll {
    foreach ($k in $script:SavedGitEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $script:SavedGitEnv[$k]) }
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
        (& git -C $script:Clone rev-parse HEAD 2>$null) | Should -Be (& git -C $script:Clone rev-parse origin/HEAD 2>$null) -Because 'success must mean HEAD equals the upstream commit'
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

    It 'refuses to reset when the stash fails and leaves local edits untouched' {
        # Deterministic double: a `git` shim first on PATH that fails only `stash` and forwards everything else.
        $c2 = Join-Path $script:Root 'clone-stashfail'
        & git clone -q $script:Upstream $c2 2>$null
        & git -C $c2 reset -q --hard HEAD~1 2>$null            # make it stale
        Set-Content (Join-Path $c2 'SKILL.md') 'precious-local-edit'
        $stale = (& git -C $c2 rev-parse HEAD 2>$null)
        $oldPath = $env:PATH
        try {
            $env:PATH = (New-GitShim -FailOn 'stash') + ';' + $oldPath
            $ErrorActionPreference = 'Stop'
            $r = Update-VendorClone $c2 'stashfail-clone'
            $r | Should -BeFalse -Because 'a failed stash must abort the refresh'
            (Get-Content (Join-Path $c2 'SKILL.md')) | Should -Be 'precious-local-edit' -Because 'nothing may be discarded when the stash failed'
            (& git -C $c2 rev-parse HEAD 2>$null) | Should -Be $stale
        } finally { $env:PATH = $oldPath }
    }

    It 'returns $false (never "already at upstream") when the reset itself fails' {
        # This is the exact false-success path: a later successful rev-parse used to overwrite $LASTEXITCODE.
        $c3 = Join-Path $script:Root 'clone-resetfail'
        & git clone -q $script:Upstream $c3 2>$null
        & git -C $c3 reset -q --hard HEAD~1 2>$null
        $stale = (& git -C $c3 rev-parse HEAD 2>$null)
        $oldPath = $env:PATH
        try {
            $env:PATH = (New-GitShim -FailOn 'reset') + ';' + $oldPath
            $ErrorActionPreference = 'Stop'
            $out = Update-VendorClone $c3 'resetfail-clone' *>&1 | Out-String
            $r = Update-VendorClone $c3 'resetfail-clone'
            $r | Should -BeFalse
            (& git -C $c3 rev-parse HEAD 2>$null) | Should -Be $stale -Because 'the clone must be left exactly as it was'
            $out | Should -Not -Match 'already at upstream'
            $out | Should -Match 'reset to upstream failed' -Because 'the test must prove the reset path was actually reached (not an earlier bail-out)'
        } finally { $env:PATH = $oldPath }
    }

    It 'tells the user their edits are in the stash when a dirty clone fails to reset' {
        $c4 = Join-Path $script:Root 'clone-dirty-resetfail'
        & git clone -q $script:Upstream $c4 2>$null
        & git -C $c4 reset -q --hard HEAD~1 2>$null
        Set-Content (Join-Path $c4 'SKILL.md') 'edit-to-recover'
        $oldPath = $env:PATH
        try {
            $env:PATH = (New-GitShim -FailOn 'reset') + ';' + $oldPath
            $ErrorActionPreference = 'Stop'
            $out = Update-VendorClone $c4 'dirty-resetfail' *>&1 | Out-String
            $out | Should -Match 'stash pop' -Because 'the message must say how to get the stashed edits back'
            (& git -C $c4 stash list 2>$null) | Should -Match 'installer-autostash'
        } finally { $env:PATH = $oldPath }
    }

    It 'skips the refresh (returns $false, touches nothing) when git status cannot be trusted' {
        $c5 = Join-Path $script:Root 'clone-statusfail'
        & git clone -q $script:Upstream $c5 2>$null
        & git -C $c5 reset -q --hard HEAD~1 2>$null
        Set-Content (Join-Path $c5 'SKILL.md') 'unknown-state-edit'
        $stale = (& git -C $c5 rev-parse HEAD 2>$null)
        $oldPath = $env:PATH
        try {
            $env:PATH = (New-GitShim -FailOn 'status') + ';' + $oldPath
            $ErrorActionPreference = 'Stop'
            $r = Update-VendorClone $c5 'statusfail-clone'
            $r | Should -BeFalse
            (& git -C $c5 rev-parse HEAD 2>$null) | Should -Be $stale
            (Get-Content (Join-Path $c5 'SKILL.md')) | Should -Be 'unknown-state-edit' -Because 'an unknown working-tree state must never be reset over'
        } finally { $env:PATH = $oldPath }
    }

    It 'follows upstream when its default branch was renamed after the clone was made' {
        # Upstream renames master/main -> trunk and moves on; the clone still has a stale origin/HEAD.
        $c6 = Join-Path $script:Root 'clone-renamed-default'
        & git clone -q $script:Upstream $c6 2>$null
        $oldDefault = (& git -C $script:Work rev-parse --abbrev-ref HEAD 2>$null)
        & git -C $script:Work branch -m $oldDefault trunk 2>$null
        Set-Content (Join-Path $script:Work 'SKILL.md') 'v3-on-trunk'
        & git -C $script:Work commit -q -am v3 2>$null
        & git -C $script:Work push -q origin trunk 2>$null
        & git -C $script:Upstream symbolic-ref HEAD refs/heads/trunk 2>$null
        & git -C $script:Work push -q origin --delete $oldDefault 2>$null
        $trunkHead = (& git -C $script:Work rev-parse HEAD 2>$null)
        $ErrorActionPreference = 'Stop'
        Update-VendorClone $c6 'renamed-default' | Should -BeTrue
        (& git -C $c6 rev-parse HEAD 2>$null) | Should -Be $trunkHead
        (Get-Content (Join-Path $c6 'SKILL.md')) | Should -Be 'v3-on-trunk'
    }
}
