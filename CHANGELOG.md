# Changelog

## 0.12.0-r2

- Upgrade pi-web to 0.12.0, including the upstream pre-0.11 password-bypass security fix and Pi 1.0/MCP support.
- Fix ChatGPT subscription OAuth with a durable installation UUID. Image-build checks exercise the real SDK and OAuth provider, stopping before account authorization.
- Include Claude Code 2.1.296 and Codex 0.162.1 from a lockfile. Existing user-local binaries keep precedence.
