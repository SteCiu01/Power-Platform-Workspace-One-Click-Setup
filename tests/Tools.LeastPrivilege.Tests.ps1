#requires -Version 5.1
Set-StrictMode -Version Latest

BeforeAll {
    . "$PSScriptRoot/Manifest.Helpers.ps1"
    $script:Manifest = Get-AgentManifest
    $script:Agents   = $script:Manifest.agents
    $script:Defaults = $script:Manifest.defaults
}

Describe 'Least-privilege tool posture' {

    It 'every agent declares an explicit tools array (no reliance on defaults)' {
        $missing = $script:Agents | Where-Object { -not $_.PSObject.Properties['tools'] -or $null -eq $_.tools }
        $missing | Should -BeNullOrEmpty -Because 'each agent must opt in to its own tools'
    }

    It 'the manifest default is read-only (search + read only)' {
        $default = @($script:Defaults.tools | Sort-Object)
        $default | Should -Be @('read','search')
    }

    It 'only executives and team leads may hold the agent (delegation) tool' {
        foreach ($a in $script:Agents) {
            $hasAgentTool = @($a.tools) -contains 'agent'
            if ($a.level -eq 'worker') {
                $hasAgentTool | Should -BeFalse -Because "$($a.id) is a worker and must not delegate"
            }
        }
    }

    It 'read-only advisory and gate roles are not granted edit' {
        foreach ($id in @('solution-architect', 'integration-qa-change-controller')) {
            $agent = $script:Agents | Where-Object { $_.id -eq $id }
            @($agent.tools) | Should -Not -Contain 'edit' -Because "$id is read-only / advisory"
        }
    }

    It 'no agent grants a tool token outside the approved set' {
        $allowed = @('agent','read','search','execute','edit')
        foreach ($a in $script:Agents) {
            foreach ($t in @($a.tools)) {
                $allowed | Should -Contain $t -Because "$($a.id) references unknown tool '$t'"
            }
        }
    }

    It 'no agent tools array contains duplicates' {
        foreach ($a in $script:Agents) {
            $tools = @($a.tools)
            ($tools | Select-Object -Unique).Count | Should -Be $tools.Count -Because "$($a.id) has duplicate tool tokens"
        }
    }
}
