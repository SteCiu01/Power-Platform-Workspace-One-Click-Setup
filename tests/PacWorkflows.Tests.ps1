# PacWorkflows.Tests.ps1
# -------------------------------------------------------------------
# Behavioural guard for the generated scripts/pac-workflows.ps1 helper.
# Runs the REAL emitted script inside a throwaway workspace-shaped git repo
# with a fake `pac` on PATH (a .cmd shim driven by env vars), so failure paths
# are exercised without any tenant or network:
#   * a failed pack must stop before import and never commit
#   * the label must be mapped (environments.json) or given as -EnvironmentUrl,
#     and the active org (`pac org who`) must match it
#   * Production is classified from the map (not the name) and needs -ConfirmProd
#   * the post-import check uses exact unique names and fails closed
#   * paths are anchored to the workspace, not the caller's CWD
#   * only the solution folder is staged, never the whole workspace

BeforeAll {
    . "$PSScriptRoot/Manifest.Helpers.ps1"
    $script:Installer = Get-InstallerPath
    $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ("pp_pacwf_" + [guid]::NewGuid().ToString('N'))
    $script:Emit = Join-Path $script:Root 'emit'
    $script:Shim = Join-Path $script:Root 'shim'
    $script:Repo = Join-Path $script:Root 'repo'
    $script:Elsewhere = Join-Path $script:Root 'elsewhere'
    New-Item -ItemType Directory -Path $script:Shim, $script:Repo, $script:Elsewhere -Force | Out-Null

    $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -EmitAgentsTo "{1}" < NUL' -f $script:Installer, $script:Emit
    $null = & cmd /c $cmd 2>&1
    (Test-Path (Join-Path $script:Emit 'scripts\pac-workflows.ps1')) | Should -BeTrue
    # The helper anchors itself to <workspace>\scripts\, so place it exactly there.
    New-Item -ItemType Directory -Path (Join-Path $script:Repo 'scripts'), (Join-Path $script:Repo '.github\agents'), (Join-Path $script:Repo '.github\agent-docs') -Force | Out-Null
    Copy-Item (Join-Path $script:Emit 'scripts\pac-workflows.ps1') (Join-Path $script:Repo 'scripts\pac-workflows.ps1') -Force
    $script:Helper = Join-Path $script:Repo 'scripts\pac-workflows.ps1'
    # Environment map: LIVE is Production despite having no 'prod' in its name or URL.
    @'
{ "DEV":  { "url": "https://orgdev.crm.dynamics.com",  "production": false },
  "TEST": { "url": "https://orgtest.crm.dynamics.com", "production": false },
  "LIVE": { "url": "https://treasury-live.crm.dynamics.com", "production": true },
  "PROD": { "url": "https://orgprod.crm.dynamics.com", "production": true } }
'@ | Set-Content (Join-Path $script:Repo '.github\agent-docs\environments.json') -Encoding UTF8

    # Fake pac: `pac org who` prints PAC_FAKE_ORG; `pac solution pack` exits PAC_FAKE_PACK_EXIT
    # (creating the zip only on success); `pac solution list` prints JSON with PAC_FAKE_LISTED
    # and exits PAC_FAKE_LIST_EXIT; every call is appended to PAC_FAKE_LOG.
    $shim = @'
@echo off
echo %*>>"%PAC_FAKE_LOG%"
if "%1 %2"=="org who" goto who
if "%1 %2"=="solution pack" goto pack
if "%1 %2"=="solution export" goto export
if "%1 %2"=="solution unpack" goto unpack
if "%1 %2"=="solution list" goto list
exit /b 0
:who
echo Connected as user@contoso.com
echo Org URL: %PAC_FAKE_ORG%
echo Friendly Name: %PAC_FAKE_ORGNAME%
exit /b 0
:pack
if "%PAC_FAKE_PACK_EXIT%"=="0" echo fake>"%4"
exit /b %PAC_FAKE_PACK_EXIT%
:export
echo fake>"%6"
exit /b 0
:unpack
mkdir "%6\Other" 2>nul
echo ^<x/^>>"%6\Other\Solution.xml"
exit /b 0
:list
if not "%PAC_FAKE_LIST_EXIT%"=="0" exit /b %PAC_FAKE_LIST_EXIT%
echo [{"SolutionUniqueName":"%PAC_FAKE_LISTED%","FriendlyName":"x","VersionNumber":"1.0.0.0"}]
exit /b 0
'@
    [System.IO.File]::WriteAllText((Join-Path $script:Shim 'pac.cmd'), $shim)

    $script:SavedGitEnv = @{}
    foreach ($k in 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL') { $script:SavedGitEnv[$k] = [Environment]::GetEnvironmentVariable($k) }
    $env:GIT_AUTHOR_NAME = 'test'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 'test'; $env:GIT_COMMITTER_EMAIL = 't@t'
    & git -C $script:Repo init -q 2>$null
    & git -C $script:Repo config user.name test 2>$null; & git -C $script:Repo config user.email t@t 2>$null
    # An unpacked solution plus an unrelated in-progress user file that must never be swept into a commit.
    New-Item -ItemType Directory -Path (Join-Path $script:Repo 'DEV\Sol\Other') -Force | Out-Null
    Set-Content (Join-Path $script:Repo 'DEV\Sol\Other\Solution.xml') '<x/>'
    Set-Content (Join-Path $script:Repo 'notes.txt') 'user work in progress'
    Set-Content (Join-Path $script:Repo 'staged-by-user.txt') 'user staged this on purpose'
    & git -C $script:Repo add DEV scripts .github 2>$null; & git -C $script:Repo commit -q -m base 2>$null
    & git -C $script:Repo add staged-by-user.txt 2>$null   # left STAGED on purpose - the helper must not commit it

    function Invoke-Helper {
        param([string]$HelperArgs, [string]$Org = 'https://orgdev.crm.dynamics.com/', [string]$OrgName = 'Contoso DEV', [string]$PackExit = '0', [string]$Listed = 'Sol', [string]$ListExit = '0', [string]$Cwd = $script:Repo)
        $log = Join-Path $script:Root ("log_" + [guid]::NewGuid().ToString('N') + '.txt')
        $envBlock = "set PAC_FAKE_ORG=$Org&& set PAC_FAKE_ORGNAME=$OrgName&& set PAC_FAKE_PACK_EXIT=$PackExit&& set PAC_FAKE_LISTED=$Listed&& set PAC_FAKE_LIST_EXIT=$ListExit&& set PAC_FAKE_LOG=$log&& set PATH=$($script:Shim);%PATH%"
        $full = "cd /d `"$Cwd`" && $envBlock && powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$($script:Helper)`" $HelperArgs"
        $out = & cmd /c $full 2>&1 | Out-String
        $calls = if (Test-Path $log) { Get-Content $log } else { @() }
        return [pscustomobject]@{ Exit = $LASTEXITCODE; Out = $out; Calls = @($calls) }
    }
}

AfterAll {
    foreach ($k in $script:SavedGitEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $script:SavedGitEnv[$k]) }
    if ($script:Root -and (Test-Path -LiteralPath $script:Root)) { Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'pac-workflows.ps1 (generated helper) - target resolution' {

    It 'refuses an unmapped label without -EnvironmentUrl instead of using the active profile' {
        $r = Invoke-Helper -HelperArgs '-Action push -SolutionName Sol -Environment UAT'
        $r.Exit | Should -Be 5
        $r.Out | Should -Match 'not mapped'
        ($r.Calls -join "`n") | Should -Not -Match 'solution (pack|import)'
    }

    It 'refuses when the active org does not match the mapped label' {
        $r = Invoke-Helper -HelperArgs '-Action push -SolutionName Sol -Environment TEST'
        $r.Exit | Should -Be 4
        ($r.Calls -join "`n") | Should -Not -Match 'solution (pack|import)'
    }

    It 'refuses when the active org does not match an explicit -EnvironmentUrl' {
        $r = Invoke-Helper -HelperArgs '-Action push -SolutionName Sol -Environment UAT -EnvironmentUrl https://orguat.crm.dynamics.com'
        $r.Exit | Should -Be 4
    }

    It 'rejects names with dots or path characters' {
        (Invoke-Helper -HelperArgs '-Action push -SolutionName .. -Environment DEV').Exit | Should -Be 1
        (Invoke-Helper -HelperArgs '-Action push -SolutionName Sol -Environment ..\DEV').Exit | Should -Be 1
    }
}

Describe 'pac-workflows.ps1 (generated helper) - Production gate' {

    It 'blocks a push to a map-classified Production org whose name has no "prod" in it' {
        New-Item -ItemType Directory -Path (Join-Path $script:Repo 'LIVE\Sol\Other') -Force | Out-Null
        Set-Content (Join-Path $script:Repo 'LIVE\Sol\Other\Solution.xml') '<x/>'
        $r = Invoke-Helper -HelperArgs '-Action push -SolutionName Sol -Environment LIVE' -Org 'https://treasury-live.crm.dynamics.com/' -OrgName 'Treasury Live'
        $r.Exit | Should -Be 2
        $r.Out | Should -Match 'BLOCKED'
        ($r.Calls -join "`n") | Should -Not -Match 'solution import'
    }

    It 'still blocks when an unmapped org merely looks like Production' {
        $r = Invoke-Helper -HelperArgs '-Action push -SolutionName Sol -Environment UAT -EnvironmentUrl https://orgprod.crm.dynamics.com' -Org 'https://orgprod.crm.dynamics.com/' -OrgName 'Contoso PROD'
        $r.Exit | Should -Be 2
    }

    It 'blocks a PROD-labelled push without -ConfirmProd and allows it with the switch' {
        New-Item -ItemType Directory -Path (Join-Path $script:Repo 'PROD\Sol\Other') -Force | Out-Null
        Set-Content (Join-Path $script:Repo 'PROD\Sol\Other\Solution.xml') '<x/>'
        (Invoke-Helper -HelperArgs '-Action push -SolutionName Sol -Environment PROD' -Org 'https://orgprod.crm.dynamics.com/' -OrgName 'Contoso PROD').Exit | Should -Be 2
        $r = Invoke-Helper -HelperArgs '-Action push -SolutionName Sol -Environment PROD -ConfirmProd' -Org 'https://orgprod.crm.dynamics.com/' -OrgName 'Contoso PROD'
        $r.Exit | Should -Be 0
        ($r.Calls -join "`n") | Should -Match 'solution import .*--environment https://orgprod\.crm\.dynamics\.com'
    }
}

Describe 'pac-workflows.ps1 (generated helper) - failure paths and commit scope' {

    It 'stops after a failed pack: no import, no commit, non-zero exit' {
        $head = (& git -C $script:Repo rev-parse HEAD 2>$null)
        $r = Invoke-Helper -HelperArgs '-Action push -SolutionName Sol -Environment DEV' -PackExit '42'
        $r.Exit | Should -Be 42
        $r.Out | Should -Match 'pac solution pack failed'
        ($r.Calls -join "`n") | Should -Not -Match 'solution import' -Because 'a stale package must never be imported'
        (& git -C $script:Repo rev-parse HEAD 2>$null) | Should -Be $head
        Test-Path (Join-Path $script:Repo 'deploy\Sol.zip') | Should -BeFalse
    }

    It 'never imports a stale package left over from an earlier run' {
        New-Item -ItemType Directory -Path (Join-Path $script:Repo 'deploy') -Force | Out-Null
        Set-Content (Join-Path $script:Repo 'deploy\Sol.zip') 'yesterday'
        $r = Invoke-Helper -HelperArgs '-Action push -SolutionName Sol -Environment DEV' -PackExit '42'
        $r.Exit | Should -Be 42
        Test-Path (Join-Path $script:Repo 'deploy\Sol.zip') | Should -BeFalse -Because 'the old zip is deleted before packing'
        ($r.Calls -join "`n") | Should -Not -Match 'solution import'
    }

    It 'a successful push imports the freshly built package, verifies by exact name, commits only the solution folder and leaves the user index alone' {
        Set-Content (Join-Path $script:Repo 'DEV\Sol\Other\Solution.xml') '<x version="2"/>'
        $r = Invoke-Helper -HelperArgs '-Action push -SolutionName Sol -Environment DEV' -Cwd $script:Elsewhere
        $r.Exit | Should -Be 0
        $r.Out | Should -Match 'Push complete'
        ($r.Calls -join "`n") | Should -Match 'solution import --path .*deploy\\Sol\.zip --environment https://orgdev\.crm\.dynamics\.com'
        ($r.Calls -join "`n") | Should -Match 'solution list --environment https://orgdev\.crm\.dynamics\.com --json'
        $committed = @(& git -C $script:Repo show --name-only --format= HEAD 2>$null)
        $committed | Should -Contain 'DEV/Sol/Other/Solution.xml'
        $committed | Should -Not -Contain 'notes.txt' -Because 'user work outside the solution must not be swept into the commit'
        $committed | Should -Not -Contain 'staged-by-user.txt' -Because 'something the user staged themselves is not ours to commit'
        (& git -C $script:Repo status --porcelain -- staged-by-user.txt 2>$null) | Should -Match '^A ' -Because 'the user''s staged file is still staged, untouched'
        Test-Path (Join-Path $script:Elsewhere 'deploy') | Should -BeFalse -Because 'paths are anchored to the workspace, not the caller''s CWD'
    }

    It 'fails when the import reports success but the exact unique name is not listed (substring is not enough)' {
        $head = (& git -C $script:Repo rev-parse HEAD 2>$null)
        Set-Content (Join-Path $script:Repo 'DEV\Sol\Other\Solution.xml') '<x version="3"/>'
        $r = Invoke-Helper -HelperArgs '-Action push -SolutionName Sol -Environment DEV' -Listed 'SolBackup'
        $r.Exit | Should -Be 6
        $r.Out | Should -Match 'not listed'
        (& git -C $script:Repo rev-parse HEAD 2>$null) | Should -Be $head
    }

    It 'fails closed when the post-import list itself fails' {
        $head = (& git -C $script:Repo rev-parse HEAD 2>$null)
        $r = Invoke-Helper -HelperArgs '-Action push -SolutionName Sol -Environment DEV' -ListExit '9'
        $r.Exit | Should -Be 7
        $r.Out | Should -Match 'could not run'
        (& git -C $script:Repo rev-parse HEAD 2>$null) | Should -Be $head
    }

    It 'pull exports and unpacks against the verified org and commits only that folder' {
        $r = Invoke-Helper -HelperArgs '-Action pull -SolutionName Sol2 -Environment DEV'
        $r.Exit | Should -Be 0
        ($r.Calls -join "`n") | Should -Match 'solution export --name Sol2 .*--environment https://orgdev\.crm\.dynamics\.com'
        $committed = @(& git -C $script:Repo show --name-only --format= HEAD 2>$null)
        $committed | Should -Contain 'DEV/Sol2/Other/Solution.xml'
        $committed | Should -Not -Contain 'staged-by-user.txt'
    }
}
