# SessionStatus.Tests.ps1
# -------------------------------------------------------------------
# Runs the EMITTED .github/agent-docs/Get-SessionStatus.ps1 against a scratch
# workspace (dry-run emit, no clones) with the user-settings and workspaceStorage
# paths pinned, and asserts the CONFIG block it prints - in particular which
# nested-dispatch SCOPE is in effect (v0.5.2, twin of Fabric v0.7.2):
#   enabled at user level / enabled in .vscode/settings.json only / NOT set
# and the naming of a user-saved .code-workspace that lacks the setting.

BeforeAll {
    . "$PSScriptRoot/Manifest.Helpers.ps1"
    $script:Installer = Get-InstallerPath
    $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ("pp_status_" + [guid]::NewGuid().ToString('N'))
    $script:Ws = Join-Path $script:Root 'ws'
    New-Item -ItemType Directory -Path $script:Ws | Out-Null
    $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -EmitAgentsTo "{1}" < NUL' -f $script:Installer, $script:Ws
    $null = & cmd /c $cmd 2>&1
    $script:Script = Join-Path $script:Ws '.github\agent-docs\Get-SessionStatus.ps1'
    (Test-Path $script:Script) | Should -BeTrue
    $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
    $script:NoUserSettings = Join-Path $script:Root 'no-user-settings.json'   # deliberately absent
    $script:EmptyStorage = Join-Path $script:Root 'empty-storage'
    New-Item -ItemType Directory -Path $script:EmptyStorage | Out-Null

    # A user-saved workspace file (elsewhere on disk) that opens the root via a relative path, without the flag.
    $script:Sess = Join-Path $script:Root 'sessions'
    $script:Storage = Join-Path $script:Root 'storage'
    New-Item -ItemType Directory -Path $script:Sess, (Join-Path $script:Storage 'x') -Force | Out-Null
    $script:Saved = Join-Path $script:Sess 'My Project.code-workspace'
    [IO.File]::WriteAllText($script:Saved, "{`n  // mine`n  `"folders`": [ { `"path`": `"../ws`" }, { `"path`": `"C:/other`" } ],`n  `"settings`": { `"editor.rulers`": [100] }`n}`n", $script:Utf8)
    $uri = 'file:///' + ([Uri]::EscapeUriString($script:Saved.Replace('\', '/')) -replace ':', '%3A')
    [IO.File]::WriteAllText((Join-Path $script:Storage 'x\workspace.json'), (@{ workspace = $uri } | ConvertTo-Json), $script:Utf8)

    # A user settings.json (JSONC) with the flag and one relative location that resolves under the root + one that does not.
    $script:UserSettings = Join-Path $script:Root 'user-settings.json'
    [IO.File]::WriteAllText($script:UserSettings, "{`n  // user prefs`n  `"editor.fontSize`": 14,`n  `"chat.subagents.allowInvocationsFromSubagents`": true,`n  `"chat.agentSkillsLocations`": { `".github/skills`": true, `"does-not-exist/skills`": true, `"C:/abs/skills`": true }`n}`n", $script:Utf8)

    function Invoke-Status {
        param([string]$UserSettings, [string]$Storage, [string]$Cwd = $script:Root)
        $env:PP_WORKSPACE_USER_SETTINGS = $UserSettings
        $env:PP_WORKSPACE_STORAGE = $Storage
        Push-Location $Cwd
        try { return ((& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Script 2>&1) -join "`n") }
        finally { Pop-Location; Remove-Item Env:\PP_WORKSPACE_USER_SETTINGS, Env:\PP_WORKSPACE_STORAGE -ErrorAction SilentlyContinue }
    }
}

AfterAll {
    if ($script:Root -and (Test-Path -LiteralPath $script:Root)) { Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'Get-SessionStatus.ps1 (emitted status script) - baseline' {
    BeforeAll { $script:Out = Invoke-Status -UserSettings $script:NoUserSettings -Storage $script:EmptyStorage -Cwd ([System.IO.Path]::GetTempPath()) }

    It 'resolves the workspace root from its own location, not the CWD' {
        $script:Out | Should -Match ('(?m)^ROOT\s+' + [regex]::Escape($script:Ws))
    }

    It 'prints every section of the status block' {
        foreach ($k in 'SKILLS', 'CONFIG', 'IDENTITY', 'ENV', 'TOOLS') { $script:Out | Should -Match "(?m)^$k\s" -Because "$k line" }
    }

    It 'reports freshness for BOTH Microsoft vendor clones' {
        $script:Out | Should -Match 'power-platform-skills'
        $script:Out | Should -Match 'copilot-studio-plugin'
    }

    It 'says the folder-level setting is in effect ONLY for Open Folder windows when no user-level setting exists' {
        $script:Out | Should -Match 'Nested dispatch: enabled in \.vscode/settings\.json only'
        $script:Out | Should -Match 'Add Folder to Workspace'
        $script:Out | Should -Not -Match 'enabled at user level'
    }

    It 'does not warn about saved workspace files when none open this root' {
        $script:Out | Should -Not -Match 'LACK the nested-dispatch setting'
    }
}

Describe 'Get-SessionStatus.ps1 names a user-saved .code-workspace that lacks nested dispatch' {
    BeforeAll { $script:Out = Invoke-Status -UserSettings $script:NoUserSettings -Storage $script:Storage }

    It 'warns with the exact path of the saved workspace file that lacks the setting' {
        $script:Out | Should -Match 'WARNING: saved workspace file\(s\) that open this folder LACK the nested-dispatch setting'
        $script:Out | Should -Match ([regex]::Escape($script:Saved))
        $script:Out | Should -Match '\(Workspace\)' -Because 'the title-bar tell helps the user recognise the window'
        $script:Out | Should -Match 'answer Y to "Enable the agent team in your VS Code user settings"'
    }

    It 'still reports settings.json as enabled (the two facts are independent) and says it is folder-only' {
        $script:Out | Should -Match 'enabled in \.vscode/settings\.json only'
    }
}

Describe 'Get-SessionStatus.ps1 with the v0.5.2 USER-level setting in effect' {
    BeforeAll { $script:Out = Invoke-Status -UserSettings $script:UserSettings -Storage $script:Storage }

    It 'reports nested dispatch as enabled at user level' {
        $script:Out | Should -Match 'Nested dispatch: enabled at user level \(every VS Code window\)'
    }

    It 'counts only workspace-relative user locations that resolve under this root' {
        $script:Out | Should -Match '1 workspace-relative in user settings \(every window\)'
    }

    It 'no longer warns about saved workspace files (the user-level setting covers them)' {
        $script:Out | Should -Not -Match 'LACK the nested-dispatch setting'
        $script:Out | Should -Match 'need no patch'
    }
}
