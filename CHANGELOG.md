# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_Nothing yet — next changes will appear here._

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
