# Security Policy

## Security Model

- **Zero Inbound Attack Surface**: Communicates exclusively via outbound HTTPS long-polling (`getUpdates`) to `api.telegram.org`. No open ports, webhooks, or public tunnels are required.
- **Ephemeral Per-Run Session Password**: Entered fresh in the native macOS password dialog on every `Start...` / `Restart...` and stored strictly in process RAM — never persisted to disk.
- **Local-Only Infrastructure Setup**: Workspace paths and CI/CD credentials (Jenkins, GitHub, Google Cloud) can only be added or modified locally on your Mac via **mac.app** or local terminal scripts (with `0600` owner-only file permissions on `data/config.json`) — never from Telegram.
- **100% Air-Gapped / Private Local AI Models**: When using Direct API with local models (Ollama, LM Studio, vLLM, LocalAI, Jan), code inspection, autonomous tool calls, file edits, and prompts execute completely offline on your local Mac — zero source code or prompts ever leave your machine.

## Reporting a Vulnerability

Please report security vulnerabilities privately via [GitHub Security Advisories](https://github.com/madmicrowave/mobile-agent-control/security/advisories/new) rather than opening a public issue.
