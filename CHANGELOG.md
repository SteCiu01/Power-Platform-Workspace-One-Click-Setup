# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [v0.5.2] - 2026-10-16

One change, ported from the Fabric twin's v0.7.2 after the same field failure was
reproduced here: the agent team must work **however you open the workspace folder** —
File > Open Folder, *Add Folder to Workspace* in a blank window, or any `.code-workspace`
you saved yourself — and a re-run of the installer must reach every one of those windows.

### Why

The two VS Code settings the team depends on are **window-scoped**:

- `chat.subagents.allowInvocationsFromSubagents` — without it a Team Lead (itself running
  as a sub-agent) cannot dispatch its Microsoft workers; the Master silently ends up doing
  the work alone, or the Lead returns empty.
- `chat.agentSkillsLocations` — registers the Microsoft skill folders so agents see them
  natively.

VS Code applies window-scoped settings from the folder's `.vscode/settings.json` **only**
in a window opened with *File > Open Folder*. Any window backed by a workspace file — a
saved `.code-workspace`, **or the untitled one VS Code creates the moment you *Add Folder
to Workspace*** — ignores the folder's `settings.json` for them. v0.5.0 shipped a
`<folder>.code-workspace` with the flag and opened VS Code from it; that covers only the
window the installer opens. Field case: adding the workspace to an existing multi-root
window, asking the Master for work, and watching the Lead fail to dispatch.

### Added

- **Step 5 — "Enable the agent team in your VS Code user settings now? (Y/n)"** (default
  Yes, never silent). On Yes the installer edits `%APPDATA%\Code\User\settings.json`
  **in place** — your other settings, comments, key order, indentation, line endings and
  BOM are preserved; only two things change:
  1. `"chat.subagents.allowInvocationsFromSubagents": true` is added, or an explicit
     `false` is flipped.
  2. The current **workspace-relative** skill folders (`.github/skills`,
     `power-platform-skills/plugins/<plugin>/skills`, `copilot-studio-plugin/skills`) are
     merged into `chat.agentSkillsLocations`; your own entries are kept; a re-run adds only
     folders that appeared upstream since. Absolute and `~/` paths are never written at
     user level.
  The edit is validated before writing (a file that would not parse is never touched) and
  idempotent (a second run reports "already up to date"). If VS Code Profiles are in use,
  the profile settings files are listed so you can repeat the two lines there.
- **Fallback when declined** — the installer scans VS Code's `workspaceStorage` for saved
  `.code-workspace` files that open this folder, lists exactly what each lacks and offers
  (`Y/n`) to add only the missing entries. Untitled *Add Folder* workspaces cannot be
  patched that way, which is why the user-level option is the default.
- **Status script** now reports which scope is in effect — `Nested dispatch: enabled at
  user level (every VS Code window)` / `enabled in .vscode/settings.json only (… NOT
  windows opened from another .code-workspace file or via Add Folder to Workspace)` /
  `NOT set` — how many workspace-relative skill folders the user settings contribute, and
  names any saved workspace file that lacks the flag (with the `(Workspace)` title-bar
  tell and the three fixes). With the user-level setting present it says those files
  need no patch. `PP_WORKSPACE_USER_SETTINGS` / `PP_WORKSPACE_STORAGE` override the paths
  for tests. It now reads `settings.json` as JSONC too.
- **Master / Lead dispatch-health rule** — names "a Lead comes back empty twice" as the
  symptom, tells the agent to quote the CONFIG scope line and the saved-file warning
  instead of guessing (never claim `settings.json` lacks the setting without reading
  it), treats `Requested agent '<name>' not found` as retry-safe (≤3, exact name, never
  substitute), re-dispatches a child that returned without a WORK RESULT **once** with a
  resume context, and may offer to add the single line to the workspace file you are in
  after `APPROVED:EDIT:<file>` (then *Developer: Reload Window*). The reconcile-before-
  retry rule for write-capable dispatches is unchanged and now also names
  `pac copilot push`.
- Generated `copilot-instructions.md` / `AGENTS.md`, the Workspace Maintainer's contract,
  the starting flow and the README describe the scoping model and exactly what the
  user-level setting does and does not enable.

### What the user-level setting does and does not enable — read this

Because it lives in your **user** settings, `chat.subagents.allowInvocationsFromSubagents:
true` is in effect in **every VS Code window on this machine**, not only when this
workspace is open. VS Code offers no per-folder conditional for a window-scoped setting,
so this is the only scope that satisfies "works however I open it".

