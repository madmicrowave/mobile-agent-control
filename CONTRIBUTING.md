# Contributing to MAC (Mobile Agent Control)

Thank you for contributing to **MAC (`mobile-agent-control`)** — open-source native macOS menu bar app & Telegram controller for **Google Antigravity (`agy`)** Workspaces, Git, and Jenkins CI/CD!

## Local Development

1. Fork and clone the repository:
   ```bash
   git clone https://github.com/madmicrowave/mobile-agent-control.git
   cd mobile-agent-control
   ```
2. Run the offline Node.js & Swift automated test suites:
   ```bash
   npm test
   ```
3. Build the standalone macOS menu bar app (`MAC.app`):
   ```bash
   npm run build:app
   ```

## Pull Request Guidelines

- Keep runtime dependencies at **zero** (native Swift/AppKit/SwiftUI + pure Node.js 20+ standard library ES Modules).
- Never commit `data/`, `.env*`, `MAC.app/`, bot tokens, or credentials.
- Add or update tests in `test/bot.test.mjs` and/or `Tests/MACAppTestMain.swift` and ensure `npm test` passes cleanly.
