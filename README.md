<div align="center">

<img src="./assets/banner.svg" alt="Mobile Agent Control (mac.app / MAC) — Control Local macOS Workspaces, Git &amp; Jenkins CI/CD via Telegram" width="100%" />

# Mobile Agent Control (`mac.app` / `MAC`)

**Control all your local macOS coding Workspaces, Git branches, and Staging → Production Jenkins deployments straight from Telegram — wrapped in a lightweight native macOS menu bar app (`mac.app`) with 2-minute visual setup and zero open ports.**

[![CI](https://github.com/madmicrowave/mobile-agent-control/actions/workflows/ci.yml/badge.svg)](https://github.com/madmicrowave/mobile-agent-control/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/madmicrowave/mobile-agent-control?label=Download%20mac.app&logo=apple)](https://github.com/madmicrowave/mobile-agent-control/releases/latest)
[![Platform: macOS 14+](https://img.shields.io/badge/Platform-macOS%2014%2B-000000?logo=apple&logoColor=white)](https://github.com/madmicrowave/mobile-agent-control)
[![Swift + Node 20+](https://img.shields.io/badge/Swift%20%2B%20Node.js-20%2B%20(Zero%20Deps)-339933?logo=swift&logoColor=white)](https://nodejs.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-22c55e.svg)](./LICENSE)
[![Powered by DOMONK Factory](https://img.shields.io/badge/Powered%20by-DOMONK%20Factory-7c3aed)](https://domonk.com)

[**Download `mac.app`**](https://github.com/madmicrowave/mobile-agent-control/releases/latest) • [**Easy 2-Minute Setup**](#easy-2-minute-setup-no-cli-needed) • [**Menu Bar & App Tabs**](#menu-bar-controls--4-app-tabs) • [**Telegram Workflow**](#controlling-workspaces-via-telegram) • [**FAQ**](#frequently-asked-questions-faq)

</div>

---

## What is Mobile Agent Control?

**Mobile Agent Control (`mac.app`)** puts a bold **`MAC`** badge right next to your macOS menu bar clock (matching the sleek style of [Sticky-AI](https://github.com/madmicrowave/sticky-ai)'s `SAI` badge) and connects your local **Google Antigravity (`agy`)** coding Workspaces (**Google Gemini 3.8 Flash**, **Gemini 4 Argon**, **Claude Opus 5.5**, **Claude Sonnet 5.5**) directly to **Telegram** on your iPhone or Android.

Whether you're away from your desk, commuting, or testing a live build on mobile, you can:
1. **Switch between any of your local Mac Workspaces** in one tap (`🔀 Switch Workspace`).
2. **Continue your active Antigravity Desktop chat** (`Same Chat •`) or start a **`🆕 New Chat`** — sending text instructions and up to **5 UI screenshots** at once.
3. **Inspect modified files (`M` / `A` / `D`)** across single-repo projects or multi-repo monorepos, then **Commit & Push** to the current branch, create a **Custom Branch**, or **Discard Changes**.
4. **Build Staging Jenkins & Promote to Production**: Trigger parameterized Jenkins builds (`VERSION=<branch>`), inspect error logs if a build fails, verify your live preview link, and tap **`🚀 Yes, deploy on prod`**, **`✅ Yes (skip prod deploy)`**, or **`↩️ Revert (Bad Commit)`**.

No terminal windows, no `ngrok` or port forwarding, no uploading private source code to third-party cloud sandboxes, and **automatic Mac sleep prevention** whenever the bot is started.

---

## Easy 2-Minute Setup (No CLI Needed)

### 1. Get & Launch `mac.app`

- **Option A — Prebuilt App (Fastest)**: Download **`mac-macOS.zip`** from [**GitHub Releases**](https://github.com/madmicrowave/mobile-agent-control/releases/latest), unzip it, move **`mac.app`** into `/Applications`, and double-click **`mac.app`**.
- **Option B — Build from Source**:
  ```bash
  git clone https://github.com/madmicrowave/mobile-agent-control.git
  cd mobile-agent-control
  npm start
  ```
  `npm start` compiles **`mac.app`** natively with `swiftc` (zero external dependencies) and places the **`MAC`** icon next to your macOS clock.

### 2. Configure Telegram, Jenkins & Workspaces in `MAC → Open App`

<img src="./assets/settings-tabs-preview.svg" alt="mac.app Window — General, Workspaces, Tutorial &amp; Live Bot Activity" width="100%" />

1. **Open `General` (or `Tutorial`) Tab**:
   - Need a bot token? Click **Open `@BotFather`** inside **Tutorial**, send `/newbot`, paste the token into **General → Telegram**, and click **Verify Token**.
   - *(Optional)* Add your numeric Telegram User ID (`@userinfobot`), **Jenkins** server credentials (`Test Jenkins Connection`), and **AGY** CLI path / default AI model, then click **Save General Settings**.
2. **Open `Workspaces` Tab & Click `+`**:
   - Click **`+`** in the left sidebar to add a new Workspace record, enter a **Workspace Label** (e.g. `PAYMENT BOOK`, `CRYPTO FUSION`), click **Browse...** to select your folder, and click **Scan Git Repos**.
   - Select the Workspace's **AI Model & Effort Level** (`low` / `medium` / `high`), choose **Single** or **Multi (Staging → Production)** Jenkins jobs, and click **Create Workspace**.
3. **Click `MAC` Next to Your Clock → `Start...`**:
   - Enter a fresh **session password** for this run (held strictly in RAM, never saved on disk).
   - Open your bot in Telegram, send `/start`, and reply once with that password (auto-deleted from chat). You're live!

---

## Menu Bar Controls & 4 App Tabs

Clicking the **`MAC`** badge next to your macOS clock gives you instant control:

| Menu Bar Item | What It Does |
| :--- | :--- |
| **`Open App`** | Opens the 4-tab `mac.app` window (**General**, **Workspaces**, **Tutorial**, **Live Bot Activity**) and shows **MAC** in the bottom Dock while open. Clicking **`✕`** closes the window back to the menu bar with no Dock icon while keeping MAC running. |
| **`Start...`** | Prompts for a fresh RAM-only session password, starts Telegram long-polling, and **prevents your Mac from sleeping** (`IOKit` + `caffeinate`). |
| **`Restart...`** | Prompts for a new session password, restarts the bot, and requires Telegram sessions to re-authenticate. |
| **`Stop`** | Stops the Telegram bot immediately and allows your MacBook to sleep normally again. |
| **`Start Automatically at Login`** | Keeps `~/Library/LaunchAgents/com.domonk.mac.plist` enabled so `MAC` launches whenever macOS starts. |
| **`About`** | Opens the **DOMONK Factory** About window with a direct link to [https://domonk.com](https://domonk.com). |

---

## Controlling Workspaces via Telegram

```text
Click [MAC] Next to macOS Clock -> "Start..." -> Enter Session Password
   │  (MacBook sleep prevention automatically active while running)
   ▼
Open Bot in Telegram (/start) -> Send Session Password (auto-deleted from chat)
   │
   ▼
🗂 Select a Workspace (`•` marks active Workspace; `Same Chat •` active by default)
   ├── Type a prompt or send up to 5 screenshots ──► Continues active Desktop chat immediately
   └── Tap "🆕 New Chat"                         ──► Starts a fresh Antigravity conversation
   │
   ▼
🤖 Antigravity (`agy`) runs locally on your Mac with the Workspace's AI Model & Level
   │
   ▼
📝 Formatted Agent Summary + Changed Files (`M` / `A` / `D` across repos)
   Ask: Commit & push?
   ├── ❌ No (Discard Changes) ──► Cleans turn's uncommitted edits -> Ready
   ├── ✅ Yes                  ──► Commits & pushes changed repos on current/configured branch
   └── 🌿 Custom Branch        ──► Prompts for branch name -> `git checkout -B <branch>` -> commits & pushes
   │
   ▼
🚀 Ask: Run Jenkins / Run Staging Jenkins? (`buildWithParameters?VERSION=<branch>`)
   ├── ❌ Failed  ──► Streams Jenkins Console Error Log -> Retry / Revert / Keep
   └── ✅ Success ──► Ask: Is it okay?
                        ├── 🚀 Yes, deploy on prod (multi-env) ──► Runs Production Jenkins -> Ready
                        ├── ✅ Yes / Yes (skip prod deploy)    ──► Confirms & unlocks Workspace -> Ready
                        └── ↩️ Revert (Bad Commit)             ──► `git revert` + push + optional rollback deploy
```

### Telegram Buttons & Slash Commands

| Control / Command | Description |
| :--- | :--- |
| **`🔀 Switch Workspace`** (`/workspaces`) | Switch between configured Workspaces; each Workspace preserves its own active chat and pending Git/Jenkins state. |
| **`⚙️ Settings`** (`/settings`, `/model`) | Change the **AI Model**, **Effort Level** (`low` / `medium` / `high`), or read **`📜 Last Messages`** for any Workspace. |
| **`🆕 New Chat`** (`/newchat`) | Start a brand-new Antigravity conversation in the selected Workspace. |
| `/history` | Display the latest `X` user & agent messages from the active Workspace transcript. |
| `/lock` | Lock your Telegram session immediately until the session password is entered again. |

---

## Why Mobile Agent Control (`mac.app`)?

| Capability | Mobile Agent Control (`mac.app`) | SSH / Mobile Terminal | Cloud Agent Sandboxes |
| :--- | :--- | :--- | :--- |
| **Setup Experience** | ✅ 2-minute macOS Settings UI + built-in **Tutorial** tab | ❌ Manual SSH keys, `tmux`, `caffeinate` | ⚠️ Cloud repo OAuth & env cloning |
| **Network Security** | ✅ Outbound Telegram HTTPS polling (zero open ports) | ❌ Requires VPN / Tailscale / open port | ⚠️ Source code leaves your Mac |
| **Real Local Mac Workspaces** | ✅ Shares live Antigravity Desktop chats & local monorepos | ✅ Local shell | ❌ Isolated remote container |
| **Mobile Git & CI/CD UX** | ✅ One-tap buttons for Workspaces, Branches & Staging → Prod | ❌ Tiny mobile terminal keyboard | ⚠️ Desktop web UI on small screen |
| **Power Management** | ✅ Auto-starts at login & keeps Mac awake only while running | ❌ Mac sleeps mid-task | ✅ Cloud-hosted |

---

## System Requirements

- **macOS 14.0 (Sonoma) or later** (Apple Silicon & Intel)
- **Node.js `>= 20.0.0`** (`brew install node` or [nodejs.org](https://nodejs.org))
- **Git** (`git --version`)
- **Google Antigravity CLI (`agy`)** installed locally (`~/.local/bin/agy` or on `PATH`)
- A free **Telegram Bot Token** from [`@BotFather`](https://t.me/BotFather)
- *(Optional)* **Jenkins** server with parameterized `VERSION` build jobs

---

## Frequently Asked Questions (FAQ)

<details>
<summary><b>Do I need ngrok, Cloudflare Tunnel, Tailscale, or router port forwarding?</b></summary>
<br />
No. <code>mac.app</code> communicates exclusively via outbound HTTPS long-polling (<code>getUpdates</code>) to <code>api.telegram.org</code>. Your Mac never opens an inbound listening port, and you can control your Workspaces from anywhere on 5G/LTE or Wi-Fi.
</details>

<details>
<summary><b>Will my MacBook go to sleep while the bot is running?</b></summary>
<br />
No. Clicking <b>Start...</b> in the <b>MAC</b> menu bar icon acquires a macOS <code>PreventUserIdleSystemSleep</code> assertion (backed by <code>caffeinate</code>) so long AI turns and Jenkins builds stay online. Clicking <b>Stop</b> or <b>Quit MAC</b> immediately allows normal Mac sleep again.
</details>

<details>
<summary><b>Can someone add Workspaces or view Jenkins tokens from Telegram?</b></summary>
<br />
Never. Workspace paths, Telegram tokens, and Jenkins credentials live strictly on your Mac in <code>data/config.json</code> (with <code>0600</code> owner-only permissions) and can only be edited locally inside <b>MAC → Settings</b>.
</details>

---

## Development & Automated Tests

```bash
npm test            # Runs all Node.js unit/E2E tests + native macOS Swift app tests
npm run build:app   # Compiles standalone ./mac.app bundle
```

---

## More Open-Source macOS AI Tools by DOMONK Factory

- **[Sticky-AI (`sticky-ai`)](https://github.com/madmicrowave/sticky-ai)** — Native Swift macOS menu bar (`SAI`) & always-on-top floating **Google Gemini** assistant toggled anywhere on macOS with **`Option + Space` (`⌥ + Space`)**.

If **Mobile Agent Control (`mac.app`)** speeds up your mobile coding & deployment workflow, please consider giving the repository a **⭐️ Star on GitHub**!

---

## Open Source License & Credits

Released as free and open-source software under the **[MIT License](./LICENSE)**.

**Powered by [DOMONK Factory](https://domonk.com)** — [https://domonk.com](https://domonk.com)
