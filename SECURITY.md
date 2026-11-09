# Security Policy

## Security Model

- **Zero Inbound Attack Surface**: Communicates exclusively via outbound HTTPS long-polling (`getUpdates`) to `api.telegram.org`. No open ports, webhooks, or public tunnels are required.
- **Ephemeral Per-Run Session Password**: Entered fresh in your local macOS terminal on every `npm start` and stored strictly in process RAM — never persisted to disk.
- **Console-Only Infrastructure Setup**: Workspace paths and Jenkins credentials can only be added or modified from your local macOS terminal (`npm run setup`, `npm run add-ide`, `npm run update-jenkins`), with `0600` owner-only file permissions on `data/config.json`.

## Reporting a Vulnerability

Please report security vulnerabilities privately via [GitHub Security Advisories](https://github.com/madmicrowave/phone-agent-control/security/advisories/new) rather than opening a public issue.
