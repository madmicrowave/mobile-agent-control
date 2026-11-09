<div align="center">

<img src="./assets/banner.svg" alt="Phone Agent Control — Remote Control AI Coding Agents, Git &amp; Jenkins CI/CD from Telegram on macOS" width="100%" />

# Phone Agent Control — Control AI Coding Agents, Git & Jenkins CI/CD from Telegram on macOS

**Remotely orchestrate local Google Antigravity IDE (`agy`) workspaces (Google Gemini & Claude Opus), Git branches, and Staging → Production Jenkins deployments from your phone — with zero open ports.**

[![CI](https://github.com/madmicrowave/phone-agent-control/actions/workflows/ci.yml/badge.svg)](https://github.com/madmicrowave/phone-agent-control/actions/workflows/ci.yml)
[![Platform: macOS](https://img.shields.io/badge/Platform-macOS-000000?logo=apple&logoColor=white)](https://github.com/madmicrowave/phone-agent-control)
[![Node.js: 20+](https://img.shields.io/badge/Node.js-20%2B%20(Zero%20Deps)-339933?logo=node.js&logoColor=white)](https://nodejs.org)
[![AI: Google Gemini & Claude Opus](https://img.shields.io/badge/AI-Google%20Gemini%20%26%20Claude%20Opus-4285F4?logo=google&logoColor=white)](https://gemini.google.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-22c55e.svg)](./LICENSE)
[![Powered by DOMONK Factory](https://img.shields.io/badge/Powered%20by-DOMONK%20Factory-7c3aed)](https://domonk.com)

[**Quick Start**](#installation--setup) • [**Workflow**](#end-to-end-workflow) • [**Why Phone Agent Control?**](#why-phone-agent-control) • [**FAQ**](#frequently-asked-questions-faq) • [**DOMONK Factory**](https://domonk.com)

</div>

---

**Phone Agent Control** is a self-hosted, zero-dependency **macOS** application built for **Google Antigravity IDE (`agy`)** and **Google Gemini** (`Gemini 3.8 Flash`, `Gemini 4 Argon`) / **Claude Opus 5.5**, open-sourced under the MIT License by **[DOMONK Factory](https://domonk.com)**.

Send text instructions and up to **5 UI screenshots** from **Telegram** on your iPhone/Android to run AI coding turns on your Mac, inspect modified files across single-repo or multi-repo monorepos, commit & push to default or custom Git branches, deploy to **Staging Jenkins**, verify your live site, and promote straight to **Production Jenkins** (or revert a bad commit in one tap).

---

## Why Phone Agent Control?

| Requirement | Phone Agent Control | SSH / Mobile Terminal | Cloud Agent Sandboxes |
| :--- | :--- | :--- | :--- |
| **Network Setup** | ✅ Outbound Telegram HTTPS polling (zero open ports, no ngrok/VPN) | ❌ Requires VPN/Tailscale/SSH keys on phone | ⚠️ Must upload private repos & secrets to cloud |
| **Runs Against Your Real Local Mac IDE** | ✅ Shares live Antigravity Desktop conversations & local repos | ✅ Local shell | ❌ Isolated remote container |
| **Mobile UX for Code, Git & CI/CD** | ✅ One-tap buttons for Models, Commit, Branch, Staging → Prod & Revert | ❌ Painful tiny mobile keyboard | ⚠️ Web UI not built for mobile |
| **Security Posture** | ✅ Per-run RAM-only password + console-only Jenkins/IDE setup | ⚠️ Persistent SSH keys | ⚠️ Third-party cloud storage |

---

## Key Features

- **Multi-Model AI Orchestration on macOS**: Native execution of local **Google Antigravity (`agy`)** agent turns powered by **Google Gemini** (`Gemini 3.8 Flash`, `Gemini 4 Argon`, plus automatic discovery via `agy models`) and **Claude Opus 5.5**, with selectable effort levels (`low`, `medium`, `high`) per IDE workspace.
- **Per-Run Ephemeral Session Password**: Every `npm start` prompts in your Mac terminal for a fresh session password (masked with `*` and held strictly in RAM — never stored on disk). Your Telegram session stays unlocked until you stop/restart the app or send `/lock`.
- **Console-Only Infrastructure Security**: Registering/removing IDE workspaces, setting/updating Jenkins credentials, and testing Jenkins connectivity happen **exclusively in your local macOS terminal** (`npm run setup`, `npm run add-ide`, `npm run update-jenkins`, `npm run test-jenkins`, or live console commands inside `npm start`). They are never exposed or modifiable in Telegram.
- **Streamlined Telegram UI**:
  - Persistent 2-button bottom bar: **`🔀 Switch IDE`** and **`⚙️ Settings`**.
  - **Default Same-Chat Continuity (`✅ Same Chat`)**: Selecting an IDE automatically binds to its active Antigravity conversation — just start typing or sending screenshots right away, tap `🆕 New Chat` to start fresh, or tap `📜 Last Messages` inside Settings to read the latest `X` transcript messages.
- **Smart Album & Long-Message Coalescing**: Merges Telegram photo/file albums (`media_group_id`) and split `>4096`-character prompts into a **single** agent turn (up to **5 attached images/files** at once).
- **Rich Telegram HTML Rendering**: Converts GitHub-Flavored Markdown (GFM) agent responses — headings, bold/italic, inline code, syntax-tagged `<pre><code>` blocks, lists, blockquotes/alerts, and local `file://` symbol links — into clean, balanced Telegram HTML chunks.
- **Interactive Git & Multi-Environment Jenkins CI/CD (`single` & `multi` Staging → Prod)**:
  1. Lists modified/added/deleted files (`M` / `A` / `D`) across all Git repositories in the workspace.
  2. Prompts **Commit & push?** (`✅ Yes` / `🌿 Custom Branch` / `❌ No (Discard Changes)`).
  3. Reports exact commit SHA(s) and remote branch via message text.
  4. Triggers parameterized **Jenkins** (`single`) or **Staging Jenkins** (`multi`) builds (`VERSION=<branch>`), streaming status and error logs on failure.
  5. When Staging succeeds, asks **Is it okay?**:
     - **`single` env**: `✅ Yes (Confirm)` or `↩️ Revert (Bad Commit)`.
     - **`multi` env (`staging` + `production`)**: **`🚀 Yes, deploy on prod`** (auto-triggers mapped Production Jenkins job(s)), **`✅ Yes (skip prod deploy)`**, or **`↩️ Revert (Bad Commit)`**.
- **Zero Third-Party Dependencies**: Built with modern ES Modules using only the Node.js 20+ standard library.

---

## End-to-End Workflow

```text
Open Bot in Telegram (/start)
   │
   ▼
🔐 Enter Current Run Password (entered on `npm start` in Mac terminal; auto-deleted from chat)
   │
   ▼
🗂 Select IDE Workspace (displays workspace `label`; `✅ Same Chat` active by default)
   ├── Start typing or attach up to 5 screenshots ──► Continues active chat immediately
   └── Tap "🆕 New Chat"                          ──► Starts a fresh Antigravity conversation
   │
   ▼
🤖 Antigravity (`agy`) runs on your Mac with the IDE's configured AI Model & Level (`low` / `medium` / `high`)
   │
   ▼
📝 Formatted Agent Summary + Changed Files (`M` / `A` / `D` per repo)
   Ask: Commit & push?
   ├── ❌ No (Discard Changes) ──► Cleans turn's uncommitted edits -> Ready
   ├── ✅ Yes                  ──► Commits & pushes changed repos on current/configured branch
   └── 🌿 Custom Branch        ──► Prompts for branch name -> `git checkout -B <branch>` -> commits & pushes
   │
   ▼
🚀 Ask: Run Jenkins / Run Staging Jenkins? (`buildWithParameters?VERSION=<branch>`)
   ├── ❌ Failed  ──► Outputs Jenkins Console Error Log -> Retry / Revert / Keep
   └── ✅ Success ──► Ask: Is it okay?
                        ├── 🚀 Yes, deploy on prod (multi-env) ──► Runs Production Jenkins -> Ready
                        ├── ✅ Yes / Yes (skip prod deploy)    ──► Confirms & unlocks IDE -> Ready
                        └── ↩️ Revert (Bad Commit)             ──► `git revert` + push + optional rollback deploy
```

---

## System Requirements

- **macOS** (Apple Silicon or Intel)
- **Node.js `>= 20.0.0`** (`node -v`)
- **Git** (`git --version`)
- **Google Antigravity IDE & CLI (`agy`)** installed locally (`~/.local/bin/agy` or on `PATH`)
- A **Telegram Bot Token** (free from [`@BotFather`](https://t.me/BotFather))
- *(Optional)* **Jenkins** server with parameterized `VERSION` build jobs (single-environment or Staging + Production)

---

## Installation & Setup

### 1. Clone the Repository

```bash
git clone https://github.com/madmicrowave/phone-agent-control.git
cd phone-agent-control
```

*(Zero npm packages need to be downloaded — runs natively on Node.js 20+.)*

### 2. Run Interactive Console Setup

```bash
npm run setup
```

`npm run setup` writes `data/config.json` locally with `0600` owner-only permissions (gitignored):

1. **Telegram Bot Token** (from `@BotFather`)
2. **Allowed Telegram User IDs** (comma-separated numeric IDs, or `all`)
3. **Latest `X` Messages Count** (fixed history count shown on `📜 Last Messages` / `/history`)
4. **Jenkins Base URL**, **Username**, **API Token** + **Interactive Console Connection Test**
5. **Workspaces Auto-Discovery, AI Model & Environment Mapping**:
   - Discovers Git/IDE folders on disk (`+1`, `+2`, …) or accepts any pasted directory path (`~/code/my-project`).
   - Configures each IDE's `id`, display `label`, **AI model** (`Gemini 3.8 Flash`, `Gemini 4 Argon`, `Claude Opus 5.5`), and **level** (`low`, `medium`, `high`).
   - Configures **Deployment environments**: `single` or `multi` (requires both **Staging** and **Production** Jenkins job paths or full job URLs).

### 3. Start the Bot

```bash
npm start
```

Enter a fresh session password when prompted in your Mac terminal, then open your bot in Telegram and send that password once to unlock your session.

> **Tip — Keep Mac Awake While Away**: Run `caffeinate -dimsu npm start` so macOS does not sleep while your lid is closed on AC power.

### Console Management Commands

```bash
npm run setup           # Full interactive setup wizard
npm run add-ide         # Scan & register an available IDE workspace (or edit existing IDEs)
npm run update-jenkins  # Set/update Jenkins URL, username & API token, and test connection
npm run test-jenkins    # Test Jenkins connectivity & list sample jobs in terminal
npm stop                # Stop any running bot process cleanly
```

---

## Telegram Controls & Slash Commands

| Control / Command | Description |
| :--- | :--- |
| **🔀 Switch IDE** (`/ides`) | Switch between registered IDE workspaces; each preserves its active chat and pending step. |
| **⚙️ Settings** (`/settings`, `/model`) | Change the **AI model** (`Gemini 3.8 Flash`, `Gemini 4 Argon`, `Claude Opus 5.5`), **model level** (`low` / `medium` / `high`), or view **`📜 Last Messages`** for any IDE. |
| `/newchat` | Start a fresh conversation in the selected IDE workspace. |
| `/history` | Show the latest `X` user/agent messages from the Antigravity conversation transcript. |
| `/lock` | Lock your Telegram session immediately. |

---

## Frequently Asked Questions (FAQ)

<details>
<summary><b>Do I need ngrok, Cloudflare Tunnel, Tailscale, or router port forwarding?</b></summary>
<br />
No. Phone Agent Control uses outbound HTTPS long-polling (<code>getUpdates</code>) to <code>api.telegram.org</code>. Your Mac never opens an inbound listening port, and you can control your IDE from anywhere on 5G/LTE or Wi-Fi.
</details>

<details>
<summary><b>Can I continue the exact chat I started on my Mac inside Antigravity Desktop?</b></summary>
<br />
Yes! Selecting an IDE automatically discovers its most recent Antigravity conversation in <code>~/.gemini/antigravity/brain</code> and sets <b>Same Chat</b> as the active default — just type your follow-up message in Telegram.
</details>

<details>
<summary><b>How does Staging → Production Jenkins promotion work?</b></summary>
<br />
For workspaces configured with <code>multi</code> environments in <code>npm run setup</code>, Phone Agent Control builds your <b>Staging</b> Jenkins job(s) first, shows your live preview link, and presents three buttons: <b>🚀 Yes, deploy on prod</b> (automatically triggers the mapped Production Jenkins job(s) with the same <code>VERSION</code> branch), <b>✅ Yes (skip prod deploy)</b>, or <b>↩️ Revert (Bad Commit)</b>.
</details>

---

## Running Automated Tests

```bash
npm test
```

Runs the complete offline unit and end-to-end test suite (`node --test`) against local mock Telegram and Jenkins HTTP servers and temporary bare/cloned Git repositories.

---

## More Open-Source macOS AI Tools by DOMONK Factory

- **[Sticky-AI (`sticky-ai`)](https://github.com/madmicrowave/sticky-ai)** — Open-source native Swift macOS menu bar & always-on-top floating **Google Gemini** window toggled from anywhere on macOS with **`Option + Space` (`⌥ + Space`)**.

If **Phone Agent Control** levels up your mobile coding & deployment workflow, please consider giving it a **⭐️ Star on GitHub**!

---

## Open Source License & Credits

Released as free and open-source software under the **[MIT License](./LICENSE)**.

**Powered by [DOMONK Factory](https://domonk.com)** — [https://domonk.com](https://domonk.com)
