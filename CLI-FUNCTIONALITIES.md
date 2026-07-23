# CLI Functionalities — Deep Dive

> **TL;DR** — The core workspace (Power Platform Tools VS Code extension + the
> agent team editing local solution source) is driven mainly by the **Power
> Platform CLI (`pac`)**. Three more CLIs add optional power on top: **`dnx`**
> (.NET 10) runs the live canvas-authoring MCP server, **`node`** (Node.js 18+)
> runs the Power Automate `flow-agent` MCP server, and **`az`** (Azure CLI) does
> two jobs: it **authenticates** the `flow-agent` MCP server (`az login`)
> and **resolves** live Power Apps `appId`s during the cross-environment repoint
> workflow. Only `pac` is required; the live-authoring runtimes (`dnx`, `node`,
> `az`) are **installed by default** and gated at runtime by
> `.github/agent-docs/tool-status.json` (non-blocking — offline authoring works
> without them).

This document is a practical catalogue of the CLI actions that matter in this
workspace and which agent owns each one. It is not an exhaustive reference —
command groups and flags evolve, so confirm exact syntax with `pac help`,
`pac <group> help`, `az --help`, or the official references linked at the end.

---

## Which CLI does what

| CLI | Required? | Runs | Owned by | Purpose |
|-----|-----------|------|----------|---------|
| **`pac`** (Power Platform CLI) | Yes (auto-installed) | terminal | Solution ALM & Environments Lead, Master | Auth, environment selection, solution export/unpack/pack/import, whoami |
| **`dnx`** (.NET 10 SDK) | Auto-installed (live canvas authoring) | MCP server | Canvas Apps Lead | Launches the `canvas-authoring` MCP server for real-time coauthoring |
| **`node`** (Node.js 18+) | Auto-installed (live flow authoring) | MCP server | Power Automate Lead | Launches the `flow-agent` MCP server (authenticated with `az login`) |
| **`az`** (Azure CLI) | Auto-installed | terminal | Power Automate Lead, Canvas Apps Lead (repoint) | Authenticate the `flow-agent` MCP (`az login`); resolve a Power Apps visual's live `appId` from Dataverse during repoint |
| **`git`** | Yes | terminal | Master, Workspace Maintainer | Clone skills, version the workspace, conventional commits |

Runtime availability is recorded during setup in
`.github/agent-docs/tool-status.json`; each tool entry carries a `found` flag and,
when present, the resolved executable `path`. An agent checks `found` before
offering a capability, invokes the exact `path` so an older same-named copy on
`PATH` cannot take precedence, and falls back gracefully when a tool is absent.

---

## Part I — Power Platform CLI (`pac`)

The workhorse. Every ALM action goes through it. The `scripts/pac-workflows.ps1`
helper wraps the common flows (pull / push / init).

### Identity & environment

```powershell
pac auth list                      # show stored auth profiles
pac auth create --deviceCode       # sign in via device code
pac auth select --index <n>        # switch active profile
pac org list                       # list environments in the tenant
pac org who                        # current environment + user
pac org select --environment <id>  # point at an environment
```

### Solutions (the ALM core)

```powershell
# Export a solution as a zip (unmanaged for dev, managed for prod)
pac solution export --name <SolutionName> --path exports\ --managed false

# Unpack a zip into source-controllable files
pac solution unpack --zipfile exports\<SolutionName>.zip --folder <Env>\<SolutionName> --packagetype Both

# Pack source back into a zip
pac solution pack --zipfile deploy\<SolutionName>.zip --folder <Env>\<SolutionName> --packagetype Both

# Import a packed solution into the active environment
pac solution import --path deploy\<SolutionName>.zip --publish-changes

pac solution list                  # solutions in the active environment
```

> **Production guardrail:** the agents never run an import against a Production
> environment unless the user explicitly types `confirm push to prod`.

### Helper script

`scripts/pac-workflows.ps1` exposes `pull`, `push`, and `init` verbs that chain
the commands above with the correct folders and conventional-commit messages, so
the Team Leads and the Master call one command instead of four.

---

## Part II — MCP runtimes (`dnx` and `node`)

These CLIs are not called directly for tasks; they **host MCP servers** that the
relevant Team Lead connects to. Both are registered in `.vscode/mcp.json` and
start on demand.

### `dnx` — Canvas Authoring MCP (.NET 10)

Provides live, real-time canvas coauthoring. Requires an open Power Apps Studio
tab with coauthoring enabled. The Canvas Apps Lead connects using the Studio URL
you paste in chat. If the .NET 10 SDK (which provides `dnx`) is missing, the Lead
falls back to offline export → edit → import automatically.

### `node` — Flow Agent MCP (Node.js 18+)

Provides Power Automate authoring support to the Power Automate Lead. Node.js 18+
is installed by default (via winget) during setup — non-blocking; when present,
the `flow-agent` server becomes available. The server authenticates to Power
Automate with `az login` (Azure CLI), so live flow authoring needs both `node`
and `az`.

---

## Part III — Azure CLI (`az`)

`az` has two optional jobs in this workspace:

1. **Authenticates the `flow-agent` MCP server** (`az login`) so the Power
   Automate Lead can do live cloud-flow authoring. Without `az` (or `node`),
   the Lead falls back to pac CLI + offline editing of the unpacked flow JSON.
2. **Resolves a target environment's live Power Apps `appId`** from Dataverse
   during the cross-environment **repoint** workflow (a Power BI report
   embedding a Power Apps / Flow visual).

The installer installs it by default (via winget), the same way the .NET 10 SDK
and Node.js are installed for the live MCP servers. It never blocks setup — if it
can't be installed, the rest of the workspace is unaffected: only the live
flow-agent MCP and the auto-resolve step of repoint are unavailable (the repoint
workflow still has maker-portal / sibling-report fallbacks).

See `.github/skills/pbi-powerapps-integration/SKILL.md` for the full repoint
playbook.

---

## Official references

- Power Platform CLI: https://learn.microsoft.com/power-platform/developer/cli/introduction
- `pac solution` reference: https://learn.microsoft.com/power-platform/developer/cli/reference/solution
- Power Platform Tools for VS Code: https://marketplace.visualstudio.com/items?itemName=microsoft-IsvExpTools.powerplatform-vscode
- Microsoft power-platform-skills: https://github.com/microsoft/power-platform-skills
- .NET 10 SDK: https://dotnet.microsoft.com/download/dotnet/10.0
- Node.js: https://nodejs.org
- Azure CLI: https://learn.microsoft.com/cli/azure/
