# Security policy

## Supported versions

Only the latest release gets fixes. Older tags stay available for pinning, but are not patched.

| Version | Supported |
|---|---|
| 0.4.x | yes |
| older | no |

## Report a vulnerability

Do not open a public issue. Report it privately through [GitHub security advisories](https://github.com/Vyrenbusiness-source/warmd-fewer-tokens-faster-agents/security/advisories/new).

Include the warmd version (the first line of `warmd status`), your Windows version, and the steps that show the problem. You get a first answer within 7 days. A confirmed problem is fixed in a new release and credited to you unless you ask not to be named.

## What warmd does on your machine

These are the parts worth checking when you review it. The README section [Safety](README.md#safety) has the full list.

- It starts and stops only processes it started itself, and refuses to run when an editor you opened has the project open.
- It writes to `.warmd/` in the project, to `~/.cache/warmd`, and during `warmd init` to the agent definitions, the instruction file and the hooks of the project.
- It sends no telemetry. Network use is limited to your own git remote, `gh` for pull requests and CI when you use GitHub, and `warmd update` when you run it.
- The installers download from this repository only. The PowerShell installer also installs Git for Windows with `winget` when it is missing; `WARMD_NO_GIT_INSTALL=1` turns that off. Set `WARMD_VERSION_TAG` to pin a reviewed version.