| Situation | Effect |
|---|---|
| Blank VS Code window, no folder | None — no workspace agents exist; default Copilot chat is unchanged. |
| Any project where you use **built-in Copilot chat / agent mode** only | None — the flag concerns *custom* agents (`.agent.md`) running as sub-agents. |
| A project with custom agents that **never delegate** | None. |
| **Another agentic workspace** (e.g. the Fabric twin) whose custom agents are **designed to delegate** | **Enabled** — exactly what that workspace expects (the Fabric installer writes the same key). Opt out per workspace with `"chat.subagents.allowInvocationsFromSubagents": false` in its `.code-workspace`; workspace scope overrides user scope. |
| This workspace, opened **any** way | **Enabled** — Master → Team Lead → Worker from the first second. |

It never installs agents or skills anywhere else, never changes what built-in Copilot can
do, never grants an agent new tools, and never bypasses the approval tokens. The skill
locations written at user level are workspace-relative, so they resolve **only** in
windows that contain a folder with those sub-paths — in practice, this workspace.

### Tests

- New `UpdateSafety.Tests.ps1` — helpers AST-extracted from the installer: JSONC parsing;
  in-place user-settings edit (append flag + relative block preserving comments / order /
  CRLF; flip `false → true` and merge only missing locations keeping user entries with LF
  preserved; idempotent; absolute / `~` never written; file created when absent; BOM
  preserved; broken file refused and left untouched); saved-workspace detection, merge-
  only patch and idempotency; static wiring of the prompt and the fallback.
- New `SessionStatus.Tests.ps1` — runs the emitted status script from an unrelated CWD
  with pinned user-settings / storage paths: root resolved from its own location, every
  section printed, both vendor clones reported, the three scope strings, the exact saved-
  file warning (and its absence when none opens the root or the user-level flag is set),
  the workspace-relative count excluding entries that do not resolve.
- Tests 122 → 144.

## [v0.5.1] - 2026-10-05

A hardening patch driven by an independent review of v0.5.0 plus two further passes of
our own (the second against the moved upstream skills repo): the failure paths of the
vendor refresh, the update commit, the PAC helper and the integrity model now behave the
way the documentation already said they did, and the agent hand-offs match what the
agent files are actually allowed to do. No change to the agent team or the protocol
other than one addition: **Copilot Studio becomes a first-class department**.

### Added

- **090 - Copilot Studio Lead** — a ninth Team Lead under the Master (also reachable from
  the Architect) that owns Copilot Studio agents authored as MCS2 YAML projects with
  `pac copilot` (init / clone / pull / push / publish / delete, knowledge, agent skills).
  Publish is treated as a shared-environment action (`APPROVED:PUBLISH:<agent>@<env>`),
  delete needs `APPROVED:DELETE:<agent>`; Production keeps `confirm push to prod`
- **Second Microsoft vendor clone** — the installer now maintains
  [microsoft/copilot-studio-plugin](https://github.com/microsoft/copilot-studio-plugin)
  next to `power-platform-skills`, from one `$vendorClones` table that drives cloning,
  force-refresh (`Update-VendorClone`), `.gitignore`, `search.exclude`,
  `chat.agentSkillsLocations` (`copilot-studio-plugin/skills` is registered natively),
  the knowledge catalog, keyword skill discovery and the status script. Adding a vendor
  is one table row plus a Lead whose `primarySkills` names the plugin id
- **Worker discovery generalised to both vendor layouts** — `Get-PluginRoots` resolves
  plugin ids to folders for the multi-plugin layout (`<clone>/plugins/<plugin>`) and the
  single-plugin layout (`<clone>` is the plugin). Microsoft's four Copilot Studio workers
  (Architect, Describer, Init, Manage) are discovered from `copilot-studio-plugin/agents/`
  and wrapped as hidden `090-sub-*` sub-agents with the same pointer-not-fork contract;
  additions and removals upstream create / prune wrappers on the next installer run. The
  wrapper translation table now also covers this vendor's conventions (`Skill` tool and
  `mcs-assistant:<skill>` references -> that plugin's `skills/<skill>/SKILL.md`;
  `pluginRoot` from `plugin-paths.json` -> the clone folder)
- Manifest `vendorCommits` (one entry per clone) replaces `skillsCommit`; the status
  script reports freshness and generation drift for every clone; the Workspace Maintainer
  refreshes both. Docs that said Copilot Studio had no dedicated Microsoft skill are
  updated (only Dataverse schema remains source-edited)

### Fixed

