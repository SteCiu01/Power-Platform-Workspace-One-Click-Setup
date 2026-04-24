# Power Platform Workspace — One-Click Setup

> **Zero to fully configured in under 60 seconds.**
> Double-click one file, answer one question, and you have a complete
> Power Platform development environment with an AI agent that handles
> authentication, environment sync, and solution management for you.

---

## What is this?

This project gives you a **one-click installer** that builds a fully wired
VS Code workspace for Power Platform development. Instead of manually
setting up folders, config files, CLI tools, and agent definitions, you
run a single script and everything is ready.

Once set up, an AI agent called **Power Platform Master Agent** lives inside
VS Code and acts as your copilot for the entire Power Platform ALM lifecycle:
pulling solutions, pushing changes, editing components, comparing environments,
and more — all through natural language in the Copilot Chat panel.

---

## What you get

| Component | Description |
|---|---|
| **Power Platform Master Agent** | A custom Copilot Chat agent that orchestrates your entire workflow — auth, environment selection, solution sync, editing, and deployment |
| **Microsoft Power Platform Skills** | Automatically cloned from [microsoft/power-platform-skills](https://github.com/microsoft/power-platform-skills) — 5 plugins (model-apps, canvas-apps, code-apps, power-pages, mcp-apps) with 30+ skills |
| **PAC CLI Helper Script** | `scripts/pac-workflows.ps1` — pull, push, and init solutions with a single command |
| **Git Version Control** | Repository initialised with a clean `.gitignore` and first commit out of the box |
| **Organised Folder Structure** | `exports/`, `deploy/`, `scripts/`, `.github/agents/` — everything where it should be |

---

## Prerequisites

Before running the installer, make sure you have:

| Tool | Required? | How to get it |
|---|---|---|
| **VS Code** | Yes | [code.visualstudio.com](https://code.visualstudio.com) |
| **GitHub Copilot** (+ Chat) | Yes | Install from VS Code Extensions marketplace |
| **Git** | Yes | [git-scm.com](https://git-scm.com) |
| **Node.js 18+** | Yes | [nodejs.org](https://nodejs.org) |
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

Once your session is active, just tell the agent what you need in plain English:

| Command | What happens |
|---|---|
| `pull MyApp` | Exports and unpacks the solution into a local folder, commits to git |
| `push MyApp to TEST` | Packs the local folder, imports to the target environment, commits |
| `edit the main form in MyApp` | Reads the relevant skill, applies changes to the XML/YAML source |
| `new solution InventoryTracker` | Scaffolds a new solution with `pac solution init` |
| `compare DEV and TEST` | Pulls the same solution from both environments and diffs them |
| `status` | Shows auth state, solution list, and git log |

### Safety built in

- **Production is protected** — the agent will never import to Production unless you explicitly type `confirm push to prod`
- **Git history stays clean** — one commit per logical action with conventional commit messages
- **Errors are diagnosed** — if a `pac` command fails, the agent explains what went wrong and suggests a fix before retrying

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
A: The setup script is Windows-only (PowerShell + .bat). The workspace itself
works on any OS once created — you'd just need to create the files manually or
adapt the script.

**Q: Can multiple people share the same workspace via git?**
A: Absolutely. Push the workspace to a shared repo. Each team member clones it,
selects Power Platform Master Agent, and connects to their own environment.
The `.gitignore` keeps exports, skills, and environment files clean.

**Q: How do I update the skills?**
A: The agent does this automatically at the start of every session. You can also
run `cd power-platform-skills && git pull` manually.

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
