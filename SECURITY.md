# Security Policy

## Supported Versions

| Version | Supported |
|---|---|
| 0.1.x-preview | :white_check_mark: |

## Reporting a Vulnerability

If you discover a security vulnerability in this project, **please do not open
a public issue**. Instead, report it privately so it can be addressed before
being disclosed.

**Email:** [steciurlia@gmail.com](mailto:steciurlia@gmail.com)

Please include:
- A description of the vulnerability
- Steps to reproduce it
- Any potential impact you've identified

You should receive an acknowledgement within 48 hours. The maintainer will work
with you to understand and address the issue before any public disclosure.

## Scope

This project consists of PowerShell scripts that run locally on the user's
machine and a Copilot agent definition file. Security concerns might include:

- Unintended code execution in the setup script
- Credential or token exposure in generated files
- Unsafe defaults in the agent definition that could lead to data loss
- Path traversal or injection issues in the installer

Thank you for helping keep this project safe.