- **Vendor refresh could report success after a failed reset** — `Update-VendorClone`
  read `$LASTEXITCODE` after a later `rev-parse`, so a failed `reset --hard` still printed
  "already at upstream" and returned `$true`; a failed `stash` was not checked before the
  reset either. It now resolves the upstream commit up front, checks every step's exit code
  immediately (including both `git status` calls - an unreadable working tree skips the
  refresh instead of resetting over it), aborts when the stash or reset fails, and returns
  `$true` only when `HEAD` equals that upstream commit. It also follows the default branch
  origin advertises now (`ls-remote --symref`), so an upstream rename no longer strands the
  clone on a stale `origin/HEAD`. When a dirty clone fails to reset the message says the
  edits are in the stash and how to get them back. Full ref names replace the `^{commit}`
  peel syntax (whose caret cmd-based git shims swallow - the old reset-failure test was
  passing because of that, not because the reset path ran)
- **Update commit touched the user's index** — Step 7 ran `git add .`, which swept
  in-progress solution edits and three machine-specific files that older versions had
  committed before they were `.gitignore`d (`tool-status.json`, `guardrail-status.json`,
  `installed-manifest.json`); an unqualified `git commit` also committed whatever the user
  had staged themselves, and files pruned by the installer were deleted on disk but never
  committed. Update mode now commits from an isolated index (`GIT_INDEX_FILE`): it untracks
  exactly those three machine files, adds only installer-owned paths, stages the deletions
  it made, checks the add/commit exit codes, and then re-syncs just those paths in the
  user's real index. Whatever the user had staged stays staged and uncommitted
- **Worker-wrapper prune matched too broadly** — any `*-sub-*.agent.md` was removed on
  update, including a user's own agent with that substring in its name. The prune now
  requires the three-digit Lead prefix *and* the wrapper marker in the file body
- **Integrity model** — discovered worker wrappers were not in the manifest, so
  `-VerifyRoot` was blind to them and the self-test counted them as "user agents"; the
  merge files (`settings.json`, `mcp.json`, `.code-workspace`) were hashed even though they
  legitimately hold user keys, so a user setting - or the status script registering a new
  skill folder - showed up as drift. The manifest now has three sections: `files` and
  `discovered` are SHA256-hashed; `merged` lists the required keys. `-VerifyRoot` checks
  those keys by **value** (`requiredTrue`: a present-but-`false`
  `allowInvocationsFromSubagents` is reported as `KEY DISABLED`), rejects a manifest with no
  hashed files (`EMPTY MANIFEST`), and reads config files the way VS Code does. The
  self-test reports "N discovered worker(s)" separately
- **Config merge replaced files it could not parse** — a `settings.json` with comments or
  trailing commas (normal for VS Code) failed `ConvertFrom-Json`, was backed up and
  overwritten with only the installer keys. `Merge-JsonSettings` now reads JSONC (comments
  outside strings, trailing commas, UTF-8 BOM) and preserves every user key (the commented
  original is kept as `.bak`); a file that still does not parse is left untouched,
  reported in the summary and surfaced by `-VerifyRoot` as `UNPARSEABLE`
- **Folder rename lost the workspace file's user settings** — the `<folder>.code-workspace`
  is named after the folder; after a rename the installer created a fresh one and pruned the
  old one. It now uses the previously shipped file (named in the old manifest) as the base,
  so user folders and settings carry over before the old file is pruned
- **Legacy orphan removal by name only** — `.github/copilot/` and `.session-active` were
  deleted whenever present. They are now removed only when their content is recognisably
  installer output; otherwise they are reported and left
- **Settings merge dropped nested user keys** — `Merge-SettingValue` only recursed into
  `[hashtable]` values; the `[ordered]` skill-location map was therefore replaced, not
  merged, on update. It now recurses into any dictionary, so user-added
  `chat.agentSkillsLocations` entries survive
- **`scripts/pac-workflows.ps1`** — ran pack, import and commit without checking exit codes
  (a failed pack could import the previous package), treated `-Environment` as a label
  only, classified Production by the word "prod" in the label or org (an environment
  called "Treasury Live" sailed through), fell open when the post-import `pac solution list`
  failed, accepted `SolBackup` as proof that `Sol` was imported, resolved `./` paths against
  the caller's CWD, accepted `..` as a name, and committed with `git add .`. It now stops at
  the first failed `pac` / `git` step, deletes any previous package before packing, anchors
  every path to the workspace that contains it, rejects dotted or path-like names, resolves
  the real target with `pac org who` and **requires** it to match the label's URL (from the
  user-owned `.github/agent-docs/environments.json` map or `-EnvironmentUrl`; an unmapped
  label is refused), classifies Production from that map (the name heuristic remains only as
  an extra guard), verifies the import with `pac solution list --json --environment <url>`
  by **exact** unique name and fails closed when the list cannot run, and stages / commits
  only the solution's own folder (`git commit -- <folder>`, so the user's own staged files
  stay staged). A fake-`pac` test suite covers each of these paths
