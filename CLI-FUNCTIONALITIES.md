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
| **`pac`** (Power Platform CLI) | Yes (auto-installed) | terminal | Solution ALM & Environments Lead, Copilot Studio Lead, Master | Auth, environment selection, solution export/unpack/pack/import, whoami; `pac copilot` (2.9.3+) for Copilot Studio agent workspaces |
| **`dnx`** (.NET 10 SDK) | Auto-installed (live canvas authoring) | MCP server | Canvas Apps Lead | Launches the `canvas-authoring` MCP server for real-time coauthoring |
| **`node`** (Node.js 18+) | Auto-installed (live flow authoring) | MCP server | Power Automate Lead | Launches the `flow-agent` MCP server (authenticated with `az login`). Code apps and mobile apps (Expo SDK 55) need **Node.js 22+** - the installer only guarantees 18+, so those Leads check `node --version` first |
| **`az`** (Azure CLI) | Auto-installed | terminal | Power Automate Lead, Canvas Apps Lead (repoint) | Authenticate the `flow-agent` MCP (`az login`); resolve a Power Apps visual's live `appId` from Dataverse during repoint |
| **`git`** | Yes | terminal | Master, Workspace Maintainer | Clone / refresh the two Microsoft vendor repos, version the workspace, conventional commits |

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
# Export a solution as a zip (unmanaged for dev, managed for prod); pin the target
pac solution export --name <SolutionName> --path exports\<SolutionName>.zip --environment <url>

# Unpack a zip into source-controllable files
pac solution unpack --zipfile exports\<SolutionName>.zip --folder <Env>\<SolutionName>

# Pack source back into a zip (Unmanaged for dev work, Managed for production)
pac solution pack --zipfile deploy\<SolutionName>.zip --folder <Env>\<SolutionName> --packagetype Unmanaged

# Import a packed solution into the VERIFIED environment (never "whatever is active")
pac solution import --path deploy\<SolutionName>.zip --environment <url>

# Verify by exact unique name after an import
pac solution list --environment <url> --json
```

> **Production guardrail:** the agents never run an import against a Production
> environment unless the user explicitly types `confirm push to prod`.

### Helper script

`scripts/pac-workflows.ps1` exposes `pull`, `push`, and `init` verbs that chain
the commands above with the correct folders and conventional-commit messages, so
the Team Leads and the Master call one command instead of four. Its contract:

- `-Environment <label>` is the local folder name (`DEV`, `TEST`, `PROD`, ...).
  For `pull` / `push` the label must resolve to a URL - either through the
  user-owned map `.github/agent-docs/environments.json`
  (`{ "DEV": { "url": "https://...", "production": false } }`) or an explicit
  `-EnvironmentUrl`. An unmapped label is refused (exit 5); it never falls back to
  the active `pac` profile.
- The active org from `pac org who` must equal that URL (exit 4 otherwise), and
  it is pinned on every remote command with `--environment`.
- Production is classified from the map's `production: true` (the word "prod" in
  a label/URL is only an extra guard). A Production push needs `-ConfirmProd`
  (exit 2 without it).
- Every `pac` / `git` step is exit-code checked; the previous package is deleted
  before packing; after import the solution must appear by exact unique name in
  `pac solution list --json` (exit 6 if absent, exit 7 if the list cannot run -
  it fails closed).
- Paths are anchored to the workspace that contains the script (the caller's
  CWD is irrelevant); names with dots or path characters are rejected.
- Only the solution folder is staged and committed (`git commit -- <folder>`);
  whatever you had staged yourself stays staged.

### Copilot Studio agents (`pac copilot`, owned by the 090 Copilot Studio Lead)

Copilot Studio agents are not edited through solution XML in this workspace: they
are **MCS2 YAML projects** synchronised with `pac copilot`, exactly as Microsoft's
[copilot-studio-plugin](https://github.com/microsoft/copilot-studio-plugin) skills
prescribe (the Lead follows those `SKILL.md` files step by step and dispatches
Microsoft's Architect / Describer / Init / Manage workers). Requires `pac` **2.9.3+**.

```powershell
pac copilot init --name '<display>' --environment '<id-or-url>' --project-dir '<dir>' --publisher-prefix '<prefix>' --authoring-mode cli-copilot --instructions '<text>'
pac copilot clone --environment '<id-or-url>' ...   # bring an existing cloud agent into a local workspace
pac copilot pull --project-dir '<dir>'              # always before editing / before push
pac copilot push --project-dir '<dir>'              # upload local YAML (pull-before-push)
pac copilot publish ...                             # make the draft live - APPROVED:PUBLISH:<agent>@<env>
pac copilot delete ...                              # APPROVED:DELETE:<agent>
pac copilot list --environment '<id-or-url>'
```

Workspace layout the Lead expects: `settings.mcs.yml`, `agent.sync.yaml`, `behaviors/`,
`capabilities/{knowledge,tools}/`, `infrastructure/connections/`, `.mcs/` (CLI-managed,
never hand-edited). The environment is always an explicit ID or Dataverse URL - never
the active profile's default.

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
