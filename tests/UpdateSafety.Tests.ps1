# UpdateSafety.Tests.ps1
# -------------------------------------------------------------------
# Regression guards for the v0.5.2 "works however you open the folder" change
# (twin of the Fabric workspace's v0.7.2): the user-level enablement must edit
# the VS Code user settings.json IN PLACE and idempotently, and the fallback
# that patches user-saved .code-workspace files must add only what is missing.
# Helpers are AST-extracted from the real installer so the tests exercise
# shipped code, not a copy.

BeforeAll {
    . "$PSScriptRoot/Manifest.Helpers.ps1"
    $script:Installer = Get-InstallerPath
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Installer, [ref]$null, [ref]$null)
    foreach ($name in 'ConvertFrom-JsonLenient', 'ConvertTo-SkillLocationKey', 'Get-UserWorkspaceFilesForRoot', 'Update-UserWorkspaceFile', 'Find-JsonObjectEnd', 'Find-LineCommentStart', 'Add-JsonMemberBeforeClose', 'Update-UserSettingsInPlace') {
        $fn = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true) | Select-Object -First 1
        $fn | Should -Not -BeNullOrEmpty -Because "$name must exist in the installer"
        Invoke-Expression $fn.Extent.Text
    }
    $script:Root = Join-Path ([System.IO.Path]::GetTempPath()) ("pp_update_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:Root | Out-Null
    $script:Utf8 = New-Object System.Text.UTF8Encoding($false)
}

