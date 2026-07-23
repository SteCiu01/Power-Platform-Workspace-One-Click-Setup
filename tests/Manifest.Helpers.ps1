# Shared helper for the Pester suite.
# Extracts the embedded $agentManifestJson here-string from the installer PS1
# and returns it as an object, WITHOUT executing the installer.

function Get-InstallerPath {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $candidate = Join-Path $repoRoot 'power-platform-workspace-installer\Setup-PowerPlatformWorkspace.ps1'
    if (-not (Test-Path $candidate)) {
        throw "Installer not found at $candidate"
    }
    return $candidate
}

function Get-RawManifestJson {
    $installer = Get-InstallerPath
    $raw = Get-Content -LiteralPath $installer -Raw
    $m = [regex]::Match($raw, "(?s)\`$agentManifestJson = @'\r?\n(.*?)\r?\n'@")
    if (-not $m.Success) {
        throw "Could not locate the embedded `$agentManifestJson here-string in the installer."
    }
    return $m.Groups[1].Value
}

function Get-AgentManifest {
    return (Get-RawManifestJson | ConvertFrom-Json)
}

function Get-SchemaPath {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    return (Join-Path $repoRoot 'schema\agent-manifest.schema.json')
}

# The complete set of capability tokens the workspace understands.
$script:AllowedTools = @('agent', 'read', 'search', 'execute', 'edit')
