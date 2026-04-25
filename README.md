# Power Platform Workspace — One-Click Setup

[![Latest Release](https://img.shields.io/badge/version-v0.1.0--preview-blue)](https://github.com/SteCiu01/Power-Platform-Workspace-One-Click-Setup/releases)

> Pre-release — functional and tested, evolving fast.
> Contributions and feedback welcome.

> **Zero to fully configured in under 60 seconds.**
> Double-click one file, answer one question, and you have a complete
> Power Platform development environment with an AI agent that handles
> authentication, environment sync, and solution management for you.

---

## What is this?

This is a **one-click workspace bootstrapper and Copilot agent configuration**
for Power Platform development in VS Code. Instead of manually setting up
folders, config files, CLI tools, and agent definitions, you run a single
script and everything is ready.

Once set up, a custom Copilot agent called **Power Platform Master Agent** lives
inside your workspace and acts as your AI-powered co-pilot for the entire Power
Platform ALM lifecycle: pulling solutions, pushing changes, editing components,
comparing environments, and more — all through natural language in the Copilot
Chat panel.

---

## What you get

| Component | Description |
|---|---|
| **Power Platform Master Agent** | A custom Copilot Chat agent that orchestrates your entire workflow — auth, environment selection, solution sync, editing, and deployment |
| **Microsoft Power Platform Skills** | Git-cloned from [microsoft/power-platform-skills](https://github.com/microsoft/power-platform-skills) — 5 plugins, 38 skills. No npm install or admin rights required (see [FAQ](#faq)) |
| **PAC CLI Helper Script** | `scripts/pac-workflows.ps1` — pull, push, and init solutions with a single command |
| **Git Version Control** | Repository initialised with a clean `.gitignore` and first commit out of the box |
| **Organised Folder Structure** | `exports/`, `deploy/`, `scripts/`, `.github/agents/` — everything where it should be |

---

## Prerequisites

Before running the installer, make sure you have:

| Tool | Required? | How to get it |
|---|---|---|
| **VS Code 1.99+** | Yes | [code.visualstudio.com](https://code.visualstudio.com) |
| **GitHub Copilot + Agent Mode** | Yes | Install from VS Code Extensions marketplace. Agent mode must be enabled (`chat.agent.enabled`). Note: org tenants may need admin to enable this. |
| **Git** | Yes | [git-scm.com](https://git-scm.com) |
| **PAC CLI** | Recommended | Auto-installed if .NET SDK is present, or the agent will guide you on first run |

---

## Quick start

### 1. Get the files

You need **two files** — keep them in the same folder:

```
Setup-PowerPlatformWorkspace.bat    ← double-click this
Setup-PowerPlatformWorkspace.ps1    ← the engine (called by the .bat)
```

### 2. Run the installer

**Double-click `Setup-PowerPlatformWorkspace.bat`.**

You'll see a terminal window:

```
===============================================
 Power Platform Workspace — One-click Setup
===============================================

Enter a name for your workspace folder (default: Power Platform): _
```

Type a name or press **Enter** to accept the default. The script will:

1. ✅ Check all prerequisites (git, node, VS Code, pac)
2. 📁 Create the folder at `C:\Users\<you>\<folder name>\`
3. 📄 Generate all config files (`.gitignore`, agent definition, Copilot settings, helper scripts)
4. 📦 Clone Microsoft's Power Platform Skills repository (30+ skills)
5. 🔀 Initialise a git repo with the first commit
6. 🚀 Open the workspace in VS Code

### 3. Start working

Once VS Code opens:

1. Open **Copilot Chat** (sidebar or `Ctrl+Shift+I`)
2. Select **Power Platform Master Agent** from the agent dropdown
3. Type anything — the agent takes over from here

On first message the agent will:
- Update skills to latest from GitHub
- Walk you through authentication (`pac auth`)
- Let you pick your environment
- Inventory all solutions
- Sync everything locally

---

## What the agent can do

### Automated session startup

You don't configure anything manually. On your **first message** each session, the agent automatically:

1. **Updates skills** — pulls the latest power-platform-skills from GitHub
2. **Authenticates you** — checks for an existing `pac auth` profile or walks you through device-code login
3. **Lets you pick your environment** — lists all environments you have access to and connects to the one you choose
4. **Inventories everything** — runs `pac solution list` (and flow/canvas list where supported) to show all solutions, loose flows, and apps in the environment
5. **Syncs locally** — if no local folder exists, pulls and unpacks every solution automatically; if files already exist, detects conflicts and asks you which version to keep (local or platform)

All of this happens before you even ask your first real question.

### Day-to-day commands

Once your session is active, just tell the agent what you need in plain English:

| Command | What happens |
|---|---|
| `pull MyApp` | Exports and unpacks the solution into a local folder, commits to git |
| `push MyApp to TEST` | Packs the local folder, imports to the target environment, commits |
| `new solution InventoryTracker` | Scaffolds a new solution with `pac solution init` |
| `compare DEV and TEST` | Pulls the same solution from both environments and diffs them |
| `status` | Shows auth state, solution list, and git log |

### Skill-based editing (5 plugins, 38 skills)

The agent doesn't just move solutions around — it can **read and edit** Power Platform source files directly using Microsoft's official [power-platform-skills](https://github.com/microsoft/power-platform-skills) library. Before each task, the agent reads the relevant `SKILL.md` file and follows its instructions step by step to apply the correct edits to your XML/YAML/JSON source, then shows you a diff.

> **Why git clone instead of npm install?** Corporate environments typically
> block npm global installs and require admin approval. This workspace clones
> the skills repo via git — which you already have — so there's zero extra
> tooling or permissions needed. See [FAQ](#faq) for details.

| Plugin | Skills | Covers | Example commands |
|---|---|---|---|
| **model-apps** | 2 | Forms, views, sitemap, genux pages | `add a phone field to the Contact main form` |
| **canvas-apps** | 5 | Screens, controls, connections, data sources | `add a gallery to the home screen` |
| **code-apps** | 14 | React+Vite code apps, connectors (Dataverse, SharePoint, Teams, etc.) | `scaffold a new code app with Dataverse` |
| **power-pages** | 15 | Sites, auth, web roles, SEO, data model, deployment | `create a new Power Pages site` |
| **mcp-apps** | 2 | MCP widget generation | `generate a UI widget for my MCP tool` |

### Conflict resolution and sync

When your local files and the platform are out of sync, the agent handles it:

- **Solution exists online but not locally** — pulled automatically, no question needed
- **Solution exists both places** — the agent asks you per-solution whether to keep local or overwrite from platform
- After resolving, everything is committed in one clean commit

### Safety built in

- **Production is protected** — the agent will never import to Production unless you explicitly type `confirm push to prod`
- **Git history stays clean** — one commit per logical action with conventional commit messages (`chore:` for pulls, `feat:` for pushes)
- **Errors are diagnosed** — if a `pac` command fails, the agent explains what went wrong and suggests a fix before retrying
- **Auth is always verified** — the agent checks `pac auth list` before any export or import
- **No raw zips committed** — solutions are always unpacked before committing; `.zip` files stay in gitignored folders
- **Managed vs unmanaged** — unmanaged for dev work, managed for production deployments

---

## Workspace structure

After setup, your folder looks like this:

```
Power Platform/
├── .git/
├── .github/
│   ├── agents/
│   │   └── power-platform-master-agent.agent.md   ← the agent brain
│   └── copilot/
│       └── settings.json                          ← skill plugin config
├── .gitignore
├── AGENTS.md                                      ← quick-reference guide
├── deploy/                                        ← packed .zip files for import
├── exports/                                       ← raw .zip exports (gitignored)
├── power-platform-skills/                         ← Microsoft skills (gitignored)
│   └── plugins/
│       ├── canvas-apps/
│       ├── code-apps/
│       ├── mcp-apps/
│       ├── model-apps/
│       └── power-pages/
└── scripts/
    └── pac-workflows.ps1                          ← CLI helper script
```

When you connect to an environment, the agent creates a folder at the root
named after that environment (e.g. `DEV/`, `TEST/`) containing your unpacked
solution source files.

---

## How it works under the hood

The setup script (`Setup-PowerPlatformWorkspace.ps1`) is fully self-contained.
It does not download anything except the public Microsoft skills repository.
Every file it creates is embedded directly in the script — no external
templates, no internet dependencies beyond `git clone`.

The `.bat` wrapper exists solely to bypass Windows PowerShell execution policy
restrictions. It calls the `.ps1` with `-ExecutionPolicy Bypass` so the script
runs regardless of your organisation's policy settings.

The script is **idempotent** — if you run it against an existing folder, it
skips files that already exist and only fills in what's missing.

---

## FAQ

**Q: Can I move the workspace folder after creation?**
A: Yes. The workspace is fully portable. Just open the new location in VS Code.

**Q: What if I don't have the PAC CLI installed?**
A: The script will warn you but still create everything. When you start your
first session, Power Platform Master Agent will guide you through installing it.

**Q: Does this work on macOS or Linux?**
A: The setup script is Windows-only (PowerShell + .bat). However, the
workspace itself — including the Power Platform Master Agent — works on
any OS once the files exist. You’d just need to create the folder structure
manually or adapt the script.

**Q: Why does this clone skills via git instead of installing them?**
A: The official way to install power-platform-skills is via npm global
install, which requires admin/elevated rights on most corporate machines
and often needs IT approval. By git-cloning the repo directly, this
workspace avoids that entirely — you only need git, which is already a
prerequisite. The agent reads the SKILL.md files from the local clone
before each task, so the skills work without any plugin framework.

**Q: Can multiple people share the same workspace via git?**
A: Absolutely. Push the workspace to a shared repo. Each team member clones it,
selects Power Platform Master Agent, and connects to their own environment.
The `.gitignore` keeps exports, skills, and environment files clean.

**Q: How do I update the skills?**
A: The agent does this automatically at the start of every session. You can also
run `cd power-platform-skills && git pull` manually.

---

## Current status (v0.1.0-preview)

| Area | Status |
|---|---|
| One-click setup (.bat + .ps1) | **Working** — tested on Windows 10/11 |
| Agent session flow (auth → env → inventory → sync) | **Working** — tested daily |
| Pull / push / compare / status commands | **Working** |
| Skill-based editing via local SKILL.md files | **Working** — agent reads and follows instructions from the cloned repo |
| Cross-platform setup script | **Not yet** — Windows only for now |
| Automated tests | **Not yet** — planned |

This is a pre-release. Expect rough edges. If something breaks, [open an issue](https://github.com/SteCiu01/Power-Platform-Workspace-One-Click-Setup/issues).

---

## Contributing

This project is open source and open for improvements. If you have ideas,
fixes, or want to extend the agent’s capabilities:

1. Fork the repo
2. Create a feature branch
3. Make your changes
4. Open a pull request

All contributions are welcome — from typo fixes to new agent workflows.
See [issues](https://github.com/SteCiu01/Power-Platform-Workspace-One-Click-Setup/issues) for known items or to suggest new features.

---

## Files in this repository

| File | Purpose |
|---|---|
| `Setup-PowerPlatformWorkspace.bat` | Double-click entry point — share this with your team |
| `Setup-PowerPlatformWorkspace.ps1` | The full installer — must be in the same folder as the .bat |
| `README.md` | This file |

---

## License

This project is licensed under the MIT License — see the [LICENSE](https://github.com/SteCiu01/Power-Platform-Workspace-One-Click-Setup/blob/main/LICENSE) file for details.
