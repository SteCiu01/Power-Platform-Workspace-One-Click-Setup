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
| `Manifest.Tests.ps1` | The manifest is valid JSON, declares a `schemaVersion` + semantic `productVersion`, defines exactly **13 agents** with the expected tier counts (4 executive / 9 team-lead / 0 worker), has unique ids/display names/filenames/prefixes, and binds the `canvas-authoring` and `flow-agent` MCP servers to the correct leads. Also validates against the JSON Schema (PS7/CI only). | Stops accidental duplication, miscounting, or a malformed manifest from shipping. |
| `Hierarchy.Tests.ps1` | Exactly one root (the Master), every `parent` resolves, the parent chain has no cycles, every `allowedChildren` entry resolves, only agents holding the `agent` tool may declare children, and every agent is visible + user-invocable. | Guarantees the delegation tree is coherent and can't form loops or dangling references. |
| `Tools.Tests.ps1` | Every `tools` entry uses only known capability tokens, no duplicates, and the delegation (`agent`) tool is never granted to the default set. | Keeps the capability model well-formed. |
| `Tools.LeastPrivilege.Tests.ps1` | Every agent declares an **explicit** `tools` array (nothing relies on the default), the manifest default is **read-only** (`read`, `search`), workers may never delegate, and the read-only advisory / gate roles (Solution Architect, Integration QA) are never granted `edit`. | Enforces least-privilege: broad capabilities are opt-in per role, not inherited. |
| `Version.Tests.ps1` | The installer's `$productVersion`, the embedded manifest `productVersion`, the README status heading, the top CHANGELOG entry and the `.bat` launcher banner / window title all agree. | Prevents version drift across the places a version is written. |
| `Generated.Tests.ps1` | Runs the installer in dry-run (`-EmitAgentsTo`) into a temp folder and checks the **actual generated files**: 12 agent files with the right frontmatter and tools; **content** - every agent has `Knowledge and skills` / `Playbook` / `Validation`, ends with the WORK RESULT contract, carries the approval-token rule; Leads have the roster markers + `How you dispatch` + the dispatch-name rule; Architect returns a PLAN, QA a VERDICT; the Master has the three loops, the session ledger, the destructive-request confirmation, the maintenance handoff, lists only its children and no longer has a `Degraded-mode` fallback; headings are spaced; managed-file refs resolve. **Config** - `settings.json` has nested dispatch on + skill locations, `mcp.json` has the three servers, `Get-SessionStatus.ps1` parses and is in the manifest, the starting flow is lean, the working flow has the team protocol + gated SYNC, `pac-workflows.ps1` has `-ConfirmProd`. | Validates the real product the generator emits - not just the manifest contract. |
| `Discovery.Tests.ps1` | Stages a fake Microsoft plugin `agents/` folder and runs the generator (dry-run) to prove **dynamic worker sub-agent discovery**: one hidden wrapper per Microsoft worker, pointing at Microsoft's file (never forking it), mirroring the worker's **own** tools (MCP servers from its `tools:` list, not the Lead's; `Bash` -> `execute`), prefix-namespaced names, the lean worker contract (token rule, no delegation, WORK RESULT), wiring into the Lead's `agents:` list **and** its `## Your team` roster (idempotent), placeholder roster for Leads without workers, the 13 core agents untouched, vanished workers pruned, and cross-plugin name collisions avoided. Also stages the **single-plugin vendor layout** (`copilot-studio-plugin/agents` + `skills`) to prove the 090 Copilot Studio Lead gets its workers (`090-sub-*`, pointing at `copilot-studio-plugin/agents/...`, `mcs-assistant:<skill>` translated), `copilot-studio-plugin/skills` is registered, its skills attach only to the 090 Lead, and a removed worker is pruned. | Guarantees Leads really gain (and lose) Microsoft's bundled workers on refresh - and know how to dispatch them. |
| `VendorClone.Tests.ps1` | Loads only `Update-VendorClone` from the installer and exercises it against a **local bare repo** (no network): a stale clone is brought to the upstream commit under `$ErrorActionPreference = 'Stop'` and success means `HEAD` equals it; local edits (tracked + untracked) are stashed not lost; idempotent; caller's EAP untouched; missing path returns `$false`; a renamed upstream default branch is followed. A `git.cmd` shim forces **stash**, **status** and **reset** failures: each must return `$false` and leave the clone (and local edits) untouched - never "already at upstream"; the reset case must prove the reset path was actually reached, and a dirty clone's failure message must say the edits are in the stash. | Regression guard for the silent-refresh and false-success bugs. |
| `PacWorkflows.Tests.ps1` | Runs the **emitted** `scripts/pac-workflows.ps1` from a workspace-shaped throwaway git repo with a fake `pac.cmd` on PATH and an `environments.json` map: an unmapped label is refused; a mapped label or `-EnvironmentUrl` that differs from `pac org who` is refused; dotted / path-like names are rejected; a map-classified Production org with no "prod" in its name is blocked, as is a prod-looking unmapped org; `-ConfirmProd` unblocks; a pack that exits 42 stops before import and commits nothing (a stale zip is deleted first); a successful push run from a different CWD imports the fresh package to the verified org, verifies by exact unique name via `--json`, commits only the solution folder and leaves a user-staged file staged; `SolBackup` does not count as `Sol`; a failing `pac solution list` fails closed; `pull` works the same way. | Proves the helper's deployment-safety claims on the failure paths, with no tenant. |
| `UpdateSafety.Tests.ps1` | Helpers AST-extracted from the installer (v0.5.2): `ConvertFrom-JsonLenient` parses VS Code JSONC; `Update-UserSettingsInPlace` appends the nested-dispatch flag and a workspace-relative skill-location block to the user `settings.json` **in place** (comments, key order, CRLF/LF and BOM preserved), flips an explicit `false`, merges only missing locations keeping user entries, is idempotent, never writes absolute / `~` paths, creates the file when absent and refuses a broken file; `Get-UserWorkspaceFilesForRoot` / `Update-UserWorkspaceFile` detect a user-saved `.code-workspace` that opens the root, add only what it lacks and find nothing on re-run; static checks that the prompt defaults to Yes, is skipped in emit mode, and the saved-file patch runs only when declined. | Guards the "works however you open the folder" fix without touching the real user profile. |
| `SessionStatus.Tests.ps1` | Runs the **emitted** `Get-SessionStatus.ps1` from an unrelated CWD with `PP_WORKSPACE_USER_SETTINGS` / `PP_WORKSPACE_STORAGE` pinned: root resolved from its own location, every section printed, both vendor clones reported, the three nested-dispatch scope strings (`enabled at user level` / `enabled in .vscode/settings.json only` / `NOT set`), the exact path of a saved workspace file that lacks the flag (with the `(Workspace)` tell and the fixes) and its absence when none opens the root or the user-level flag is set, and the workspace-relative count that excludes entries not resolving under the root. | Makes the status block the Master relays a tested contract, so it names the real cause of a failed dispatch. |

## What these tests do **not** cover

They validate the manifest **contract**, the generated files, and consistency with
the docs. They do not run the installer end-to-end against a real Power Platform /
VS Code environment (no network, no cloning, no tool installs), and they do not
judge the *behavioural* quality of an agent's prompt - only its structure and
safety. Behavioural quality is validated by real-world use; the installer's
post-generation self-test (`guardrail-status.json`) checks structure only (front
matter, name, description, expected count), not behaviour.
