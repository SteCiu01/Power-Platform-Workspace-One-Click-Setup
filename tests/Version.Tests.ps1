#requires -Version 5.1
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot/Manifest.Helpers.ps1"
    $script:InstallerPath = Get-InstallerPath
    $script:Raw = Get-Content $script:InstallerPath -Raw
    $script:Manifest = Get-AgentManifest
}

Describe 'Version single source of truth' {

    It 'installer $productVersion is a semantic version' {
        $m = [regex]::Match($script:Raw, "(?m)^\`$productVersion\s*=\s*'(?<v>[^']+)'")
        $m.Success | Should -BeTrue
        $m.Groups['v'].Value | Should -Match '^\d+\.\d+\.\d+$'
    }

    It 'installer $productVersion matches the embedded manifest productVersion' {
        $m = [regex]::Match($script:Raw, "(?m)^\`$productVersion\s*=\s*'(?<v>[^']+)'")
        $installerVersion = $m.Groups['v'].Value
        $installerVersion | Should -Be $script:Manifest.productVersion -Because 'the two version stamps must not drift'
    }

    It 'manifest declares an integer schemaVersion' {
        ($script:Manifest.schemaVersion -is [int] -or $script:Manifest.schemaVersion -is [long]) | Should -BeTrue
    }

    It 'README status heading matches the installer version (no doc drift)' {
        $readmePath = Join-Path $PSScriptRoot '..\README.md'
        (Test-Path $readmePath) | Should -BeTrue
        $readme = Get-Content $readmePath -Raw
        $ver = $script:Manifest.productVersion
        $readme | Should -Match ([regex]::Escape("Current status (v$ver)")) -Because 'the README status heading must track the current version'
    }

    It 'CHANGELOG top entry matches the installer version (no doc drift)' {
        $changelogPath = Join-Path $PSScriptRoot '..\CHANGELOG.md'
        (Test-Path $changelogPath) | Should -BeTrue
        $changelog = Get-Content $changelogPath -Raw
        $ver = $script:Manifest.productVersion
        $first = [regex]::Match($changelog, '(?m)^## \[(v[^\]]+)\]')
        $first.Success | Should -BeTrue
        $first.Groups[1].Value | Should -Be "v$ver" -Because 'the NEWEST (first) CHANGELOG entry must document the current version, not merely some entry'
    }

    It 'README test count matches the number of It blocks in the suite (no stale claims)' {
        $readme = Get-Content (Join-Path $PSScriptRoot '..\README.md') -Raw -Encoding UTF8
        $claimed = [regex]::Match($readme, '\*\*Working\*\*\s+\S+\s+(\d+) tests')
        $claimed.Success | Should -BeTrue -Because 'the status table states the suite size'
        $actual = 0
        foreach ($f in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' -File) {
            $actual += ([regex]::Matches((Get-Content -LiteralPath $f.FullName -Raw), "(?m)^\s*It\s+'")).Count
        }
        [int]$claimed.Groups[1].Value | Should -Be $actual
    }

    It '.bat launcher banner and window title match the installer version' {
        $batPath = Join-Path (Split-Path $script:InstallerPath -Parent) 'Setup-PowerPlatformWorkspace.bat'
        (Test-Path $batPath) | Should -BeTrue
        $bat = Get-Content $batPath -Raw
        $ver = $script:Manifest.productVersion
        $bat | Should -Match ([regex]::Escape("One-click Setup v$ver")) -Because 'the banner the user sees first must show the current version'
        $bat | Should -Match ([regex]::Escape("Setup v$ver")) -Because 'the console window title must show the current version'
        # No other version string may linger in the launcher.
        ([regex]::Matches($bat, 'v\d+\.\d+\.\d+') | ForEach-Object { $_.Value } | Sort-Object -Unique) | Should -Be @("v$ver")
    }
}
