BeforeAll {
    . (Join-Path $PSScriptRoot 'Manifest.Helpers.ps1')
    $script:manifest = Get-AgentManifest
    $script:agents   = $script:manifest.agents
    $script:byId     = @{}
    foreach ($a in $script:agents) { $script:byId[$a.id] = $a }
    $script:names    = @($script:agents.displayName)
}

Describe 'Hierarchy - parent references' {
    It 'exactly one root (parent = null) which is the master' {
        $roots = @($script:agents | Where-Object { $null -eq $_.parent })
        $roots.Count | Should -Be 1
        $roots[0].id | Should -Be 'power-platform-master'
    }

    It 'every non-null parent resolves to an existing agent id' {
        foreach ($a in $script:agents | Where-Object { $null -ne $_.parent }) {
            $script:byId.ContainsKey($a.parent) | Should -BeTrue -Because "parent '$($a.parent)' of '$($a.id)' must exist"
        }
    }

    It 'the parent chain has no cycles and reaches the master' {
        foreach ($a in $script:agents) {
            $seen = @{}
            $cur = $a
            while ($null -ne $cur.parent) {
                $seen.ContainsKey($cur.id) | Should -BeFalse -Because "cycle detected at '$($cur.id)'"
                $seen[$cur.id] = $true
                $cur = $script:byId[$cur.parent]
            }
            $cur.id | Should -Be 'power-platform-master'
        }
    }
}

Describe 'Hierarchy - delegation (allowedChildren)' {
    It 'every allowedChildren entry resolves to an existing display name' {
        foreach ($a in $script:agents) {
            foreach ($child in $a.allowedChildren) {
                $script:names -contains $child | Should -BeTrue -Because "'$($a.id)' delegates to unknown '$child'"
            }
        }
    }

    It 'only agents that hold the "agent" tool may declare children' {
        foreach ($a in $script:agents) {
            $effectiveTools = if ($a.tools) { $a.tools } else { $script:manifest.defaults.tools }
            if (@($a.allowedChildren).Count -gt 0) {
                $effectiveTools -contains 'agent' | Should -BeTrue -Because "'$($a.id)' delegates but lacks the 'agent' tool"
            }
        }
    }

    It 'the master can reach every team-lead and executive specialist' {
        $master = $script:byId['power-platform-master']
        foreach ($sub in $script:agents | Where-Object { $_.id -ne 'power-platform-master' }) {
            $master.allowedChildren -contains $sub.displayName | Should -BeTrue -Because "master must list '$($sub.displayName)'"
        }
    }
}

Describe 'Hierarchy - visibility invariants' {
    It 'every agent is visible and user-invocable (flat, no hidden workers)' {
        foreach ($a in $script:agents) {
            $a.visibility    | Should -Be 'visible'
            $a.userInvocable | Should -BeTrue
        }
    }
}
