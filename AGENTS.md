# Repository Guidelines

## Product Overview
This repository is for a "VPN in a box" appliance: a plug-and-play computer that connects a local subnet to a remote VPN server. It should also support travel use cases, allowing a laptop user to connect back into the home internal network through this mini-computer.

## Project Structure & Module Organization
Organize the code around the appliance responsibilities: VPN connectivity, routing, device setup, and remote access. Place application code in `src/`, tests in `tests/`, automation in `scripts/`, and supporting docs or assets in `docs/` or `assets/`.

Keep modules focused and small. Prefer names that describe behavior, such as `src/vpn/client.py`, `src/routing/subnet_manager.py`, or `scripts/bootstrap_appliance.sh`, rather than vague names like `utils.py`.

## Build, Test, and Development Commands
No standard build or test commands are defined yet. When you add tooling, expose the primary workflows through documented entry points so other contributors do not need to guess.

Examples:
- `make test` runs the full test suite
- `make lint` runs formatting and lint checks
- `scripts/dev.sh` starts a local development workflow

If you introduce a new command surface, document it here in the same change.

## Coding Style & Naming Conventions
Use 4 spaces for indentation in Python and shell scripts with consistent line wrapping and no trailing whitespace. Match the formatter and linter used by the language you add; for example, Python should use `ruff` or `black`, and shell scripts should pass `shellcheck` when applicable.

Use `snake_case` for files and functions, `PascalCase` for classes, and descriptive directory names. Avoid one-letter variables outside short loops.

## Testing Guidelines
Add tests alongside every new feature or bug fix. Mirror the source layout under `tests/`; for example, `src/network/client.py` should usually map to `tests/network/test_client.py`.

Prefer deterministic unit tests first, then add integration coverage only where behavior crosses process or network boundaries.

## Commit & Pull Request Guidelines
No Git history is available in this workspace, so use clear Conventional Commit style messages such as `feat: add bootstrap script` or `fix: handle missing config`.

Pull requests should include a short problem statement, a summary of the change, verification steps, and any relevant logs or screenshots for user-facing behavior. Keep PRs focused; separate refactors from functional changes.

## Security & Configuration Tips
Do not commit secrets, certificates, private keys, or real VPN credentials. Store local-only settings in ignored env files such as `.env.local`, and provide sanitized examples like `.env.example` when configuration is required.