- **Team Leads could not reach the agents their instructions told them to use** — the Lead
  body said "dispatch the Solution Architect / QA", but discovery overwrote the Lead's
  `agents:` list with its workers only, so the dispatch was refused. Leads now declare
  `001 - Solution Architect` and `002 - Integration QA & Change Controller` as children
  and discovery **merges** workers into that list. The Architect's mid-work mode is told
  never to dispatch a Lead back (loop guard)
- **Worker wrappers mapped an omitted `tools:` key to read-only** — Microsoft omits the key
  on e.g. `code-app-architect` (meaning "inherit everything" in its runtime), which left
  the wrapper unable to run `node --version` or write a plan. An omitted key now maps to a
  bounded `read/search/edit/execute` set with no MCP servers. The wrapper translation table
  also covers the vocabulary Microsoft's newer workers use: `EnterPlanMode`/`ExitPlanMode`
  (-> `NEEDS APPROVAL` with the plan attached), `TaskCreate`/`TaskUpdate`/`TodoWrite`
  (-> inline checklist), `apply_patch` (-> `edit`), `${CLAUDE_PLUGIN_ROOT}`
- **Keyword skill discovery crossed plugin boundaries** — a Lead's keywords (`dataverse`,
  `deploy`, `mcp`) matched skills in other plugins and attached them to the wrong team, and
  matching ran on a description truncated to 160 characters. Matching is now scoped to the
  Lead's own plugins (the ALM Lead to the Pages ALM skills; executives unscoped) and uses
  the full description
- **Startup script invoked by relative path** — `starting-flow.md` told the Master to run
  `-File .github/agent-docs/Get-SessionStatus.ps1`, which fails whenever the terminal's CWD
  is not the workspace root (typical in a multi-root window). The flow now carries the
  absolute path for this install
- **Purge allow-list** now includes a root-level `*.code-workspace` shipped under a
  previous folder name

### Changed

- **Retry rule corrected** — a dispatch is **not** retry-safe when its WORK ORDER could have
  written anything: the child may have finished before the response was lost. Retries are
  limited to read-only calls and read-only dispatches; anything that could have written is
  reconciled first (`git status`/`diff` on the artifact, `pac solution list`, a fresh
  `sync_canvas`, run history) and re-dispatched only for what is verifiably missing. The
  dispatch-health rule now lists the three real causes of a refused dispatch (window
  setting, name not in `agents:`, unparseable target file)
- **Authoring-model docs** — "offline works for EVERY component / non-canvas -> offline
  only" is replaced by a component matrix (canvas, cloud flow, desktop flow, model-driven
  XML, generative pages, code app, mobile app, Pages site, Dataverse schema) that says
  which path applies to each; "read every guide before acting" is replaced by task-relevant
  selection that honours the vendor skills' own conditional reads; Phase 2 sign-in is
  required only when the task touches an environment
- **Catalog facts aligned with upstream** — code apps use the template's Power Apps CLI via
  `npx --no-install pa` (resolved per `code-apps/shared/cli-binary.md`), not `pac code`;
  code and mobile apps need **Node.js 22+** (the installer still guarantees 18+ for the flow
  MCP and says so in `tool-status.json`); mobile validation no longer requires a deploy;
  the MCP App widget skill's two runtime modes (bundled or user-approved CDN) are described
  instead of "no external dependencies"; the Pages ALM skills referenced by the Architect
  and ALM Lead are labelled as worked examples, with `working-flow-reference.md` and
  `pac-workflows.ps1` as the generic authority
- **Manifest records `skillsCommit`** (the vendor clone commit the agents were generated
  from); the status script compares it with the clone's HEAD and asks for an installer
  re-run when they diverge, so a maintenance refresh cannot silently leave the worker roster
  and skill lists stale. `.NET` install arguments are quoted; `tool-status.json` carries a
  `runtimeNotes.node` line
