# Backlog

## Security (deferred)

- Secret and pattern scanning (gitleaks) before pushing role memory.
- Rules on what roles must not store in memory: code, credentials, customer data, internal URLs.
- Network restrictions for role containers.
- Platform guardrails and hooks for dangerous commands (force-push, production, destructive operations).
- Separate tokens with different scopes per role (GitLab PAT, Atlassian API token).

## Platform

- Telegram access from outside the local machine (tunnel) for approvals from a phone and bot commands.
- Parallel runs of the same role.
