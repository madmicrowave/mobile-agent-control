<div align="center">

<img src="./assets/banner.svg" alt="MAC (Mobile Agent Control) — Native macOS Menu Bar App for Controlling AI Coding Agents, Git &amp; Jenkins CI/CD from Telegram" width="100%" />

# MAC (Mobile Agent Control) — Native macOS Menu Bar App for Controlling AI Workspaces, Git & Jenkins CI/CD from Telegram

**Remotely orchestrate local Google Antigravity (`agy`) Workspaces (Google Gemini & Claude), Git branches, and Staging → Production Jenkins deployments from Telegram — wrapped in a native macOS menu bar app (`MAC.app`) with zero open ports and zero CLI commands required.**

[![CI](https://github.com/madmicrowave/mobile-agent-control/actions/workflows/ci.yml/badge.svg)](https://github.com/madmicrowave/mobile-agent-control/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/madmicrowave/mobile-agent-control?label=Download%20MAC.app&logo=apple)](https://github.com/madmicrowave/mobile-agent-control/releases/latest)
[![Platform: macOS 14+](https://img.shields.io/badge/Platform-macOS%2014%2B-000000?logo=apple&logoColor=white)](https://github.com/madmicrowave/mobile-agent-control)
[![Swift + Node 20+](https://img.shields.io/badge/Swift%20%2B%20Node.js-20%2B%20(Zero%20Deps)-339933?logo=swift&logoColor=white)](https://nodejs.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-22c55e.svg)](./LICENSE)
[![Powered by DOMONK Factory](https://img.shields.io/badge/Powered%20by-DOMONK%20Factory-7c3aed)](https://domonk.com)

[**Download MAC.app**](https://github.com/madmicrowave/mobile-agent-control/releases/latest) • [**Menu Bar & Settings**](#native-macos-menu-bar-app-macapp) • [**Workflow**](#end-to-end-workflow) • [**FAQ**](#frequently-asked-questions-faq) • [**DOMONK Factory**](https://domonk.com)

</div>

---

**MAC (`Mobile Agent Control`)** is a self-hosted, zero-dependency **native macOS menu bar application (`MAC.app`)** built for **Google Antigravity (`agy`)** and **Google Gemini** (`Gemini 3.8 Flash`, `Gemini 4 Argon`) / **Claude Opus 5.5**, open-sourced under the MIT License by **[DOMONK Factory](https://domonk.com)**.

`MAC` lives right next to your macOS clock in the menu bar — start, restart, or stop the Telegram bot with a per-run session password dialog, manage all your Workspaces and Staging/Production Jenkins jobs visually in **Settings**, launch automatically at macOS login, and automatically prevent your MacBook from sleeping while running.

---

## Native macOS Menu Bar App (`MAC.app`)

When **MAC** starts, its icon appears in your macOS menu bar (clock line):

- **`Start...`** — Opens a native macOS password dialog to set a fresh, RAM-only session password for this run, starts Telegram long-polling, and activates **Mac Sleep Prevention** (`IOKit` power assertion + `caffeinate`).
- **`Restart...`** — Prompts for a new session password, cleanly restarts the bot, and requires Telegram sessions to re-authenticate with the new password.
- **`Stop`** — Stops the Telegram bot immediately and allows your Mac to sleep normally again.
- **`Settings...` (`⌘,`)** — Native SwiftUI window with 4 dedicated tabs:
  1. **Manage Workspaces**: Edit workspace labels, folder paths, extra `--add-dir` paths, live staging URLs, AI model & effort level (`low` / `medium` / `high`), `Single` vs `Multi (Staging → Production)` environment mode, Staging & Production Jenkins jobs, and per-repo Git mappings.
  2. **Add Workspace**: Create a new Workspace in seconds — browse for a folder, auto-scan Git repositories, paste Staging & Production Jenkins job lists, and pick its default AI model.
  3. **Manage Jenkins**: Configure Jenkins Base URL, username, API token, default folder prefix, build timeout, self-signed TLS toggle, and one-click **Test Jenkins Connection**.
  4. **Bot & Startup**: Configure your `@BotFather` Telegram Bot Token, allowed Telegram user IDs, latest messages count (`X`), `agy` binary path, **Start Automatically at Login** toggle, and live bot activity logs.
- **Auto-Start at macOS Login**: Automatically installs `~/Library/LaunchAgents/com.domonk.mac.plist` so `MAC` appears in your menu bar whenever your Mac boots.
- **Awake While Running**: While `MAC` is in the **Running** state, macOS idle system sleep is prevented so long AI coding turns and Staging → Prod Jenkins pipelines never drop offline.

---

## Why MAC (Mobile Agent Control)?

| Requirement | MAC (`MAC.app`) | SSH / Mobile Terminal | Cloud Agent Sandboxes |
| :--- | :--- | :--- | :--- |
| **Desktop Experience** | ✅ Native macOS menu bar app + Settings GUI + Awake mode | ❌ Terminal windows & manual `caffeinate` | ❌ Browser-only |
| **Network Setup** | ✅ Outbound Telegram HTTPS polling (zero open ports, no ngrok/VPN) | ❌ Requires VPN/Tailscale/SSH keys on phone | ⚠️ Must upload private repos & secrets to cloud |
| **Runs Against Your Real Local Mac Workspaces** | ✅ Shares live Antigravity conversations & local Git repos | ✅ Local shell | ❌ Isolated remote container |
| **Mobile UX for Code, Git & CI/CD** | ✅ One-tap Telegram buttons for Workspaces, Models, Git & Staging → Prod | ❌ Painful tiny mobile keyboard | ⚠️ Web UI not built for mobile |
| **Security Posture** | ✅ Per-run RAM-only password + local-only `MAC → Settings` | ⚠️ Persistent SSH keys | ⚠️ Third-party cloud storage |

---

## End-to-End Workflow

```text
Click MAC Icon in macOS Menu Bar -> "Start..." -> Enter Session Password
   │  (Mac Sleep Prevention automatically enabled while running)
   ▼
Open Bot in Telegram (/start) -> Reply with Current Session Password (auto-deleted)
   │
   ▼
🗂 Select a Workspace (`•` marks active Workspace; `•` marks `Same Chat` active by default)
   ├── Start typing or attach up to 5 screenshots ──► Continues active chat immediately
   └── Tap "🆕 New Chat"                          ──► Starts a fresh Antigravity conversation
   │
   ▼
🤖 Antigravity (`agy`) runs on your Mac with the Workspace's AI Model & Level (`low` / `medium` / `high`)
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
                        ├── ✅ Yes / Yes (skip prod deploy)    ──► Confirms & unlocks Workspace -> Ready
                        └── ↩️ Revert (Bad Commit)             ──► `git revert` + push + optional rollback deploy
```

---

## System Requirements

- **macOS 14.0 (Sonoma) or later** (Apple Silicon or Intel)
- **Node.js `>= 20.0.0`** (`brew install node` or `nodejs.org`)
- **Git** (`git --version`)
- **Google Antigravity CLI (`agy`)** installed locally (`~/.local/bin/agy` or on `PATH`)
- A **Telegram Bot Token** (free from [`@BotFather`](https://t.me/BotFather))
- *(Optional)* **Jenkins** server with parameterized `VERSION` build jobs (Single or Multi Staging → Production)

---

## Quick Start

### Option A: Download Prebuilt `MAC.app`

1. Download **`MAC-macOS.zip`** from [**GitHub Releases**](https://github.com/madmicrowave/mobile-agent-control/releases/latest), unzip, and move **`MAC.app`** to `/Applications` (or anywhere you prefer).
2. Double-click **`MAC.app`** — the **MAC** icon appears at your macOS clock line.
3. Click **`Settings...`** to paste your `@BotFather` Telegram Bot Token, add your Workspaces, and configure Jenkins.
4. Click **`Start...`** in the menu bar, enter a session password, and send `/start` to your bot in Telegram!

### Option B: Build & Launch from Source

```bash
git clone https://github.com/madmicrowave/mobile-agent-control.git
cd mobile-agent-control
npm start
```

`npm start` compiles the standalone native **`MAC.app`** bundle (using `swiftc`, zero external packages) and launches it straight into your macOS menu bar.

---

## Telegram Controls & Slash Commands

| Control / Command | Description |
| :--- | :--- |
| **🔀 Switch Workspace** (`/workspaces`) | Switch between registered Workspaces; each preserves its active chat and pending step. |
| **⚙️ Settings** (`/settings`, `/model`) | Change the **AI model** (`Gemini 3.8 Flash`, `Gemini 4 Argon`, `Claude Opus 5.5`), **model level** (`low` / `medium` / `high`), or view **`📜 Last Messages`** for any Workspace. |
| `/newchat` | Start a fresh conversation in the selected Workspace. |
| `/history` | Show the latest `X` user/agent messages from the Antigravity conversation transcript. |
| `/lock` | Lock your Telegram session immediately. |

---

## Frequently Asked Questions (FAQ)

<details>
<summary><b>Do I need ngrok, Cloudflare Tunnel, Tailscale, or router port forwarding?</b></summary>
<br />
No. MAC uses outbound HTTPS long-polling (<code>getUpdates</code>) to <code>api.telegram.org</code>. Your Mac never opens an inbound listening port, and you can control your Workspaces from anywhere on 5G/LTE or Wi-Fi.
</details>

<details>
<summary><b>Will my Mac go to sleep while MAC is running?</b></summary>
<br />
No! Whenever you click <b>Start...</b> in the MAC menu bar icon, MAC acquires a macOS <code>PreventUserIdleSystemSleep</code> power assertion (plus <code>caffeinate</code>) so your Mac stays awake for Telegram commands, AI runs, and Jenkins deployments. Clicking <b>Stop</b> or <b>Quit MAC</b> immediately restores normal sleep behavior.
</details>

<details>
<summary><b>How does Staging → Production Jenkins promotion work?</b></summary>
<br />
In <b>MAC → Settings → Manage Workspaces</b> (or <b>Add Workspace</b>), set Environment Mode to <b>Multi (Staging → Production)</b> and add both Staging and Production Jenkins jobs. After Staging builds succeed, Telegram presents three buttons: <b>🚀 Yes, deploy on prod</b> (triggers Production Jenkins with the same <code>VERSION</code> branch), <b>✅ Yes (skip prod deploy)</b>, or <b>↩️ Revert (Bad Commit)</b>.
</details>

---

## Running Automated Tests

```bash
npm test
```

Runs both the Node.js unit & end-to-end test suite (`test/bot.test.mjs`) and the native macOS Swift test suite (`Tests/MACAppTestMain.swift` — testing `MACConfigFileStore`, job & repo discovery, `SleepPreventer`, `LaunchAtLoginManager`, and `MACStatusBarController` Start/Restart/Stop lifecycle).

---

## More Open-Source macOS AI Tools by DOMONK Factory

- **[Sticky-AI (`sticky-ai`)](https://github.com/madmicrowave/sticky-ai)** — Open-source native Swift macOS menu bar & always-on-top floating **Google Gemini** window toggled from anywhere on macOS with **`Option + Space` (`⌥ + Space`)**.

If **MAC (`mobile-agent-control`)** levels up your mobile coding & deployment workflow, please consider giving it a **⭐️ Star on GitHub**!

---

## Open Source License & Credits

Released as free and open-source software under the **[MIT License](./LICENSE)**.

**Powered by [DOMONK Factory](https://domonk.com)** — [https://domonk.com](https://domonk.com)
