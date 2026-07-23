# Test suite - what it guarantees

These [Pester](https://pester.dev) tests are the automated safety net for the
installer. They validate the **embedded agent manifest** (the `$agentManifestJson`
block inside `Setup-PowerPlatformWorkspace.ps1`) and its governance invariants, so
a change that would corrupt the agent organisation is caught before release.

They run automatically in GitHub Actions on every push/PR that touches the
installer, schema, or tests (see `.github/workflows/validate.yml`), and you can run
them locally at any time.

## How to run

**Easiest:** double-click `Run-Tests.bat` in this folder. It runs the whole suite
and shows a green/red summary. The path is resolved from the batch file's own
location (`%~dp0`), so it works for any user on any machine - no hard-coded paths.

**Manually** (from any terminal):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester; Invoke-Pester -Path '<path-to>\tests' -Output Detailed"
```

The JSON-Schema test needs PowerShell 7 (`Test-Json -Schema`); on Windows
PowerShell 5.1 it is skipped. GitHub Actions runs on PowerShell 7, so the full
suite (including schema validation) is exercised in CI.

## What each file checks

| File | What it guards | Why it matters |
|------|----------------|----------------|
| `Manifest.Helpers.ps1` | *(not a test)* Shared helpers that locate the installer, extract the embedded manifest JSON, and expose the allowed tool set. | Every test loads this; you never run it directly. |
| `Manifest.Tests.ps1` | The manifest is valid JSON, declares a `schemaVersion` + semantic `productVersion`, defines exactly **12 agents** with the expected tier counts (4 executive / 8 team-lead / 0 worker), has unique ids/display names/filenames/prefixes, and binds the `canvas-authoring` and `flow-agent` MCP servers to the correct leads. Also validates against the JSON Schema (PS7/CI only). | Stops accidental duplication, miscounting, or a malformed manifest from shipping. |
| `Hierarchy.Tests.ps1` | Exactly one root (the Master), every `parent` resolves, the parent chain has no cycles, every `allowedChildren` entry resolves, only agents holding the `agent` tool may declare children, and every agent is visible + user-invocable. | Guarantees the delegation tree is coherent and can't form loops or dangling references. |
| `Tools.Tests.ps1` | Every `tools` entry uses only known capability tokens, no duplicates, and the delegation (`agent`) tool is never granted to the default set. | Keeps the capability model well-formed. |
| `Tools.LeastPrivilege.Tests.ps1` | Every agent declares an **explicit** `tools` array (nothing relies on the default), the manifest default is **read-only** (`read`, `search`), workers may never delegate, and the read-only advisory / gate roles (Solution Architect, Integration QA) are never granted `edit`. | Enforces least-privilege: broad capabilities are opt-in per role, not inherited. |
| `Version.Tests.ps1` | The installer's `$productVersion`, the embedded manifest `productVersion`, the README status heading, and the top CHANGELOG entry all agree. | Prevents version drift across the places a version is written. |
| `Generated.Tests.ps1` | Runs the installer in dry-run (`-EmitAgentsTo`) into a temp folder and checks the **actual generated agent files**: 12 files exist, filenames match the manifest with a three-digit ordered prefix, each opens with YAML frontmatter, each file's declared `tools` match the manifest, and each MCP binding is appended as a `server/*` wildcard token. | Validates the real product the generator emits - not just the manifest contract. |

## What these tests do **not** cover

They validate the manifest **contract**, the generated files, and consistency with
the docs. They do not run the installer end-to-end against a real Power Platform /
VS Code environment (no network, no cloning, no tool installs), and they do not
judge the *behavioural* quality of an agent's prompt - only its structure and
safety. Behavioural quality is validated by real-world use and the installer's
post-generation self-test (`guardrail-status.json`).
