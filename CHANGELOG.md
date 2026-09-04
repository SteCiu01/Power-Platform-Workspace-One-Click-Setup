# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [v0.4.0] - 2026-08-31

Adds **dynamic worker sub-agent discovery**: each Team Lead now automatically gains
Microsoft's own bundled worker agents (shipped inside the cloned
`power-platform-skills` plugins) as **hidden, delegated sub-agents** — with zero
forking. The stable 12-agent team stays the orchestration layer; Microsoft's
refreshed workers are the implementation layer.

### Added

- **Dynamic worker sub-agent discovery** — after the skills clone/refresh, the installer scans each Lead's plugin at `power-platform-skills/plugins/<plugin>/agents/*.md` and generates **one hidden wrapper agent per Microsoft worker** in `.github/agents/`, wired into the owning Lead's `agents:` list so the Lead can dispatch it as a VS Code subagent. Today this lights up the **Canvas Apps Lead** with Microsoft's `canvas-app-planner` and `canvas-screen-builder`; every other Lead activates automatically the moment Microsoft ships an `agents/` folder for its plugin — no installer change required
- **Pointer, not fork** — each wrapper is a thin `user-invocable: false` agent whose body tells the sub-agent to read Microsoft's file **verbatim** and resolve `${PLUGIN_ROOT}` to the plugin folder. Microsoft stays the single source of truth; wrappers carry only the worker's own tool/MCP permissions (read-only workers stay read-only)
- **Self-refreshing & self-pruning** — new upstream workers are picked up on every refresh; wrappers for workers Microsoft removed are pruned. Wrappers use a `-sub-` filename marker so pruning never touches the 12 core agents
- **Collision-safe naming** — each wrapper's registered agent name is namespaced with its Lead's numeric prefix (e.g. `030-data-model-architect`), so when two plugins ship a worker with the same name (Microsoft's `data-model-architect` exists under both power-pages and mobile-apps) they never clash in `.github/agents/`, and each Lead only ever dispatches its own worker
- **Discovery test suite** — `tests/Discovery.Tests.ps1` stages a fake plugin and proves wrapper generation, hidden visibility, Lead wiring, tool mirroring, self-pruning, and cross-plugin name-collision safety through the real generator (dry-run mode, no network)

### Changed

- **The team is now "12 core agents + auto-discovered Microsoft worker sub-agents (hidden, per Lead)"** — the 12-agent hierarchy and the Master → Lead delegation are unchanged; the discovered workers add a hidden implementation layer beneath the Leads
- **Version bumped to `0.4.0`** across the installer stamp, embedded manifest, README status heading, and this changelog

## [v0.3.0] - 2026-07-23

A structural release that turns the single Power Platform Master Agent into a
governed **12-agent hierarchy**, generated from an embedded, schema-validated
manifest — and makes the installer **authoritative and self-pruning**, in parity
with the Fabric Agentic Workspace installer. Everything the installer ships is
force-refreshed on every update; anything the user creates is never touched.

### Added

- **12-agent hierarchy, manifest-driven** — the installer now embeds a JSON agent manifest (validated against the new `schema/agent-manifest.schema.json`) and generates one `.agent.md` per entry with a 3-digit, hierarchy-sorted filename prefix. The team: **4 executives** (`000` Power Platform Master, `001` Solution Architect, `002` Integration QA & Change Controller, `003` Workspace Maintainer) and **8 Team Leads** (`010`–`080`: Canvas Apps, Power Automate, Power Pages, Code Apps, Model Apps, Mobile Apps, MCP Apps, Solution ALM & Environments). All are visible and user-invocable; the Master coordinates and delegates rather than implementing directly
- **Least-privilege capability model** — every agent declares an explicit `tools` array drawn from a fixed set (`agent`, `read`, `search`, `execute`, `edit`); the manifest default is read-only (`read`, `search`). The **Master** (delegates to all 11 other agents) and the **Solution Architect** (can call the 8 Team Leads for advisory planning) hold the `agent` tool; the **8 Team Leads** are the leaf executors that carry `execute`/`edit` and do the actual building (no direct reports); and the advisory/gate roles (Solution Architect, Integration QA & Change Controller) are never granted `edit`
- **Second MCP server: `flow-agent`** — the Power Automate Lead can drive the Power Automate MCP server (Node.js 18+), registered in `.vscode/mcp.json` alongside the existing `canvas-authoring` server. Step 2 auto-installs Node.js by default (non-blocking)
- **CI-friendly generation & integrity modes** — `-EmitAgentsTo <dir>` generates the workspace non-interactively (no prereq checks, cloning, or launch) and runs a post-generation self-test; `-VerifyRoot <dir>` re-hashes managed files against `.github/installed-manifest.json` (SHA256) to detect drift. The installer also writes `tool-status.json` and `guardrail-status.json`
- **Pester test suite + GitHub Actions** — `tests/` guards the manifest contract, hierarchy, tool posture, version consistency, and the real generator output; `.github/workflows/validate.yml` runs it on every push/PR
- **`CLI-FUNCTIONALITIES.md`** — a reference mapping each CLI the workspace drives (`pac`, `az`, `dnx`, `node`) to the agents and workflows that use it
- **Self-pruning updates** — the `installed-manifest.json` is an authoritative **write-log** (the exact set of files the installer wrote, never a directory scan). On update, files an earlier version shipped but the current one no longer ships are **removed automatically** by diffing the previous write-log against the new one, scoped to managed roots (`.github/agents/`, `.github/skills/`, `.github/agent-docs/`, `.vscode/`, `scripts/`) with an allow-list. A separate legacy-orphan sweep removes pre-manifest artefacts (`.github/hooks/`, `.github/copilot/`, `.session-active`) that can leak environment identifiers
- **Vendor force-refresh** — a new `Update-VendorClone` helper fetches + prunes, stashes any local edits (recoverable via `git stash list`), then `reset --hard origin/HEAD`, so the `power-platform-skills` clone always mirrors published upstream

### Changed

- **Live-authoring runtimes install by default** — Step 2 auto-installs **Node.js 18+** (for the Power Automate `flow-agent` MCP) and the **Azure CLI** (`az login` auth for the flow MCP, plus repoint `appId` resolution) by default, matching how the **.NET 10 SDK** is installed for the `canvas-authoring` MCP (previously Node.js was only detected and `az` was an opt-in `y/N` prompt). The Azure CLI install uses a resilient two-stage pattern: **winget** first (per-machine MSI, works on most PCs), then an **isolated-venv `pip install`** no-admin fallback for locked-down machines where winget is blocked (exit 1603). All are **non-blocking** — if any can't be installed, offline authoring via `pac` still works and setup completes
- **`copilot-instructions.md` and `AGENTS.md` are now hierarchy-aware** — they describe the full team, delegation flow, and how to start with `000 - Power Platform Master`
- **Managed files are authoritative** — the `power-platform-skills` clone is **force-refreshed** to upstream on update (not fast-forward-only). The `003` Workspace Maintainer agent enforces the authoritative-overwrite contract: it explains that edits to managed files reset on update and steers customisation into **NEW** files under `.github/`, rather than preserving edits as conflicts
- **Machine-specific files excluded from integrity** — `tool-status.json`, `guardrail-status.json`, and `installed-manifest.json` are `.gitignore`d and excluded from the hashed manifest, so `-VerifyRoot` no longer reports false drift from regenerated, environment-specific files
- **Self-test is all-managed-present, not exact-count** — the post-generation self-test asserts every managed agent was written and reports any extra user-authored agents as preserved, instead of failing when the user adds an agent
- **Version is single-sourced** — `$productVersion` in the installer and `productVersion` in the embedded manifest are both `0.3.0`; the Pester suite fails the build if they drift from the README status heading or this changelog

## [v0.2.2-pre-release] - 2026-06-26

### Added

- **Cross-environment repoint workflow added to the `pbi-powerapps-integration` skill** — the embedded skill now carries an end-to-end, A-to-Z playbook for repointing a Power BI report's Power Apps and Power Automate (Flow) visuals across DevOps branches (`dev → stage → prod`): read-only discovery of the visuals, a DEV-confirmation gate, resolving each target environment's live ids from Power Platform (the Dataverse `canvasapps.canvasappid` *is* the visual's `appId`; the Flow GUID is solution-aware and identical across environments while only the `EnvironmentId` changes), hardcoding the correct `appId` / `EnvironmentId` per branch, and a verification pass. The agent's copilot-instructions and working-flow skill discovery now point at it for "repoint / lock the app & flow ids per environment" tasks
- **Optional Azure CLI (`az`) install prompt** — Step 2 now detects Azure CLI and, only if it's missing, offers a one-time opt-in install (`y/N`, defaults to skip) via winget. `az` is used solely by the repoint workflow above to auto-resolve a Power Apps visual's live `appId` from Dataverse; if you decline or winget is unavailable, the installer points you to [aka.ms/installazurecli](https://aka.ms/installazurecli) and everything else still works. 

## [v0.2.1-pre-release] - 2026-06-24

### Fixed

- **Live canvas authoring was blocked by the agent's own tool allowlist** — the Canvas Authoring MCP server was registered in `.vscode/mcp.json`, but the agent's `tools:` allowlist did not include it, so the agent could not call it and would suggest a non-existent desktop workaround instead. Added `canvas-authoring/*` to the allowlist so the agent can actually coauthor live

### Added

- **Conversation-state session routing** — the Master agent decides whether guided setup has already run by inspecting the current conversation, not a filesystem marker. There is no `.session-active` file and no SessionStart hook (VS Code does not fire workspace `SessionStart` hooks reliably); the guided setup is offered once per chat and skipped thereafter within that same conversation
- **`[S] set me up` / `[W] just work` startup choice** — on a fresh session the agent now asks whether to run the full guided setup or jump straight to work with a lightweight, lazy init (confirms sign-in and environment, prompts only if missing), reducing first-turn friction
- **Power Platform Tools extension auto-install (optional)** — Step 2 now detects the Power Platform Tools VS Code extension and installs it via `code --install-extension` when absent (non-blocking); all six prerequisites now print an explicit green confirmation when present
- **Custom embedded skill `pbi-powerapps-integration`** — the installer now writes a maintainer-authored, house-style skill to `.github/skills/pbi-powerapps-integration/SKILL.md` (committed, not gitignored) so it auto-installs and stays current on every run. It covers canvas apps embedded in Power BI via the Power Apps visual: the `PowerBIIntegration.Data` / `.Refresh()` API, the golden rule that field-well changes must be re-edited from the Power BI Service, the 1000-row limit, and a stale-schema troubleshooting playbook. The agent (copilot-instructions, starting flow, and working-flow skill discovery) now reads it first and treats it as authoritative over the cloned canvas-apps skills where they overlap

### Changed

- **Master Agent restructured into a cleaner session router** — consolidated redundant onboarding prose, clarified offline (every component) vs live (canvas apps only) editing paths, and added a live-authoring readiness check (`dnx` / .NET 10 SDK + the `canvas-authoring` MCP server) to the starting flow

## [v0.2.0-pre-release] - 2026-06-05

### Added

- **Live canvas authoring (real-time coauthoring via MCP)** — the installer now registers Microsoft's Canvas Authoring MCP server in `.vscode/mcp.json` (launched on demand via `dnx`). With an app open in Power Apps Studio and coauthoring enabled, Power Platform Master Agent connects from the Studio URL and edits the live app in real time — no pack/import round-trip
- **Automatic .NET 10 SDK install** — Step 2 detects and force-installs the .NET 10 SDK (per-user, no admin, via the official `dotnet-install` script), which provides the `dnx` command the MCP server runs on. Non-blocking: if it can't be installed, a warning explains that live authoring is unavailable while local authoring still works
- **Two separated prerequisite batches** — the installer now distinguishes the **local authoring flow** (git, VS Code 1.117.0+, pac CLI, Copilot) from the optional **live authoring flow** (.NET 10 SDK), checking and reporting each independently
- **Offline vs live editing guidance** — the agent's working-flow reference now documents both canvas editing paths, with detailed step-by-step live-authoring instructions (enable coauthoring under Settings → Updates → Coauthoring, keep the Studio tab open, connect via the Studio URL, parameter extraction rules)
- README sections covering the two authoring flows, the `.NET 10 SDK` prerequisite, the `.vscode/mcp.json` server, and a live-authoring FAQ

### Changed

- **PAC CLI install is now forced for everyone** — it installs automatically via the .NET tool when a .NET SDK is present, otherwise via the standalone Power Platform CLI MSI (per-user, no admin), instead of only installing when .NET happened to be available
- Prerequisites table and FAQ in the README updated to reflect the automatic pac install and the new live-authoring requirements

### Fixed

- pac CLI failing to install on machines without the .NET SDK — the standalone MSI fallback now covers clean machines

## [v0.1.1-pre-release] - 2026-04-29

### Added

- **Installer update mode** — when the user selects an existing workspace folder, all installation-managed files (agent definition, copilot instructions, AGENTS.md, .gitignore, pac-workflows.ps1, VS Code configs) are overwritten with the latest versions while user files (solutions, environment folders, exports, custom scripts) are left untouched
- **Skills auto-update on re-install** — in update mode the installer fetches and hard-resets `power-platform-skills/` to latest `origin/main` instead of skipping the clone
- **Smart first-message handling** — Power Platform Master Agent now detects whether the user's opening message is a greeting or an actual question/task; it acknowledges the intent, runs the full environment setup, then either answers the original question automatically or prompts for input

### Changed

- Installer prompts now clearly explain update-mode behaviour before proceeding
- Phase 0 / Phase 6 of the agent starting flow rewritten to support greeting vs. question routing

## [v0.1.0-pre-release] - 2025-04-25

### Added

- One-click setup via `Setup-PowerPlatformWorkspace.bat` + `.ps1` (Windows)
- Power Platform Master Agent definition (`.github/agents/power-platform-master-agent.agent.md`)
- Automated session startup flow: skill update → auth → environment selection → inventory → local sync
- PAC CLI helper script (`scripts/pac-workflows.ps1`) for pull, push, and init operations
- Git-cloned Microsoft [power-platform-skills](https://github.com/microsoft/power-platform-skills) integration — no npm install required
- Organised workspace folder structure (`exports/`, `deploy/`, `scripts/`, `.github/agents/`)
- Git repository initialisation with clean `.gitignore` and first commit
- Workspace-level Copilot instructions (`.github/copilot-instructions.md`)
- `AGENTS.md` quick-reference guide
- Production protection — agent refuses to push to Production without explicit confirmation
- Idempotent installer — safe to re-run on existing folders
- Prerequisite checks for git, VS Code, and pac CLI

### Known limitations

- Setup script is Windows-only (PowerShell + .bat)
- No automated tests yet
- PAC CLI must be installed separately if .NET SDK is not present
