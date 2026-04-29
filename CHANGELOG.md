# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_Nothing yet — next changes will appear here._

## [0.1.1-preview] - 2026-04-29

### Added

- **Installer update mode** — when the user selects an existing workspace folder, all installation-managed files (agent definition, copilot instructions, AGENTS.md, .gitignore, pac-workflows.ps1, VS Code configs) are overwritten with the latest versions while user files (solutions, environment folders, exports, custom scripts) are left untouched
- **Skills auto-update on re-install** — in update mode the installer fetches and hard-resets `power-platform-skills/` to latest `origin/main` instead of skipping the clone
- **Smart first-message handling** — Power Platform Master Agent now detects whether the user's opening message is a greeting or an actual question/task; it acknowledges the intent, runs the full environment setup, then either answers the original question automatically or prompts for input

### Changed

- Installer prompts now clearly explain update-mode behaviour before proceeding
- Phase 0 / Phase 6 of the agent starting flow rewritten to support greeting vs. question routing

## [0.1.0-preview] - 2025-04-25

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

[Unreleased]: https://github.com/SteCiu01/Power-Platform-Workspace-One-Click-Setup/compare/v0.1.1-preview...HEAD
[0.1.1-preview]: https://github.com/SteCiu01/Power-Platform-Workspace-One-Click-Setup/compare/v0.1.0-preview...v0.1.1-preview
[0.1.0-preview]: https://github.com/SteCiu01/Power-Platform-Workspace-One-Click-Setup/releases/tag/v0.1.0-preview
