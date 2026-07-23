BeforeAll {
    . (Join-Path $PSScriptRoot 'Manifest.Helpers.ps1')
    $script:manifest = Get-AgentManifest
    $script:agents   = $script:manifest.agents
    $script:allowed  = $script:AllowedTools
}

Describe 'Tools - token validity' {
    It 'defaults.tools uses only known capability tokens' {
        foreach ($t in $script:manifest.defaults.tools) {
            $script:allowed -contains $t | Should -BeTrue -Because "default tool '$t' is not a known capability"
        }
    }

    It 'every agent tools entry uses only known capability tokens' {
        foreach ($a in $script:agents) {
            foreach ($t in $a.tools) {
                $script:allowed -contains $t | Should -BeTrue -Because "'$($a.id)' declares unknown tool '$t'"
            }
        }
    }

    It 'no agent declares duplicate tools' {
        foreach ($a in $script:agents) {
            if ($a.tools) {
                (@($a.tools) | Sort-Object -Unique).Count | Should -Be @($a.tools).Count -Because "'$($a.id)' has duplicate tools"
            }
        }
    }
}

Describe 'Tools - delegation capability is reserved' {
    It 'no worker may hold the "agent" (delegation) tool' {
        foreach ($w in $script:agents | Where-Object level -eq 'worker') {
            $effective = if ($w.tools) { $w.tools } else { $script:manifest.defaults.tools }
            $effective -contains 'agent' | Should -BeFalse -Because "worker '$($w.id)' must not delegate"
        }
    }

    It 'the default capability set never grants delegation' {
        $script:manifest.defaults.tools -contains 'agent' | Should -BeFalse
    }
}