- **Tests 85 → 122** — `VendorClone` (+5: stash-fails, reset-fails *reaching the reset*,
  dirty-clone recovery message, status-fails, renamed default branch), new
  `PacWorkflows.Tests.ps1` (fake `pac` on PATH: unmapped label, mapped-URL mismatch,
  explicit URL mismatch, dotted names, map-classified Production without "prod" in the name,
  prod-looking org, `-ConfirmProd`, failed pack, stale zip, exact-name verification,
  list failure fails closed, wrong CWD, user-staged file untouched, pull), `Discovery` (+5:
  Architect/QA kept in the Lead list without duplicates, omitted `tools:` default, upstream
  vocabulary translation, wrappers hashed and verified, self-test classification),
  `Generated` (+7: value-checked keys, empty manifest, JSONC merge, unparseable file left
  alone, folder-rename migration, absolute status path + conditional sign-in, capability
  matrix, `vendorCommits`, Copilot Studio documented as a department), `Discovery` (+3 for the
  single-plugin vendor layout: 090 wiring + `mcs-assistant:` translation, skill registration
  scoped to the 090 Lead, pruning), `Manifest` (13 agents / 9 Leads), `Version` (+1: the README
  test count must equal the number of
  `It` blocks; the CHANGELOG check now anchors on the *first* heading). Test suites restore
  the `GIT_*` identity variables they set; `Run-Tests.bat` propagates the failure count as
  its exit code
- **Version bumped to `0.5.1`** across the installer stamp, embedded manifest, README
  status heading, `.bat` launcher, and this changelog

## [v0.5.0] - 2026-09-14

Fine-tunes the delegation model so the three-tier team (Master → Team Lead →
Microsoft worker) runs end to end, gives every agent its own specialist knowledge,
hardens the vendor refresh, and makes startup lean. Same principles and vocabulary as
the Fabric twin's v0.7.0, adapted to the Power Platform domain.

### Fixed

- **Nested delegation now enabled** — VS Code keeps subagent → subagent calls off by
  default (`chat.subagents.allowInvocationsFromSubagents` = false), so a Team Lead dispatched
  by the Master could not reach its Microsoft workers. The installer now writes the setting
  (forced `true`) into `.vscode/settings.json` **and** into a managed `<folder>.code-workspace`
  that it opens VS Code from — the key is window-scoped, so in a multi-root window only the
  workspace file (or user settings) counts. The status script checks it every session
  and every delegating agent carries a *dispatch health* rule that names this exact cause
- **Worker permissions mirror Microsoft's** — wrappers previously took their Lead's MCP
  grant. They now mirror the worker's **own** `tools:` list (`mcp__x__y` / `x/y` → `x/*`,
  `Write`/`Edit` → `edit`, `Bash` → `execute`); a builder Microsoft gave no MCP tools gets
  none. The Discovery test now asserts this
- **`.github\hooks` left alone** — the legacy-orphan cleanup no longer removes this folder,
  which VS Code now uses for user hooks. Only `.github\copilot` and `.session-active` are
  still purged
- **Vendor refresh made observable** — `Update-VendorClone` discards git's stderr with
  `2>$null` (a `2>&1` under `$ErrorActionPreference = 'Stop'` can abort the reset silently),
  checks `$LASTEXITCODE`, falls back to `reset --hard '@{upstream}'`, and prints
  `refreshed: <old> -> <new>` / `already at upstream`. New `tests/VendorClone.Tests.ps1`
  proves it on a local bare repo (no network)
- **Update commit** now compares `HEAD` before/after instead of relying on `$LASTEXITCODE`
- **Managed-file reference** — `copilot-instructions.md` no longer cites
  `schema/agent-manifest.schema.json`, which lives in this repo rather than the generated
  workspace

### Added

- **Team protocol** in `working-flow-reference.md` and every agent: `WORK ORDER`
  (goal, artifact, mode, constraints, validation expected, approvals granted, context) →
  `WORK RESULT` (`DONE | DONE WITH RISKS | NEEDS APPROVAL | NEEDS INPUT | NEEDS ARCHITECT |
  OUT OF SCOPE | FAILED`); the Architect returns a **PLAN**, QA a **VERDICT**; the Master
  runs **three loops** (Simple / Designed / Blocked) and keeps a **session ledger**
- **Approval tokens** — destructive or shared-environment actions need a literal
  `APPROVED:<ACTION>:<artifact>` (Production import keeps `confirm push to prod`).
  Plain-words "do it now" is not a token; workers without one stop and return
  `NEEDS APPROVAL`; only the agent the user selected can ask. Microsoft's mid-build
  plan approvals ride the same channel instead of telling the user to switch agents