AfterAll {
    if ($script:Root -and (Test-Path -LiteralPath $script:Root)) {
        Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'ConvertFrom-JsonLenient (VS Code JSONC is not "malformed")' {

    It 'parses comments and trailing commas the way VS Code does' {
        $jsonc = @"
{
  // user comment
  "editor.fontSize": 14, /* block */
  "url": "https://example.com/not/a/comment",
  "list": [1, 2, 3,],
}
"@
        $o = ConvertFrom-JsonLenient $jsonc
        $o.'editor.fontSize' | Should -Be 14
        $o.url | Should -Be 'https://example.com/not/a/comment' -Because '// inside a string literal is not a comment'
        @($o.list).Count | Should -Be 3
    }

    It 'returns null for genuinely broken JSON' {
        ConvertFrom-JsonLenient '{ "a": ' | Should -BeNullOrEmpty
    }
}

Describe 'User-saved .code-workspace files (window-scoped settings) - fallback patch' {

    BeforeAll {
        # Layout: <Root>\ws is the installed workspace; a saved file in <Root>\sessions\sub
        # opens it via a relative path; fake workspaceStorage points at that file.
        $script:WsRoot = Join-Path $script:Root 'ws'
        $script:Sess = Join-Path $script:Root 'sessions\sub'
        $script:Storage = Join-Path $script:Root 'storage'
        New-Item -ItemType Directory -Path $script:WsRoot, $script:Sess, (Join-Path $script:Storage 'a') -Force | Out-Null
        $script:Saved = Join-Path $script:Sess 'Mine.code-workspace'
        [IO.File]::WriteAllText($script:Saved, "{`n`t// kept by the user`n`t`"folders`": [ { `"path`": `"../../ws`" } ],`n`t`"settings`": { `"chat.agentSkillsLocations`": { `"copilot-studio-plugin/skills`": true, `"C:/my/own/skills`": true } }`n}`n", $script:Utf8)
        $uri = 'file:///' + ([Uri]::EscapeUriString($script:Saved.Replace('\', '/')) -replace ':', '%3A')
        [IO.File]::WriteAllText((Join-Path $script:Storage 'a\workspace.json'), (@{ workspace = $uri } | ConvertTo-Json), $script:Utf8)
        $script:Required = @(
            (Join-Path $script:WsRoot '.github\skills'),
            (Join-Path $script:WsRoot 'copilot-studio-plugin\skills'),
            (Join-Path $script:WsRoot 'power-platform-skills\plugins\canvas-apps\skills')
        )
    }

    It 'reports the dispatch setting and only the skill locations the file does not already have' {
        $r = @(Get-UserWorkspaceFilesForRoot -RootPath $script:WsRoot -StorageRoot $script:Storage -RequiredSkillLocations $script:Required)
        $r.Count | Should -Be 1
        $r[0].Path | Should -Be $script:Saved
        $r[0].NestedDispatch | Should -BeFalse
        @($r[0].MissingSkillLocations).Count | Should -Be 2
        @($r[0].MissingSkillLocations) | Should -Not -Contain (Join-Path $script:WsRoot 'copilot-studio-plugin\skills')
    }

    It 'patch adds only what is missing, keeps user entries, writes no .bak, and reports dropped comments' {
        $r = @(Get-UserWorkspaceFilesForRoot -RootPath $script:WsRoot -StorageRoot $script:Storage -RequiredSkillLocations $script:Required)
        $hadComments = Update-UserWorkspaceFile -Path $script:Saved -SkillLocations $r[0].MissingSkillLocations
        $hadComments | Should -BeTrue
        Test-Path -LiteralPath "$($script:Saved).bak" | Should -BeFalse
        $w = Get-Content -LiteralPath $script:Saved -Raw | ConvertFrom-Json
        $w.settings.'chat.subagents.allowInvocationsFromSubagents' | Should -BeTrue
        $w.settings.'chat.agentSkillsLocations'.'C:/my/own/skills' | Should -BeTrue -Because 'user entries are preserved'
        $w.settings.'chat.agentSkillsLocations'.'copilot-studio-plugin/skills' | Should -BeTrue -Because 'an equivalent relative entry is not duplicated'
        $w.settings.'chat.agentSkillsLocations'.(Join-Path $script:WsRoot '.github\skills') | Should -BeTrue
        $w.folders[0].path | Should -Be '../../ws'
        (Get-Content -LiteralPath $script:Saved -Raw)[0] | Should -Be '{' -Because 'no BOM'
    }

    It 'is idempotent: after the patch a re-run finds nothing to update' {
        $r = @(Get-UserWorkspaceFilesForRoot -RootPath $script:WsRoot -StorageRoot $script:Storage -RequiredSkillLocations $script:Required |
            Where-Object { -not $_.NestedDispatch -or $_.MissingSkillLocations.Count -gt 0 })
        $r.Count | Should -Be 0
    }
}

Describe 'Update-UserSettingsInPlace (v0.5.2: USER-level enablement, edited in place)' {

    BeforeAll {
        $script:UsDir = Join-Path $script:Root 'user-settings'
        New-Item -ItemType Directory -Path $script:UsDir -Force | Out-Null
        $script:Locs = @('.github/skills', 'copilot-studio-plugin/skills', 'power-platform-skills/plugins/canvas-apps/skills')
    }

    It 'appends the flag and a relative skill-location block to a JSONC file, preserving comments, order and formatting' {
        $p = Join-Path $script:UsDir 'jsonc.json'
        $orig = "{`r`n    // my editor prefs`r`n    `"editor.fontSize`": 14,`r`n    `"url`": `"https://example.com//not-a-comment`",`r`n    /* block */`r`n    `"files.autoSave`": `"off`" // trailing note`r`n}`r`n"
        [IO.File]::WriteAllText($p, $orig, $script:Utf8)
        $r = Update-UserSettingsInPlace -Path $p -SkillLocations $script:Locs
        $r.Changed | Should -BeTrue
        $r.FlagAdded | Should -BeTrue
        @($r.LocationsAdded).Count | Should -Be 3
        $txt = Get-Content -LiteralPath $p -Raw
        $txt | Should -Match '// my editor prefs'
        $txt | Should -Match '/\* block \*/'
        $txt | Should -Match '// trailing note'
        $txt | Should -Match 'https://example.com//not-a-comment'
        $txt.IndexOf('"editor.fontSize"') | Should -BeLessThan $txt.IndexOf('"files.autoSave"')
        $txt.IndexOf('"files.autoSave"') | Should -BeLessThan $txt.IndexOf('"chat.subagents.allowInvocationsFromSubagents"')
        $txt | Should -Match "`r`n" -Because 'line endings are preserved'
        $o = ConvertFrom-JsonLenient $txt
        $o.'editor.fontSize' | Should -Be 14
        $o.'chat.subagents.allowInvocationsFromSubagents' | Should -BeTrue
        $o.'chat.agentSkillsLocations'.'copilot-studio-plugin/skills' | Should -BeTrue
        ([IO.File]::ReadAllBytes($p))[0] | Should -Be 123 -Because 'no BOM is introduced'
    }

    It 'flips an explicit false to true and merges only the missing locations into an existing block (user entries kept)' {
        $p = Join-Path $script:UsDir 'existing.json'
        $orig = "{`n  `"chat.subagents.allowInvocationsFromSubagents`": false,`n  `"chat.agentSkillsLocations`": {`n    `"C:/my/own/skills`": true,`n    `"copilot-studio-plugin/skills`": true // already here`n  },`n  `"zoom`": 1`n}`n"
        [IO.File]::WriteAllText($p, $orig, $script:Utf8)
        $r = Update-UserSettingsInPlace -Path $p -SkillLocations $script:Locs
        $r.FlagAdded | Should -BeTrue
        @($r.LocationsAdded) | Should -Not -Contain 'copilot-studio-plugin/skills'
        @($r.LocationsAdded).Count | Should -Be 2
        $txt = Get-Content -LiteralPath $p -Raw
        $txt | Should -Match '// already here'
        $txt | Should -Not -Match "`r`n" -Because 'LF files stay LF'
        $o = ConvertFrom-JsonLenient $txt
        $o.'chat.subagents.allowInvocationsFromSubagents' | Should -BeTrue
        $o.'chat.agentSkillsLocations'.'C:/my/own/skills' | Should -BeTrue
        $o.'chat.agentSkillsLocations'.'.github/skills' | Should -BeTrue
        $o.zoom | Should -Be 1
    }

    It 'is idempotent and never writes absolute or ~ paths' {
        $p = Join-Path $script:UsDir 'existing.json'
        $before = Get-Content -LiteralPath $p -Raw
        $r = Update-UserSettingsInPlace -Path $p -SkillLocations ($script:Locs + @('C:\abs\skills', '~/.vscode/extensions/x/skills'))
        $r.Changed | Should -BeFalse
        (Get-Content -LiteralPath $p -Raw) | Should -Be $before
    }

    It 'creates the file when absent, keeps a BOM when present, and refuses a broken file' {
        $new = Join-Path $script:UsDir 'sub\new.json'
        (Update-UserSettingsInPlace -Path $new -SkillLocations $script:Locs).Changed | Should -BeTrue
        (ConvertFrom-JsonLenient (Get-Content -LiteralPath $new -Raw)).'chat.subagents.allowInvocationsFromSubagents' | Should -BeTrue

        $bom = Join-Path $script:UsDir 'bom.json'
        [IO.File]::WriteAllText($bom, "{`r`n  `"a`": 1`r`n}`r`n", (New-Object System.Text.UTF8Encoding($true)))
        Update-UserSettingsInPlace -Path $bom -SkillLocations @() | Out-Null
        $b = [IO.File]::ReadAllBytes($bom); ($b[0] -eq 0xEF -and $b[1] -eq 0xBB) | Should -BeTrue
        (ConvertFrom-JsonLenient (Get-Content -LiteralPath $bom -Raw)).a | Should -Be 1

        $bad = Join-Path $script:UsDir 'bad.json'
        [IO.File]::WriteAllText($bad, '{ "a": ', $script:Utf8)
        { Update-UserSettingsInPlace -Path $bad -SkillLocations @() } | Should -Throw
        (Get-Content -LiteralPath $bad -Raw) | Should -Be '{ "a": ' -Because 'a broken file is never rewritten'
    }
}

Describe 'Installer source: the user-level prompt is wired in (static)' {
    BeforeAll { $script:Src = Get-Content -LiteralPath $script:Installer -Raw }

    It 'asks before touching user settings, defaults to Yes, and skips in emit mode' {
        $script:Src | Should -Match 'Enable the agent team in your VS Code user settings now\? \(Y/n\)'
        $script:Src | Should -Match "if \(-not \`$EmitAgentsTo\) \{\s*\r?\n\s*\`$relativeSkillLocs"
    }

    It 'runs the saved-workspace fallback only when the user-level prompt was declined' {
        $script:Src | Should -Match 'if \(-not \$EmitAgentsTo -and -not \$userLevelEnabled\)'
    }

    It 'lets tests pin the user settings and workspaceStorage paths' {
        $script:Src | Should -Match 'PP_WORKSPACE_USER_SETTINGS'
        $script:Src | Should -Match 'PP_WORKSPACE_STORAGE'
    }
}
