# Contributing to Power Platform Workspace One-Click Setup

First off — thank you for considering contributing! This project is in
**pre-release** and actively looking for feedback, ideas, and improvements
from the community.

## How can I contribute?

### Reporting bugs

Found something broken? [Open a bug report](https://github.com/SteCiu01/Power-Platform-Workspace-One-Click-Setup/issues/new?template=bug_report.md).

Please include:
- Your OS and PowerShell version
- Steps to reproduce
- What you expected vs what happened
- Any terminal output or screenshots

### Suggesting features or improvements

Have an idea? [Open a feature request](https://github.com/SteCiu01/Power-Platform-Workspace-One-Click-Setup/issues/new?template=feature_request.md).

All ideas are welcome — from small quality-of-life tweaks to entirely new
agent workflows.

### Submitting code changes

1. **Fork** the repository
2. **Create a branch** from `main`:
   ```
   git checkout -b feature/your-feature-name
   ```
   Use prefixes: `feature/`, `fix/`, `docs/`, `chore/`
3. **Make your changes** — keep commits focused and atomic
4. **Test your changes**:
   - Run the `.bat` installer on a clean folder to verify setup works end-to-end
   - If you modified the agent definition, test it in VS Code Copilot Chat
   - If you modified the PowerShell script, test on both PowerShell 5.1 and PowerShell 7+ if possible
5. **Open a pull request** against `main`

### What's a good first contribution?

Look for issues labelled [`good first issue`](https://github.com/SteCiu01/Power-Platform-Workspace-One-Click-Setup/labels/good%20first%20issue)
or check the [current status table in the README](README.md#current-status-v010-preview)
for areas marked "Not yet".

Some ideas:
- Cross-platform setup script (bash/zsh for macOS/Linux)
- Automated tests for the installer script
- Improved error messages or UX in the setup flow
- Additional agent workflows or skill integrations
- Documentation improvements

## Development setup

To work on this project locally:

1. Clone your fork:
   ```
   git clone https://github.com/<your-username>/Power-Platform-Workspace-One-Click-Setup.git
   ```
2. The project has no build step — the deliverable is the two installer files
   inside `power-platform-workspace-installer/`.
3. To test, double-click `Setup-PowerPlatformWorkspace.bat` or run the `.ps1`
   directly in PowerShell.

## Code style

- **PowerShell**: Use full cmdlet names (not aliases), meaningful variable names, and comment non-obvious logic
- **Markdown**: Use ATX headings (`##`), keep lines under 80 characters where practical
- **Agent definitions**: Follow the existing structure in `power-platform-master-agent.agent.md` — clear phases, explicit instructions, no ambiguity

## Commit messages

Use [Conventional Commits](https://www.conventionalcommits.org/) style:

```
feat: add macOS setup script
fix: handle spaces in folder names
docs: clarify PAC CLI installation steps
chore: update power-platform-skills clone URL
```

## Pull request guidelines

- Reference the related issue if one exists (e.g. `Closes #12`)
- Describe what changed and why
- Keep PRs focused — one feature or fix per PR
- Be open to feedback and iteration

## Code of Conduct

This project follows the [Contributor Covenant Code of Conduct](CODE_OF_CONDUCT.md).
By participating, you agree to uphold it.

## Questions?

Open a [discussion](https://github.com/SteCiu01/Power-Platform-Workspace-One-Click-Setup/issues)
or reach out via the issue tracker. There are no bad questions.
