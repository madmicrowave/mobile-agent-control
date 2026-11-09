# Contributing to Phone Agent Control

Thank you for contributing to **Phone Agent Control** — open-source macOS software for controlling local **Google Antigravity IDE (`agy`)** coding agents, Git, and Jenkins CI/CD from Telegram!

## Local Development

1. Fork and clone the repository:
   ```bash
   git clone https://github.com/madmicrowave/phone-agent-control.git
   cd phone-agent-control
   ```
2. Run the offline unit & end-to-end test suite (uses Node.js 20+ built-in `node --test`, mock Telegram & Jenkins HTTP servers, and temporary Git repos):
   ```bash
   npm test
   ```

## Pull Request Guidelines

- Keep runtime dependencies at **zero** (pure Node.js 20+ standard library ES Modules).
- Never commit `data/`, `.env*`, bot tokens, or credentials.
- Add or update tests in `test/bot.test.mjs` for all workflow or parser changes and ensure `npm test` passes cleanly.

