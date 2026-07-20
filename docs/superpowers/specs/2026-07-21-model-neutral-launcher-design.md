# Model-Neutral Claude Launcher Design

## Goal

Make the globally installed PM Orchestrator independent of any Claude Code model or provider. Starting through the launcher should only enable unattended permissions and expose the PM helper paths; Claude Code settings and the current shell remain the sole source of model, provider, authentication, effort, and concurrency configuration.

## Design

- Replace `launch-claude-deepseek.sh` with `launch-claude.sh`.
- The launcher exports only `PM_HANDOFF_TOOL` and `PM_CLAUDE_LAUNCHER`.
- It invokes `claude --permission-mode bypassPermissions "$@"` without `--model` and without changing Claude-related environment variables.
- The global installer removes both legacy GLM and DeepSeek launchers after copying the current skill.
- Worktree instructions and README examples use the neutral launcher and contain no provider-specific guidance.

## Compatibility

Arguments supplied by the user are forwarded unchanged after the required permission flag. Existing Claude Code settings, environment variables, credentials, and default subagent routing remain active. The PM loop continues to use `PM_CLAUDE_LAUNCHER`, which now resolves to the neutral launcher.

## Verification

- A launcher test seeds model, provider, authentication, effort, subagent, and concurrency variables and asserts they are preserved.
- The test asserts that the launcher adds only `--permission-mode bypassPermissions` before caller arguments.
- Global installation tests assert the neutral launcher is installed and both legacy launchers are removed.
- Contract and full shell test suites must pass before installation and push.
