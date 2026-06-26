# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_Nothing yet — next changes will appear here._

## [v0.2.2-pre-release] - 2026-06-26

### Added

- **Cross-environment repoint workflow added to the `pbi-powerapps-integration` skill** — the embedded skill now carries an end-to-end, A-to-Z playbook for repointing a Power BI report's Power Apps and Power Automate (Flow) visuals across DevOps branches (`dev → stage → prod`): read-only discovery of the visuals, a DEV-confirmation gate, resolving each target environment's live ids from Power Platform (the Dataverse `canvasapps.canvasappid` *is* the visual's `appId`; the Flow GUID is solution-aware and identical across environments while only the `EnvironmentId` changes), hardcoding the correct `appId` / `EnvironmentId` per branch, and a verification pass. The agent's copilot-instructions and working-flow skill discovery now point at it for "repoint / lock the app & flow ids per environment" tasks
- **Optional Azure CLI (`az`) install prompt** — Step 2 now detects Azure CLI and, only if it's missing, offers a one-time opt-in install (`y/N`, defaults to skip) via winget. `az` is used solely by the repoint workflow above to auto-resolve a Power Apps visual's live `appId` from Dataverse; if you decline or winget is unavailable, the installer points you to [aka.ms/installazurecli](https://aka.ms/installazurecli) and everything else still works. Kept off the architecture diagram by design (niche, single-use-case tool)

## [v0.2.1-pre-release] - 2026-06-24

### Fixed

- **Live canvas authoring was blocked by the agent's own tool allowlist** — the Canvas Authoring MCP server was registered in `.vscode/mcp.json`, but the agent's `tools:` allowlist did not include it, so the agent could not call it and would suggest a non-existent desktop workaround instead. Added `canvas-authoring/*` to the allowlist so the agent can actually coauthor live

### Added

- **Per-session setup reset via SessionStart hook** — the installer now generates `.github/hooks/clear-session.json`, a workspace `SessionStart` hook that clears the `.session-active` marker at the start of each new agent session, so the guided setup is offered once per session instead of only once after install
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
