# Changelog

## 0.12.0-r6

- Fix Pi Web global MCP servers not reaching Claude Code or Codex in the browser terminal. The refresh launchers lived in `~/.local/bin`, but the terminal is a login shell whose rebuilt PATH skipped that directory, so `claude mcp list` and `codex mcp list` stayed empty until the container restarted (same defect measured on the HA add-on). `/usr/local/bin/claude` and `/usr/local/bin/codex` are now wrappers that refresh the shared MCP/skills state before every launch, whatever PATH the caller has, then exec the pinned binaries.
- The refresh summary is discarded so `claude -p` / `codex exec` output stays machine-readable; a failed refresh is reported on stderr and the CLI still starts.
- Retire the `~/.local/bin` launchers written by 0.12.0-r5 and earlier; user-owned binaries there are kept and keep precedence.
- The terminal's login shell puts `$HOME/.local/bin` back before the system bins, matching the Quadlet service PATH.
- Load the profile with `.` instead of `source`, so POSIX login shells (`sh -l`) no longer print `source: not found` (same fix as the k3s package 0.2.5).
- Tolerate two CLI launches refreshing the shared skills links at the same time.

## 0.12.0-r5

- Share only Pi Web-installed skills and global MCP servers with Claude Code and Codex.
- Stop importing portable Pi plugin skills and MCP servers; remove links left by earlier releases.

## 0.12.0-r2

- Upgrade pi-web to 0.12.0, including the upstream pre-0.11 password-bypass security fix and Pi 1.0/MCP support.
- Fix ChatGPT subscription OAuth with a durable installation UUID. Image-build checks exercise the real SDK and OAuth provider, stopping before account authorization.
- Include Claude Code 2.1.296 and Codex 0.162.1 from a lockfile. Existing user-local binaries keep precedence.