- **Specialist agents** — a knowledge catalog (`$agentKnowledge`) renders per-agent
  `## Knowledge and skills` (paths resolved against the real clone at install time;
  renamed upstream folders self-heal, missing ones get a *re-discover by keyword* hint),
  `## Playbook`, `## Validation you must run before reporting`, `## Tool ladder` and
  `## Avoid`; keyword matching against an index of every upstream `SKILL.md` appends
  *"Also relevant – auto-discovered"* skills so new Microsoft additions attach on the
  next run without a catalog edit
- **Leads know their team** — discovery injects a `## Your team` table (dispatch name →
  Microsoft name → tools → definition file) between `<!-- team-roster -->` markers and a
  `## How you dispatch` section; Microsoft's `SKILL.md` says "invoke
  `canvas-screen-builder`", the Lead dispatches `010-canvas-screen-builder`
- **Lean worker contract** — wrappers tell the worker its WORK ORDER is the complete brief
  (no startup, no flow docs), translate the Claude Code runtime (`Task`, `AskUserQuestion`,
  `${PLUGIN_ROOT}`), carry the token rule, never delegate, and end with a WORK RESULT
- **`Get-SessionStatus.ps1`** (managed, in the manifest) — one CWD-independent call prints
  `ROOT / SKILLS / CONFIG / IDENTITY / ENV / TOOLS`: clone commit date and commits behind,
  custom-skill date with a >30-day hint, skill locations (self-registers new plugin
  folders), nested-dispatch check, active `pac auth` profile + environment URL (`az`
  fallback), and a live tool re-check that rewrites `tool-status.json`
- **Skills registered natively** — `Get-SkillContainerDirs` scans
  `power-platform-skills/plugins/*/skills` and registers every container in
  `chat.agentSkillsLocations` (plus `.github/skills`), so agents see the catalogue without
  `ls`
- **`microsoft-learn` MCP** (HTTP, no install) registered in `.vscode/mcp.json` and granted
  to the Solution Architect and all eight Team Leads
- **`power-apps-mobile-extension`** plugin (12 `.ppmplugin` skills) attached to the Mobile
  Apps Lead
- **Gated SYNC** capability — lists unmanaged, non-Microsoft solutions and pulls only what
  the user picks (`APPROVED:SYNC:<env>` for more than one); replaces the startup
  "pull every solution" phase
- **Code-level Production gate** — `scripts/pac-workflows.ps1 push` to PROD requires
  `-ConfirmProd`
- **Maintenance handoff** button on the Master → `003 - Workspace Maintainer`, which now
  offers light / deep maintenance when selected directly
- **Tests 53 → 85** — generated-content assertions (Knowledge / Playbook / Validation,
  WORK RESULT, token rule, Lead roster + dispatch-name rule, PLAN / VERDICT, three loops +
  ledger, heading spacing, no unresolved managed refs), emitted-config assertions (nested
  setting on in `settings.json` and the `.code-workspace`, skill locations, three MCP
  servers, status script parses and is in the manifest, lean starting flow, gated SYNC,
  `-ConfirmProd`), Discovery (own-tools mirroring, roster injection, placeholder for Leads
  without workers, lean worker contract), `VendorClone.Tests.ps1`, and the `.bat` banner
  version check

### Changed

- **Startup is lean** — `starting-flow.md` is now: classify, one status-script call, sign-in
  / environment **only if missing**, MCP probed lazily by the owning Lead, straight to the
  request. The `[S] set me up / [W] just work` menu, the inventory phase and the
  sync-everything phase are gone; upstream freshness is a one-line hint, never a prompt
- **Master** — the "Routing is invisible" rule and the "Degraded-mode direct dispatch"
  fallback are retired (they worked around the nested-dispatch setting, which is now
  written by the installer); the Master is the only voice to the user, confirms destructive
  requests up front, and lists only its children in `agents:`
- **Operating contract is tier-aware** — Master runs startup; executives and Leads follow
  the working-flow reference and return open questions when dispatched; the
  "read the plugin `AGENTS.md`" step is replaced by an explicit translation of the plugin
  runtime's tool names (`Task`, `AskUserQuestion`, `${PLUGIN_ROOT}`)
- **Installer step order** — the skills clone/refresh now runs **before** agent generation
  (Step 4) so knowledge references resolve and worker discovery has one call site right
  after the agents loop; the `.bat` banner and window title carry the version
- **Version bumped to `0.5.0`** across the installer stamp, embedded manifest, README
  status heading, `.bat` launcher, and this changelog

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
