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
        $changelog | Should -Match ([regex]::Escape("## [v$ver]")) -Because 'the newest CHANGELOG entry must document the current version'
    }
}
