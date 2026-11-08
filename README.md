# Phone Agent Control (`phone-agent-control`)

[![Platform: macOS](https://img.shields.io/badge/Platform-macOS-000000?logo=apple&logoColor=white)](https://github.com/madmicrowave/phone-agent-control)
[![AI: Google Gemini](https://img.shields.io/badge/AI-Google%20Gemini-4285F4?logo=google&logoColor=white)](https://gemini.google.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-22c55e.svg)](./LICENSE)
[![Powered by DOMONK Factory](https://img.shields.io/badge/Powered%20by-DOMONK%20Factory-7c3aed)](https://domonk.com)

> **Open-Source macOS Software for Google Gemini & Antigravity IDE (`agy`)** — Free and open source for everyone under the MIT License.
>
> **Powered by [DOMONK Factory](https://domonk.com)** • Repository: **[github.com/madmicrowave/phone-agent-control](https://github.com/madmicrowave/phone-agent-control)**

**Phone Agent Control** is a self-hosted **macOS** application built for **Google Gemini** and **Google Antigravity IDE** (`agy`). It lets you remotely orchestrate local IDE workspaces on your Mac directly from **Telegram** on your phone — inspect recent conversation transcripts, send text and multi-photo prompts, choose the Google Gemini model and reasoning effort level per workspace, review modified files (`M` / `A` / `D`), commit and push to default or custom Git branches, trigger parameterized **Jenkins** CI/CD deployments, inspect build failure logs, and revert bad commits in one tap.

Because it communicates via outbound HTTPS long-polling (`getUpdates`) to `api.telegram.org`, **no inbound ports, port forwarding, reverse proxies, ngrok tunnels, or public webhooks are required** — it works seamlessly over 5G/LTE cellular and any Wi-Fi network whenever your Mac is online.

---

## Key Features

- **Built for Google Gemini on macOS**: Native orchestration of local **Google Antigravity (`agy`)** agent sessions powered by **Google Gemini** (`Gemini 3.8 Flash`, `Gemini 4 Argon`, plus automatic discovery of new `gemini-*` models via `agy models`) as well as **Claude Opus 5.5**, with configurable reasoning effort levels (`low`, `medium`, `high`) per IDE workspace.
- **Per-Run Ephemeral Session Password**: Every `npm start` prompts in your Mac terminal for a fresh session password (masked with `*` and held strictly in RAM — never stored on disk). Your Telegram session remains unlocked until you stop/restart the app or send `/lock`.
- **Console-Only Infrastructure Security**: Registering/removing IDE workspaces, setting/updating Jenkins credentials, and testing Jenkins connectivity happen **exclusively in your local macOS terminal** (`npm run setup`, `npm run add-ide`, `npm run update-jenkins`, `npm run test-jenkins`, or live console commands inside `npm start`). They are never exposed or modifiable in Telegram.
- **Focused Telegram Settings**: Telegram's `⚙️ Settings` (`/settings` / `/model`) is dedicated solely to switching the **AI model & reasoning level** (`low` / `medium` / `high`) per IDE workspace.
- **Multi-IDE Workspace Switching**: Switch across multiple single-repo or multi-repo monorepo workspaces at any time (`🔀 Switch IDE`), displaying each workspace's human-readable `label`. Each workspace independently preserves its active conversation and pending commit, branch, Jenkins, or revert decision.
- **Default Same-Chat Continuity & Transcript Reader**: **Same Chat (`✅ Same Chat`)** is active by default whenever you select an IDE — simply start typing or sending screenshots right away to continue the active conversation automatically, tap `🆕 New Chat` to start fresh, or tap `📜 Latest Messages` to inspect the latest `X` messages from `~/.gemini/antigravity/brain/<conversationId>/.system_generated/logs/transcript.jsonl` (`X` defined in `npm run setup`).
- **Smart Album & Long-Message Coalescing**: Automatically merges Telegram photo/file albums (`media_group_id`) and split `>4096`-character prompts into a **single** Google Gemini agent turn (supporting up to **5 attached images/files** at once).
- **Rich Telegram HTML Rendering**: Converts GitHub-Flavored Markdown (GFM) agent responses — headings, bold/italic, inline code, syntax-tagged `<pre><code>` blocks, lists, blockquotes/alerts, and local `file://` symbol links — into clean, balanced Telegram HTML chunks.
- **Interactive Git & Jenkins CI/CD Loop**:
  1. Lists modified/added/deleted files across all Git repositories in the workspace.
  2. Prompts **Commit & push?** (`✅ Yes` / `❌ No (discard turn edits)` / `🌿 Custom Branch`).
  3. Reports exact commit SHA(s) and remote branch via message text.
  4. Prompts **Run Jenkins?** (`VERSION=<branch>` parameterized builds, nested folder job support, multi-service selective or run-all triggers).
  5. Streams build status; on failure displays console error tail; on success asks **Is it okay?** (`✅ Yes` / `↩️ Revert (Mark Bad)` with optional rollback redeploy).
- **Zero Third-Party Dependencies**: Written in modern ES Modules using only the Node.js 20+ standard library.

---

## End-to-End Workflow

```text
Open Bot in Telegram (/start)
   │
   ▼
🔐 Enter Current Run Password (set in Mac terminal on `npm start`; auto-deleted from chat)
   │
   ▼
🗂 Select IDE Workspace
   │   (Tap "🔀 Switch IDE" anytime to jump between workspaces and resume pending steps)
   ▼
💬 Chat Mode (`✅ Same Chat` active by default; or tap "⚙️ Settings" to change AI Model & Level):
   ├── ✅ Same Chat (Default) ──► Start typing/uploading immediately to continue the active chat
   └── 🆕 New Chat           ──► Starts a fresh Antigravity conversation
   │
   ▼
✏️ Send Prompt Text and/or Up to 5 Photos/Screenshots
   • Multi-photo albums and split >4096-char messages coalesce into 1 single agent run
   • Photo(s) + caption runs immediately; photo(s) alone queues attachments for your prompt
   │
   ▼
🤖 Google Gemini (via `agy`) edits workspace files on your Mac
   │
   ▼
📝 Bot sends Formatted Agent Response + Changed Files (`M` / `A` / `D` per repo)
   Ask: Commit & push?
   ├── ❌ No            ──► Discards turn's uncommitted edits -> Ready
   ├── ✅ Yes           ──► Commits & pushes changed repos on configured/current branch
   └── 🌿 Custom Branch ──► Prompts for branch name -> `git checkout -B <branch>` -> commits & pushes
   │
   ▼
📣 Outputs Commit Summary (`sha -> origin/<branch>`)
   Ask: Run Jenkins?
   ├── ⏭ No  ─────────────────────────────────────────┐
   └── 🚀 Yes (`buildWithParameters?VERSION=<branch>`) │
          ├── ❌ Failed  ──► Outputs Console Error Log ┤
          └── ✅ Success ──► Shows Build Summary       │
                                                       ▼
                                          Ask: Is it okay?
                                          ├── ✅ Yes    ──► Confirms & unlocks IDE for next turn
                                          └── ↩️ Revert ──► `git revert` ("Revert ... (bad commit)") + push
                                                               │
                                                               ▼
                                                   📣 Outputs Revert Summary
                                                      Ask: Run Jenkins?
                                                      ├── 🚀 Yes ──► Redeploys reverted branch -> Ready
                                                      └── ⏭ No  ──► Finishes & unlocks IDE -> Ready
```

---

## System Requirements

- **macOS** (Apple Silicon or Intel)
- **Node.js 20+** (`node -v`) — zero external npm packages required
- **Google Antigravity CLI (`agy`)** installed and signed in with your Google Gemini / Antigravity account (`agy --version`)
- **Git** configured with SSH keys or macOS Keychain credential helper so `git push` runs non-interactively
- *(Optional)* **Jenkins** server URL, username, and API token for one-tap CI/CD deployments

---

## Installation & Quick Setup

### 1. Clone the Repository

```bash
git clone https://github.com/madmicrowave/phone-agent-control.git
cd phone-agent-control
```

### 2. Create Your Telegram Bot (`@BotFather`)

1. Open Telegram and message **[@BotFather](https://t.me/BotFather)**.
2. Send `/newbot`, choose a display name and a unique username ending in `bot`.
3. Copy the **HTTP API Token** (`123456789:AAH...`).
4. *(Optional)* Find your numeric Telegram User ID (e.g., via `@userinfobot`) if you want to restrict the bot to specific Telegram user ID(s) in addition to the per-run password.

### 3. Run the Interactive Console Setup Wizard

```bash
npm run setup
```

`npm run setup` configures `data/config.json` locally with `0600` owner-only permissions (gitignored):

1. **Telegram Bot Token** (from `@BotFather`)
2. **Allowed Telegram User IDs** (comma-separated numeric IDs, or `all`)
3. **Latest `X` Messages Count** (default `6` — fixed in Telegram from this setup setting)
4. **Jenkins Base URL** (e.g. `https://jenkins.example.com`, or `-` to skip)
5. **Jenkins Username**
6. **Jenkins API Token** + **Interactive Console Connection Test** (`Test Jenkins connection now?`)
7. **Workspaces Auto-Discovery, Google Gemini Model & Repository Mapping**:
   - Auto-discovers unregistered Git/IDE folders on disk (`+1`, `+2`, …) or accepts any pasted folder path (`~/code/my-project`).
   - Lets you choose each IDE's **AI model** (`gemini-3.8-flash`, `gemini-4-argon`, `claude-opus-5-5`) and **reasoning level** (`low`, `medium`, `high`).
   - Scans child Git repositories, detects active branches and `Jenkinsfile` hints, and lets you configure per-repo deploy jobs (including nested Jenkins folder paths like `Prod/Web/frontend-app`).

---

## Console Management Commands

All workspace registration and Jenkins credential operations are strictly local console commands:

```bash
npm run setup           # Full interactive setup wizard
npm run add-ide         # Scan & register an available IDE workspace (or edit existing IDEs)
npm run update-jenkins  # Set/update Jenkins URL, username & API token, and test connection
npm run test-jenkins    # Test Jenkins connectivity & list sample jobs in terminal
npm stop                # Stop any running bot process cleanly
```

---

## Starting the Bot

```bash
npm start
```

On every `npm start`:
1. Enter a fresh **session password** in your Mac terminal (never saved to disk).
2. Open your bot in Telegram, send `/start`, and enter that password (the password message is immediately deleted from Telegram chat history).
3. While `npm start` is running, you can also type live commands directly into the terminal window — `add-ide`, `update-jenkins`, `test-jenkins`, `setup`, `status`, or `help` — and changes hot-reload in memory without restarting the bot.

To keep your Mac awake during long remote sessions:

```bash
caffeinate -dimsu npm start
```

---

## Telegram Controls & Slash Commands

Once unlocked, a persistent 4-button reply keyboard stays pinned at the bottom of Telegram:

| Button / Command | Description |
| :--- | :--- |
| **🔀 Switch IDE** (`/ides`) | Switch between registered IDE workspaces; each preserves its active chat and pending step. |
| **📜 Latest Messages** (`/history`) | Show the latest `X` user/agent messages from the Antigravity conversation transcript. |
| **🆕 New Chat** (`/newchat`) | Start a fresh Google Gemini conversation in the selected IDE workspace. |
| **⚙️ Settings** (`/settings`, `/model`) | Change the **AI model** (`Gemini 3.8 Flash`, `Gemini 4 Argon`, `Claude Opus 5.5`) and **model level** (`low` / `medium` / `high`) for any IDE. |
| `/lock` | Lock your Telegram session immediately. |

---

## Project Structure

```text
phone-agent-control/
├── src/
│   ├── bot.mjs               # CLI entrypoint, startup password prompt, live console commands & polling loop
│   ├── bot-controller.mjs    # Telegram state machine, album/text coalescing, Git & Jenkins workflows
│   ├── agy-runner.mjs        # Google Antigravity (`agy`) subprocess runner & Gemini model/level resolver
│   ├── setup.mjs             # Console-only setup, `add-ide`, `update-jenkins` & `test-jenkins` wizards
│   ├── config.mjs            # `0600` config/state persistence, hot-reload & in-memory session auth
│   ├── git-manager.mjs       # Repo snapshots, diff detection, commits, custom branches & `git revert`
│   ├── jenkins-client.mjs    # Crumb-aware Jenkins API client, nested job paths & console log tailing
│   ├── telegram-api.mjs      # Zero-dependency Telegram Bot API client & GFM-to-Telegram-HTML converter
│   ├── transcript-reader.mjs # Reader for Antigravity `~/.gemini/antigravity/brain` JSONL transcripts
│   ├── env-loader.mjs        # Minimal `.env` loader
│   └── service.mjs           # Process stop & single-instance management helpers
├── test/
│   └── bot.test.mjs          # Offline unit + E2E test suite (mock Telegram/Jenkins servers + temp Git repos)
├── .env.example              # Optional environment variable template
├── package.json
└── LICENSE                   # MIT License
```

---

## Running Automated Tests

```bash
npm test
```

Runs the complete offline unit and end-to-end test suite (`node --test`) against local mock Telegram and Jenkins HTTP servers and temporary bare/cloned Git repositories.

---

## Companion macOS Google Gemini Software

Check out **[Sticky-AI (`sticky-ai`)](https://github.com/madmicrowave/sticky-ai)** — an open-source native macOS floating **Google Gemini** window toggled from anywhere on macOS with **`Option + Space` (`⌥ + Space`)**.

---

## Open Source License & Credits

Released as free and open-source software for everyone under the **[MIT License](./LICENSE)**.

**Powered by [DOMONK Factory](https://domonk.com)** — [https://domonk.com](https://domonk.com)
