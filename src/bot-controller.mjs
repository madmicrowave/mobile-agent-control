import fsp from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import {
  snapshotWorkspaceRepos,
  detectRepoChangesSinceSnapshot,
  validateGitBranchName,
  buildAutoCommitMessage,
  pushRepoCommit,
  commitAndPushRepoChanges,
  collectAgentCommitsAndPush,
  discardUncommittedTurnChanges,
  revertAndPushTurnCommits
} from './git-manager.mjs';
import { JenkinsClient } from './jenkins-client.mjs';
import {
  DEFAULT_AGENT_MODEL_FAMILIES,
  GEMINI_MODEL_FAMILIES,
  VALID_MODEL_LEVELS,
  isMissingTrajectoryError,
  resolveEffectiveModelAndLevel,
  runAgyTurn
} from './agy-runner.mjs';
import { runUnifiedAgentTurn } from './agent-runner.mjs';
import {
  getLatestConversationMessages,
  discoverRecentWorkspaceConversations
} from './transcript-reader.mjs';
import { escapeHtml, markdownToTelegramHtml } from './telegram-api.mjs';

export const REPLY_BTN_SWITCH_WORKSPACE = '🔀 Workspace';
export const REPLY_BTN_SWITCH_IDE = REPLY_BTN_SWITCH_WORKSPACE;
const LEGACY_REPLY_BTN_SWITCH_WORKSPACE = '🔀 Switch Workspace';
const LEGACY_REPLY_BTN_SWITCH_IDE = '🔀 Switch IDE';
export const REPLY_BTN_LATEST_MSGS = '📜 Latest Messages';
export const REPLY_BTN_NEW_CHAT = '🆕 New Chat';
export const REPLY_BTN_SETTINGS = '⚙️ Settings';
const LEGACY_REPLY_BTN_SETTINGS = '➕ Register / Settings';

export const MAX_FILES_PER_TURN = 5;
export const BIG_MESSAGE_SPLIT_THRESHOLD = 3800;

export const MAIN_REPLY_KEYBOARD = {
  keyboard: [[{ text: REPLY_BTN_SWITCH_WORKSPACE }, { text: REPLY_BTN_SETTINGS }]],
  resize_keyboard: true,
  is_persistent: true
};

function phaseIcon(phase) {
  switch (phase) {
    case 'IDLE':
    case 'SELECT_CHAT':
      return '🟢';
    case 'RUNNING_AGENT':
    case 'RUNNING_JENKINS':
    case 'RUNNING_PROD_JENKINS':
    case 'RUNNING_REVERT_JENKINS':
      return '⏳';
    default:
      return '🟣';
  }
}

function truncateText(str, maxChars = 600) {
  const s = String(str || '').trim();
  if (s.length <= maxChars) return s;
  return `${s.slice(0, maxChars - 1)}…`;
}

export function shortJenkinsJobLabel(jobPath) {
  const leaf = String(jobPath || '').split('/').pop() || String(jobPath || '');
  const stripped = leaf.replace(/^[a-z0-9.-]+\.[a-z]{2,}-/i, '');
  return stripped.length > 26 ? stripped.slice(-26) : stripped;
}

export class BotController {
  constructor({
    configStore,
    telegram,
    agentRunner = runUnifiedAgentTurn,
    jenkinsFactory = (cfg) => new JenkinsClient(cfg),
    gitPush = true,
    nowProvider = () => new Date(),
    inputCoalesceMs = 1000,
    logger = null
  }) {
    this.configStore = configStore;
    this.telegram = telegram;
    this.agentRunner = agentRunner;
    this.jenkinsFactory = jenkinsFactory;
    this.gitPush = gitPush;
    this.nowProvider = nowProvider;
    this.inputCoalesceMs = inputCoalesceMs;
    this.logger = logger;

    /** @type {Map<string, { abortAgent?: () => void, abortJenkins?: AbortController }>} */
    this.runtime = new Map();

    /** @type {Map<string, number[]>} */
    this.passwordFailures = new Map();

    /** @type {Map<string, Array<{ conversationId: string, preview: string, messageCount: number }>>} */
    this.cachedRecentChatsByWs = new Map();

    /** @type {Map<string, object>} */
    this.pendingInputBatches = new Map();

    /** @type {Map<string, { atMs: number, mediaGroupId: string | null }>} */
    this.lastGateNoticeByWs = new Map();

    /** @type {Map<string, { messageId: number, userId: string | number }>} */
    this.lastWorkspaceMenuByChat = new Map();

    /** @type {Map<string, { messageId: number, userId: string | number }>} */
    this.lastSettingsMenuByChat = new Map();

    /** @type {Map<string, Promise<unknown>>} */
    this.menuDispatchLocks = new Map();

    /** @type {Set<Promise<unknown>>} */
    this.activePromises = new Set();
  }

  #trackAsync(promise) {
    const tracked = Promise.resolve(promise).finally(() => {
      this.activePromises.delete(tracked);
    });
    this.activePromises.add(tracked);
    return tracked;
  }

  async waitForBackgroundTasks() {
    while (this.activePromises.size > 0) {
      await Promise.allSettled([...this.activePromises]);
    }
  }

  async runWithMenuLock(chatId, task) {
    const key = String(chatId);
    const prev = this.menuDispatchLocks.get(key) || Promise.resolve();
    let release;
    const current = new Promise((resolve) => {
      release = resolve;
    });
    this.menuDispatchLocks.set(key, prev.then(() => current));
    try {
      await prev;
      return await task();
    } finally {
      release();
      if (this.menuDispatchLocks.get(key) === current) {
        this.menuDispatchLocks.delete(key);
      }
    }
  }

  log(category, msg) {
    if (this.logger?.log) {
      this.logger.log(`[${category}] ${msg}`);
    }
  }

  getWorkspace(workspaceId) {
    return this.configStore.config.workspaces.find((w) => w.id === workspaceId) || null;
  }

  getWorkspaceLabel(ws) {
    if (!ws) return 'Workspace';
    return String(ws.label || ws.id || 'Workspace').trim();
  }

  getConfiguredHistoryCount() {
    return Math.max(1, Math.min(50, Number(this.configStore.config.defaultHistoryCount) || 6));
  }

  resolveWorkspaceModel(ws) {
    const cfg = this.configStore.config;
    return resolveEffectiveModelAndLevel({
      model: ws?.model || cfg.defaultModel || 'gemini-3.8-flash',
      modelLevel: ws?.modelLevel || cfg.defaultModelLevel || 'high'
    });
  }

  /**
   * Returns all configured Jenkins job paths for a workspace (combining `ws.jenkinsJobs` and repo mappings).
   */
  getWorkspaceJenkinsJobs(ws) {
    if (!ws) return [];
    const seen = new Set();
    const list = [];
    for (const j of ws.jenkinsJobs || []) {
      if (j && !seen.has(j)) {
        seen.add(j);
        list.push(j);
      }
    }
    for (const r of ws.repos || []) {
      if (r.deployEnabled && r.jenkinsJob && !seen.has(r.jenkinsJob)) {
        seen.add(r.jenkinsJob);
        list.push(r.jenkinsJob);
      }
    }
    return list;
  }

  /**
   * Builds `{ jenkinsJob, branch }[]` for every job in `ws`, using the committed branch
   * for modified repos and `'master'` for unmodified sibling services.
   */
  buildAllWorkspaceTargets(ws, sourceCommits = []) {
    const allJobs = this.getWorkspaceJenkinsJobs(ws);
    return allJobs.map((jobName) => {
      const repoForJob = (ws?.repos || []).find((r) => r.jenkinsJob === jobName);
      const matchedCommit = (sourceCommits || []).find(
        (c) => c.jenkinsJob === jobName || (repoForJob && c.repoName === repoForJob.name)
      );
      return {
        jenkinsJob: jobName,
        branch: matchedCommit?.branch || repoForJob?.branch || 'master'
      };
    });
  }

  /**
   * Returns all configured Production Jenkins job paths for a multi-environment workspace.
   */
  getWorkspaceProdJenkinsJobs(ws) {
    if (!ws || ws.environmentMode !== 'multi') return [];
    const seen = new Set();
    const list = [];
    for (const j of ws.prodJenkinsJobs || []) {
      if (j && !seen.has(j)) {
        seen.add(j);
        list.push(j);
      }
    }
    for (const r of ws.repos || []) {
      if (r.deployEnabled && r.prodJenkinsJob && !seen.has(r.prodJenkinsJob)) {
        seen.add(r.prodJenkinsJob);
        list.push(r.prodJenkinsJob);
      }
    }
    return list;
  }

  hasWorkspaceProdJenkins(ws) {
    return this.getWorkspaceProdJenkinsJobs(ws).length > 0;
  }

  buildAllWorkspaceProdTargets(ws, sourceCommits = []) {
    const prodJobs = this.getWorkspaceProdJenkinsJobs(ws);
    return prodJobs.map((prodJob) => {
      const repoForJob = (ws?.repos || []).find((r) => r.prodJenkinsJob === prodJob);
      const matchedCommit = (sourceCommits || []).find(
        (c) => repoForJob && c.repoName === repoForJob.name
      );
      return {
        jenkinsJob: prodJob,
        branch: matchedCommit?.branch || repoForJob?.branch || 'master'
      };
    });
  }

  resolveProdJenkinsTargets(ws, st) {
    if (!this.hasWorkspaceProdJenkins(ws)) return [];
    const commits = st?.activeTurn?.commits || [];
    const stagingDeployed = st?.activeTurn?.deployedTargets || [];
    const allStagingJobs = this.getWorkspaceJenkinsJobs(ws);

    if (stagingDeployed.length > 0) {
      if (allStagingJobs.length > 1 && stagingDeployed.length >= allStagingJobs.length) {
        return this.dedupeJenkinsTargets(this.buildAllWorkspaceProdTargets(ws, commits));
      }

      const mappedFromStaging = [];
      for (const stgTarget of stagingDeployed) {
        const repoForStaging = (ws?.repos || []).find(
          (r) => r.jenkinsJob === stgTarget.jenkinsJob
        );
        if (repoForStaging?.prodJenkinsJob) {
          mappedFromStaging.push({
            jenkinsJob: repoForStaging.prodJenkinsJob,
            branch: stgTarget.branch || repoForStaging.branch || 'master'
          });
        }
      }

      if (mappedFromStaging.length > 0) {
        return this.dedupeJenkinsTargets(mappedFromStaging);
      }
    }

    const mappedFromCommits = [];
    for (const c of commits) {
      const liveRepo = (ws?.repos || []).find((r) => r.name === c.repoName);
      if (liveRepo?.deployEnabled && liveRepo.prodJenkinsJob) {
        mappedFromCommits.push({
          jenkinsJob: liveRepo.prodJenkinsJob,
          branch: c.branch || liveRepo.branch || 'master'
        });
      }
    }
    if (mappedFromCommits.length > 0) {
      return this.dedupeJenkinsTargets(mappedFromCommits);
    }

    return this.dedupeJenkinsTargets(this.buildAllWorkspaceProdTargets(ws, commits));
  }

  dedupeJenkinsTargets(targets = []) {
    const seen = new Set();
    const out = [];
    for (const t of targets) {
      if (!t?.jenkinsJob) continue;
      const key = `${t.jenkinsJob}::${t.branch || 'master'}`;
      if (!seen.has(key)) {
        seen.add(key);
        out.push({ jenkinsJob: t.jenkinsJob, branch: t.branch || 'master' });
      }
    }
    return out;
  }

  checkPasswordRateLimit(userId) {
    const key = String(userId);
    const nowMs = Date.now();
    const prev = (this.passwordFailures.get(key) || []).filter((t) => nowMs - t < 60_000);
    if (prev.length === 0) {
      this.passwordFailures.delete(key);
      return true;
    }
    this.passwordFailures.set(key, prev);
    return prev.length < 6;
  }

  recordPasswordFailure(userId) {
    const key = String(userId);
    const list = this.passwordFailures.get(key) || [];
    list.push(Date.now());
    this.passwordFailures.set(key, list);
  }

  /**
   * Processes a single Telegram Update (`message` or `callback_query`).
   */
  async handleUpdate(update) {
    if (!update) return;
    await this.configStore.reloadConfigIfChanged();
    if (update.callback_query) {
      await this.handleCallbackQuery(update.callback_query);
      return;
    }
    if (update.message) {
      await this.handleMessage(update.message);
    }
  }

  async promptForSessionPassword(chatId) {
    await this.telegram.sendMessage({
      chatId,
      text:
        `🔐 <b>Mobile Agent Control (MAC)</b>\n\n` +
        `Session requires authentication.\n\n` +
        `Reply with the current session password:`
    });
  }

  async handleMessage(msg) {
    const chatId = msg.chat?.id;
    const userId = msg.from?.id;
    if (!chatId || !userId) return;

    if (!this.configStore.isUserAllowed(userId)) {
      await this.telegram.sendMessage({
        chatId,
        text: `⛔ Unauthorized Telegram user ID (<code>${escapeHtml(String(userId))}</code>).`
      });
      return;
    }

    const text = String(msg.text || msg.caption || '').trim();
    const now = this.nowProvider();

    // ── Per-Run Startup Password Gate ────────────────────────────────────────
    if (!this.configStore.isUserUnlocked(userId)) {
      if (!text || text === '/start') {
        await this.promptForSessionPassword(chatId);
        return;
      }

      if (!this.checkPasswordRateLimit(userId)) {
        await this.telegram.sendMessage({
          chatId,
          text: '⏳ Too many failed password attempts. Wait 1 minute and try again.'
        });
        return;
      }

      // Best-effort delete user's password message from chat screen for privacy
      await this.telegram.deleteMessage(chatId, msg.message_id);

      if (!this.configStore.verifyPassword(text)) {
        this.recordPasswordFailure(userId);
        await this.telegram.sendMessage({
          chatId,
          text: '❌ Invalid password. Please enter the current session password:'
        });
        return;
      }

      this.passwordFailures.delete(String(userId));
      this.configStore.unlockUser(userId, now);
      await this.configStore.saveState();

      await this.telegram.sendMessage({
        chatId,
        text:
          `🔓 <b>Session unlocked!</b>\n\n` +
          `Active until the bot is stopped or restarted (or <code>/lock</code>).\n\n` +
          `Use the buttons below anytime to switch Workspaces or change AI models.`,
        replyMarkup: MAIN_REPLY_KEYBOARD
      });
      await this.sendIdeSelectorMenu(chatId, userId);
      return;
    }

    const sess = this.configStore.getUserSession(userId);

    // ── Global Commands & Reply Keyboard Shortcuts ───────────────────────────
    if (
      text === '/start' ||
      text === '/workspaces' ||
      text === '/ides' ||
      text === REPLY_BTN_SWITCH_WORKSPACE ||
      text === LEGACY_REPLY_BTN_SWITCH_WORKSPACE ||
      text === LEGACY_REPLY_BTN_SWITCH_IDE ||
      text === 'Workspace'
    ) {
      await this.sendIdeSelectorMenu(chatId, userId);
      return;
    }

    if (text === '/lock') {
      this.configStore.lockUser(userId);
      this.lastWorkspaceMenuByChat.delete(chatId);
      this.lastSettingsMenuByChat.delete(chatId);
      await this.configStore.saveState();
      await this.telegram.sendMessage({
        chatId,
        text: '🔒 Session locked. Enter the current run password whenever you want to unlock again.'
      });
      return;
    }

    if (
      text === '/settings' ||
      text === REPLY_BTN_SETTINGS ||
      text === LEGACY_REPLY_BTN_SETTINGS
    ) {
      await this.sendSettingsAndRegisterMenu(chatId, userId);
      return;
    }

    if (
      text === '/register' ||
      text.startsWith('/register ') ||
      text === '/setjenkins' ||
      text.startsWith('/setjenkins ') ||
      text === '/testjenkins'
    ) {
      if (text.startsWith('/setjenkins')) {
        await this.telegram.deleteMessage(chatId, msg.message_id);
      }
      await this.telegram.sendMessage({
        chatId,
        text:
          `🔒 Workspace registration and Jenkins configuration are local-only and cannot be viewed or changed in Telegram.\n\n` +
          `Open <b>MAC → Settings</b> in your macOS menu bar to manage Workspaces and Jenkins.`
      });
      return;
    }

    if (text === '/model' || text.startsWith('/setmodel ')) {
      sess.currentView = 'MODEL';
      sess.lastWorkspaceMenuMessageId = null;
      this.lastWorkspaceMenuByChat.delete(chatId);
      sess.lastSettingsMenuMessageId = null;
      this.lastSettingsMenuByChat.delete(chatId);
      if (!sess.selectedWorkspaceId || !this.getWorkspace(sess.selectedWorkspaceId)) {
        await this.sendSettingsAndRegisterMenu(chatId, userId);
        return;
      }
      if (text === '/model') {
        await this.sendWorkspaceRepoInfo(chatId, sess.selectedWorkspaceId);
        return;
      }
      await this.handleSetModelCommand(
        chatId,
        sess.selectedWorkspaceId,
        text.slice('/setmodel '.length).trim()
      );
      return;
    }

    if (text === REPLY_BTN_LATEST_MSGS || text === '/history' || text.startsWith('/history ')) {
      if (!sess.selectedWorkspaceId || !this.getWorkspace(sess.selectedWorkspaceId)) {
        await this.sendIdeSelectorMenu(chatId, userId, 'Select a Workspace first to view messages:');
        return;
      }
      sess.currentView = 'HISTORY';
      sess.lastWorkspaceMenuMessageId = null;
      this.lastWorkspaceMenuByChat.delete(chatId);
      sess.lastSettingsMenuMessageId = null;
      this.lastSettingsMenuByChat.delete(chatId);
      await this.sendLatestMessagesForWorkspace(chatId, sess.selectedWorkspaceId);
      return;
    }

    if (text === REPLY_BTN_NEW_CHAT || text === '/newchat') {
      if (!sess.selectedWorkspaceId || !this.getWorkspace(sess.selectedWorkspaceId)) {
        await this.sendIdeSelectorMenu(chatId, userId, 'Select a Workspace first:');
        return;
      }
      sess.currentView = 'NEW_CHAT';
      sess.lastWorkspaceMenuMessageId = null;
      this.lastWorkspaceMenuByChat.delete(chatId);
      sess.lastSettingsMenuMessageId = null;
      this.lastSettingsMenuByChat.delete(chatId);
      await this.activateNewChat(chatId, sess.selectedWorkspaceId);
      return;
    }

    // ── Ensure a Workspace is selected ───────────────────────────────────────
    const ws = sess.selectedWorkspaceId ? this.getWorkspace(sess.selectedWorkspaceId) : null;
    if (!ws) {
      await this.sendIdeSelectorMenu(chatId, userId, 'Select a Workspace first:');
      return;
    }
    sess.currentView = 'CHAT';
    sess.lastWorkspaceMenuMessageId = null;
    this.lastWorkspaceMenuByChat.delete(chatId);
    sess.lastSettingsMenuMessageId = null;
    this.lastSettingsMenuByChat.delete(chatId);

    const wsLabel = this.getWorkspaceLabel(ws);
    const st = this.configStore.getWorkspaceState(ws.id);

    // ── Custom Branch Text Input (during AWAITING_CUSTOM_BRANCH) ─────────────
    if (st.phase === 'AWAITING_CUSTOM_BRANCH') {
      if (!text) {
        await this.telegram.sendMessage({
          chatId,
          text: `🌿 Type a valid git branch name for <b>${escapeHtml(wsLabel)}</b>:`,
          replyMarkup: {
            inline_keyboard: [[{ text: '↩️ Back to Commit Options', callback_data: `cmt:back:${ws.id}` }]]
          }
        });
        return;
      }
      await this.handleCustomBranchSubmitted(chatId, ws, text);
      return;
    }

    // ── Add Fix Prompt Input (during AWAITING_FIX_PROMPT) ────────────────────
    if (st.phase === 'AWAITING_FIX_PROMPT') {
      const incomingAttachment = this.extractIncomingAttachment(msg);
      if (incomingAttachment) {
        try {
          const saved = await this.downloadAttachment(incomingAttachment, ws.id);
          if (saved && st.pendingPhotos.length < MAX_FILES_PER_TURN) {
            st.pendingPhotos.push(saved);
            await this.configStore.saveState();
          }
        } catch {}
      }
      if (!text && st.pendingPhotos.length === 0) {
        await this.telegram.sendMessage({
          chatId,
          text: `➕ Reply with what to fix or modify in <b>${escapeHtml(wsLabel)}</b>:`,
          replyMarkup: {
            inline_keyboard: [[{ text: '↩️ Back to Commit Options', callback_data: `cmt:back:${ws.id}` }]]
          }
        });
        return;
      }
      await this.handleFixPromptSubmitted(chatId, ws, text);
      return;
    }

    // ── Block new agent messages if workspace is awaiting a step decision ────
    if (st.phase !== 'IDLE' && st.phase !== 'SELECT_CHAT') {
      if (this.#shouldSuppressDuplicateGateNotice(ws.id, msg.media_group_id)) {
        return;
      }
      await this.sendCurrentWorkspaceGatePrompt(
        chatId,
        ws,
        `⚠️ <b>${escapeHtml(wsLabel)}</b> is currently in step <code>${escapeHtml(st.phase)}</code>.\n\nComplete the action below (or tap <b>${REPLY_BTN_SWITCH_WORKSPACE}</b> to work in another Workspace):`
      );
      return;
    }

    // Same Chat is the default option: if user didn't tap any button in SELECT_CHAT and starts typing/uploading, auto-continue Same Chat!
    if (st.phase === 'SELECT_CHAT') {
      if (!st.conversationId) {
        const recent = await discoverRecentWorkspaceConversations(
          this.configStore.config.antigravityBrainDir,
          ws.path,
          { maxResults: 1 }
        );
        if (recent.length > 0) {
          st.conversationId = recent[0].conversationId;
          st.continueLatest = false;
        } else {
          st.continueLatest = true;
        }
      }
      st.phase = 'IDLE';
      await this.configStore.saveState();
    }

    // ── Handle Single / Multi-File (Album) Uploads + Split Big Text Prompts ──
    const incomingAttachment = this.extractIncomingAttachment(msg);
    if (!incomingAttachment && !text) return;

    const existingBatch = this.pendingInputBatches.get(ws.id);
    const hasMediaGroup = Boolean(msg.media_group_id);
    const isBigSplitChunk = !incomingAttachment && text.length >= BIG_MESSAGE_SPLIT_THRESHOLD;
    const shouldCoalesce = Boolean(existingBatch || hasMediaGroup || isBigSplitChunk);

    if (shouldCoalesce) {
      await this.#enqueueInputBatchPart(chatId, ws, st, incomingAttachment, text);
      return;
    }

    if (incomingAttachment) {
      if (st.pendingPhotos.length >= MAX_FILES_PER_TURN) {
        if (text) {
          await this.startAgentTurn(chatId, ws, text, {
            extraNotice: `⚠️ Max ${MAX_FILES_PER_TURN} files allowed at once — kept the ${MAX_FILES_PER_TURN} already-attached files and skipped 1 extra file.`
          });
          return;
        }
        await this.telegram.sendMessage({
          chatId,
          text:
            `⚠️ <b>Maximum ${MAX_FILES_PER_TURN} files allowed at once</b> (${st.pendingPhotos.length}/${MAX_FILES_PER_TURN} already attached for <b>${escapeHtml(wsLabel)}</b>).\n\n` +
            `Type your message to run with these ${MAX_FILES_PER_TURN} files, or tap <b>🗑 Clear Photo(s)</b> first:`,
          replyMarkup: {
            inline_keyboard: [
              [
                { text: '▶️ Run with Photo Only', callback_data: `photo:run:${ws.id}` },
                { text: '🗑 Clear Photo(s)', callback_data: `photo:clr:${ws.id}` }
              ]
            ]
          }
        });
        return;
      }

      const destBase = path.join(
        this.configStore.uploadsDir,
        `${ws.id}-${Date.now()}-${crypto.randomBytes(3).toString('hex')}`
      );
      let savedPath;
      try {
        savedPath = await this.telegram.downloadFile(
          incomingAttachment.fileId,
          destBase,
          incomingAttachment.preferredExt
        );
      } catch (dlErr) {
        await this.telegram.sendMessage({
          chatId,
          text: `❌ Failed to download file from Telegram: ${escapeHtml(dlErr.message)}`
        });
        return;
      }

      st.pendingPhotos.push({
        path: savedPath,
        fileName: path.basename(savedPath)
      });
      await this.configStore.saveState();

      // Single file WITH caption -> execute immediately as one single message!
      if (text) {
        await this.startAgentTurn(chatId, ws, text);
        return;
      }

      // Single file WITHOUT caption -> hold up to MAX_FILES_PER_TURN (5) files for prompt
      const remaining = MAX_FILES_PER_TURN - st.pendingPhotos.length;
      await this.telegram.sendMessage({
        chatId,
        text:
          `🖼 <b>Photo attached (${st.pendingPhotos.length})</b> <i>(max ${MAX_FILES_PER_TURN})</i> for <b>${escapeHtml(wsLabel)}</b>.\n\n` +
          `Now type your message explaining what to do${remaining > 0 ? ` (or attach up to ${remaining} more)` : ''}:`,
        replyMarkup: {
          inline_keyboard: [
            [
              { text: '▶️ Run with Photo Only', callback_data: `photo:run:${ws.id}` },
              { text: '🗑 Clear Photo(s)', callback_data: `photo:clr:${ws.id}` }
            ]
          ]
        }
      });
      return;
    }

    await this.startAgentTurn(chatId, ws, text);
  }

  extractIncomingAttachment(msg) {
    if (Array.isArray(msg.photo) && msg.photo.length > 0) {
      // Highest resolution photo is last in Telegram's photo array
      return {
        fileId: msg.photo[msg.photo.length - 1].file_id,
        preferredExt: '.jpg',
        displayName: 'photo.jpg'
      };
    }
    if (msg.document && msg.document.file_id) {
      const rawName = String(msg.document.file_name || '').trim();
      const ext = rawName ? path.extname(rawName) : '';
      const isImg = typeof msg.document.mime_type === 'string' && msg.document.mime_type.startsWith('image/');
      return {
        fileId: msg.document.file_id,
        preferredExt: ext || (isImg ? '.png' : ''),
        displayName: rawName || 'file'
      };
    }
    return null;
  }

  #shouldSuppressDuplicateGateNotice(wsId, mediaGroupId = null) {
    const nowMs = Date.now();
    const prev = this.lastGateNoticeByWs.get(wsId);
    if (prev) {
      if (mediaGroupId && prev.mediaGroupId === String(mediaGroupId)) {
        prev.atMs = nowMs;
        return true;
      }
      if (nowMs - prev.atMs < 2500) {
        return true;
      }
    }
    this.lastGateNoticeByWs.set(wsId, {
      atMs: nowMs,
      mediaGroupId: mediaGroupId ? String(mediaGroupId) : null
    });
    return false;
  }

  #cancelInputBatch(wsId) {
    const batch = this.pendingInputBatches.get(wsId);
    if (!batch) return;
    if (batch.timer) {
      clearTimeout(batch.timer);
      batch.timer = null;
    }
    this.pendingInputBatches.delete(wsId);
    batch.resolveDone?.();
  }

  async #enqueueInputBatchPart(chatId, ws, st, incomingAttachment, text) {
    let batch = this.pendingInputBatches.get(ws.id);
    if (!batch) {
      let resolveDone;
      const donePromise = new Promise((resolve) => {
        resolveDone = resolve;
      });
      batch = {
        wsId: ws.id,
        chatId,
        files: [],
        texts: [],
        skippedCount: 0,
        downloadErrors: [],
        inFlightDownloads: 0,
        timer: null,
        resolveDone
      };
      this.pendingInputBatches.set(ws.id, batch);
      this.#trackAsync(donePromise);
    } else {
      batch.chatId = chatId;
    }

    if (batch.timer) {
      clearTimeout(batch.timer);
      batch.timer = null;
    }

    if (text) {
      batch.texts.push(text);
    }

    if (incomingAttachment) {
      const currentTotal = (st.pendingPhotos?.length || 0) + batch.files.length;
      if (currentTotal >= MAX_FILES_PER_TURN) {
        batch.skippedCount += 1;
      } else {
        batch.inFlightDownloads += 1;
        const destBase = path.join(
          this.configStore.uploadsDir,
          `${ws.id}-${Date.now()}-${crypto.randomBytes(3).toString('hex')}`
        );
        try {
          const savedPath = await this.telegram.downloadFile(
            incomingAttachment.fileId,
            destBase,
            incomingAttachment.preferredExt
          );
          if ((st.pendingPhotos?.length || 0) + batch.files.length < MAX_FILES_PER_TURN) {
            batch.files.push({
              path: savedPath,
              fileName: path.basename(savedPath)
            });
          } else {
            batch.skippedCount += 1;
            await fsp.rm(savedPath, { force: true }).catch(() => {});
          }
        } catch (dlErr) {
          batch.downloadErrors.push(dlErr.message || String(dlErr));
        } finally {
          batch.inFlightDownloads -= 1;
        }
      }
    }

    if (batch.inFlightDownloads === 0 && this.pendingInputBatches.get(ws.id) === batch) {
      batch.timer = setTimeout(() => {
        this.#flushInputBatch(ws.id);
      }, this.inputCoalesceMs);
    }
  }

  async #flushInputBatch(wsId) {
    const batch = this.pendingInputBatches.get(wsId);
    if (!batch || batch.inFlightDownloads > 0) return;

    if (batch.timer) {
      clearTimeout(batch.timer);
      batch.timer = null;
    }
    this.pendingInputBatches.delete(wsId);

    try {
      const ws = this.getWorkspace(wsId);
      if (!ws) return;
      const st = this.configStore.getWorkspaceState(ws.id);

      for (const file of batch.files) {
        if (st.pendingPhotos.length < MAX_FILES_PER_TURN) {
          st.pendingPhotos.push(file);
        } else {
          batch.skippedCount += 1;
        }
      }
      await this.configStore.saveState();

      const notices = [];
      if (batch.skippedCount > 0) {
        notices.push(
          `⚠️ Max ${MAX_FILES_PER_TURN} files allowed at once — kept first ${st.pendingPhotos.length} file(s) and skipped ${batch.skippedCount} extra file(s).`
        );
      }
      if (batch.downloadErrors.length > 0) {
        notices.push(
          `⚠️ Failed to download ${batch.downloadErrors.length} file(s): ${batch.downloadErrors[0]}`
        );
      }
      const extraNotice = notices.join('\n');
      const combinedPrompt = batch.texts.join('\n').trim();

      if (combinedPrompt) {
        await this.startAgentTurn(batch.chatId, ws, combinedPrompt, { extraNotice });
        return;
      }

      if (st.pendingPhotos.length > 0) {
        const remaining = MAX_FILES_PER_TURN - st.pendingPhotos.length;
        await this.telegram.sendMessage({
          chatId: batch.chatId,
          text:
            `🖼 <b>Photo attached (${st.pendingPhotos.length})</b> <i>(max ${MAX_FILES_PER_TURN})</i> for <b>${escapeHtml(this.getWorkspaceLabel(ws))}</b>.` +
            (extraNotice ? `\n\n${escapeHtml(extraNotice)}` : '') +
            `\n\nNow type your message explaining what to do${remaining > 0 ? ` (or attach up to ${remaining} more)` : ''}:`,
          replyMarkup: {
            inline_keyboard: [
              [
                { text: '▶️ Run with Photo Only', callback_data: `photo:run:${ws.id}` },
                { text: '🗑 Clear Photo(s)', callback_data: `photo:clr:${ws.id}` }
              ]
            ]
          }
        });
        return;
      }

      if (extraNotice) {
        await this.telegram.sendMessage({
          chatId: batch.chatId,
          text: escapeHtml(extraNotice)
        });
      }
    } finally {
      batch.resolveDone?.();
    }
  }

  // ── Callback Query Dispatcher ──────────────────────────────────────────────
  async handleCallbackQuery(cb) {
    const cbId = cb.id;
    const data = String(cb.data || '');
    const chatId = cb.message?.chat?.id;
    const messageId = cb.message?.message_id;
    const userId = cb.from?.id;

    if (!chatId || !userId) {
      await this.telegram.answerCallbackQuery(cbId);
      return;
    }

    if (!this.configStore.isUserAllowed(userId)) {
      await this.telegram.answerCallbackQuery(cbId, 'Unauthorized user', true);
      return;
    }

    if (!this.configStore.isUserUnlocked(userId)) {
      await this.telegram.answerCallbackQuery(cbId, 'Session password required', true);
      await this.promptForSessionPassword(chatId);
      return;
    }

    await this.telegram.answerCallbackQuery(cbId);
    const sess = this.configStore.getUserSession(userId);
    if (data !== 'ide:menu') {
      sess.currentView = 'WORKSPACE_ACTION';
      sess.lastWorkspaceMenuMessageId = null;
      this.lastWorkspaceMenuByChat.delete(chatId);
    }

    try {
      if (data === 'ide:menu') {
        await this.sendIdeSelectorMenu(chatId, userId);
        return;
      }

      if (data.startsWith('ide:sel:')) {
        const wsId = data.slice('ide:sel:'.length);
        await this.handleSelectIde(chatId, userId, wsId);
        return;
      }

      if (
        data === 'ide:reg_menu' ||
        data.startsWith('ide:cand:') ||
        data === 'ide:reg_manual' ||
        data.startsWith('ide:del:') ||
        data === 'cfg:test_jnk' ||
        data === 'cfg:set_jnk'
      ) {
        await this.telegram.clearInlineButtons(chatId, messageId);
        await this.telegram.sendMessage({
          chatId,
          text:
            `🔒 Workspace registration and Jenkins configuration are local-only and cannot be viewed or changed in Telegram.\n\n` +
            `Open <b>MAC → Settings</b> in your macOS menu bar to manage Workspaces and Jenkins.`
        });
        return;
      }

      if (data.startsWith('ide:cfg:')) {
        const wsId = data.slice('ide:cfg:'.length);
        await this.sendWorkspaceRepoInfo(chatId, wsId);
        return;
      }

      if (data.startsWith('mdl:f:')) {
        const [, , wsId, shortCode] = data.split(':');
        await this.handleUpdateWorkspaceModelFamily(chatId, wsId, shortCode, messageId);
        return;
      }

      if (data.startsWith('mdl:l:')) {
        const [, , wsId, level] = data.split(':');
        await this.handleUpdateWorkspaceModelLevel(chatId, wsId, level, messageId);
        return;
      }

      if (data.startsWith('mdl:custom:')) {
        const wsId = data.slice('mdl:custom:'.length);
        await this.sendWorkspaceRepoInfo(chatId, wsId, messageId);
        return;
      }

      if (data.startsWith('chat:same:')) {
        const parts = data.split(':');
        const wsId = parts[2];
        await this.activateSameChat(chatId, userId, wsId);
        if (messageId && cb.message?.text?.includes('Workspace Selected')) {
          const ws = this.getWorkspace(wsId);
          if (ws) {
            await this.telegram.updateInlineKeyboard(
              chatId,
              messageId,
              this.buildIdeSelectedKeyboard(
                ws,
                this.cachedRecentChatsByWs.get(ws.id) || [],
                this.configStore.getWorkspaceState(ws.id)
              )
            );
          }
        }
        return;
      }

      if (data.startsWith('chat:pick:')) {
        const parts = data.split(':');
        const wsId = parts[2];
        const idx = Number(parts[3]);
        const list = this.cachedRecentChatsByWs.get(wsId) || [];
        const chosen = list[idx];
        if (chosen) {
          const st = this.configStore.getWorkspaceState(wsId);
          st.conversationId = chosen.conversationId;
          st.continueLatest = false;
          await this.configStore.saveState();
        }
        await this.activateSameChat(chatId, userId, wsId);
        if (messageId && cb.message?.text?.includes('Workspace Selected')) {
          const ws = this.getWorkspace(wsId);
          if (ws) {
            await this.telegram.updateInlineKeyboard(
              chatId,
              messageId,
              this.buildIdeSelectedKeyboard(ws, list, this.configStore.getWorkspaceState(ws.id))
            );
          }
        }
        return;
      }

      if (data.startsWith('chat:new:')) {
        const wsId = data.slice('chat:new:'.length);
        await this.activateNewChat(chatId, wsId);
        if (messageId && cb.message?.text?.includes('Workspace Selected')) {
          const ws = this.getWorkspace(wsId);
          if (ws) {
            await this.telegram.updateInlineKeyboard(
              chatId,
              messageId,
              this.buildIdeSelectedKeyboard(
                ws,
                this.cachedRecentChatsByWs.get(ws.id) || [],
                this.configStore.getWorkspaceState(ws.id)
              )
            );
          }
        }
        return;
      }

      if (data.startsWith('chat:hist:')) {
        const wsId = data.slice('chat:hist:'.length);
        await this.sendLatestMessagesForWorkspace(chatId, wsId);
        return;
      }

      if (data.startsWith('photo:run:')) {
        const wsId = data.slice('photo:run:'.length);
        const ws = this.getWorkspace(wsId);
        if (ws) {
          await this.#flushInputBatch(wsId);
          await this.telegram.clearInlineButtons(chatId, messageId);
          if (this.configStore.getWorkspaceState(wsId).phase === 'IDLE') {
            await this.startAgentTurn(chatId, ws, '');
          }
        }
        return;
      }

      if (data.startsWith('photo:clr:')) {
        const wsId = data.slice('photo:clr:'.length);
        this.#cancelInputBatch(wsId);
        const st = this.configStore.getWorkspaceState(wsId);
        st.pendingPhotos = [];
        await this.configStore.saveState();
        await this.telegram.clearInlineButtons(chatId, messageId);
        await this.telegram.sendMessage({
          chatId,
          text: '🗑 Cleared attached file(s)/photo(s).'
        });
        return;
      }

      if (data.startsWith('agent:stop:')) {
        const wsId = data.slice('agent:stop:'.length);
        const rt = this.runtime.get(wsId);
        if (rt?.abortAgent) {
          rt.abortAgent();
          const stopWs = this.getWorkspace(wsId);
          const stopLabel = stopWs ? this.getWorkspaceLabel(stopWs) : wsId;
          await this.telegram.sendMessage({
            chatId,
            text: `🛑 Stopping Antigravity agent in <b>${escapeHtml(stopLabel)}</b>...`
          });
        }
        return;
      }

      if (data.startsWith('cmt:yes:')) {
        const wsId = data.slice('cmt:yes:'.length);
        await this.telegram.clearInlineButtons(chatId, messageId);
        await this.handleCommitYes(chatId, wsId, '');
        return;
      }

      if (data.startsWith('cmt:no:')) {
        const wsId = data.slice('cmt:no:'.length);
        await this.telegram.clearInlineButtons(chatId, messageId);
        await this.handleCommitNo(chatId, wsId);
        return;
      }

      if (data.startsWith('cmt:br:')) {
        const wsId = data.slice('cmt:br:'.length);
        await this.telegram.clearInlineButtons(chatId, messageId);
        await this.promptForCustomBranch(chatId, wsId);
        return;
      }

      if (data.startsWith('cmt:fix:')) {
        const wsId = data.slice('cmt:fix:'.length);
        await this.telegram.clearInlineButtons(chatId, messageId);
        await this.promptForAddFix(chatId, wsId);
        return;
      }

      if (data.startsWith('cmt:back:')) {
        const wsId = data.slice('cmt:back:'.length);
        await this.telegram.clearInlineButtons(chatId, messageId);
        const ws = this.getWorkspace(wsId);
        if (ws) {
          const st = this.configStore.getWorkspaceState(ws.id);
          st.phase = 'AWAITING_COMMIT_CHOICE';
          await this.configStore.saveState();
          await this.sendCurrentWorkspaceGatePrompt(chatId, ws);
        }
        return;
      }

      if (data.startsWith('cmt:repush:')) {
        const wsId = data.slice('cmt:repush:'.length);
        await this.telegram.clearInlineButtons(chatId, messageId);
        await this.handleRetryGitPush(chatId, wsId);
        return;
      }

      if (data.startsWith('jnk:yes:')) {
        const wsId = data.slice('jnk:yes:'.length);
        await this.telegram.clearInlineButtons(chatId, messageId);
        await this.handleRunJenkinsChoice(chatId, wsId, true, { isAfterRevert: false, mode: 'matched' });
        return;
      }

      if (data.startsWith('jnk:all:')) {
        const wsId = data.slice('jnk:all:'.length);
        await this.telegram.clearInlineButtons(chatId, messageId);
        await this.handleRunJenkinsChoice(chatId, wsId, true, { isAfterRevert: false, mode: 'all' });
        return;
      }

      if (data.startsWith('jnk:one:')) {
        const parts = data.split(':');
        const wsId = parts[2];
        const jobIndex = Number(parts[3]);
        await this.telegram.clearInlineButtons(chatId, messageId);
        await this.handleRunJenkinsChoice(chatId, wsId, true, {
          isAfterRevert: false,
          mode: 'single',
          jobIndex
        });
        return;
      }

      if (data.startsWith('jnk:no:')) {
        const wsId = data.slice('jnk:no:'.length);
        await this.telegram.clearInlineButtons(chatId, messageId);
        await this.handleRunJenkinsChoice(chatId, wsId, false, { isAfterRevert: false });
        return;
      }

      if (data.startsWith('ok:prod:')) {
        const wsId = data.slice('ok:prod:'.length);
        await this.telegram.clearInlineButtons(chatId, messageId);
        await this.handleOkDeployProd(chatId, wsId);
        return;
      }

      if (data.startsWith('ok:yes:')) {
        const wsId = data.slice('ok:yes:'.length);
        await this.telegram.clearInlineButtons(chatId, messageId);
        await this.handleOkConfirm(chatId, wsId);
        return;
      }

      if (data.startsWith('ok:rev:')) {
        const wsId = data.slice('ok:rev:'.length);
        await this.telegram.clearInlineButtons(chatId, messageId);
        await this.handleRevertBadCommit(chatId, wsId);
        return;
      }

      if (data.startsWith('fix:err:')) {
        const wsId = data.slice('fix:err:'.length);
        await this.telegram.clearInlineButtons(chatId, messageId);
        await this.handleFixJenkinsError(chatId, wsId);
        return;
      }

      if (data.startsWith('rjnk:yes:')) {
        const wsId = data.slice('rjnk:yes:'.length);
        await this.telegram.clearInlineButtons(chatId, messageId);
        await this.handleRunJenkinsChoice(chatId, wsId, true, { isAfterRevert: true, mode: 'matched' });
        return;
      }

      if (data.startsWith('rjnk:all:')) {
        const wsId = data.slice('rjnk:all:'.length);
        await this.telegram.clearInlineButtons(chatId, messageId);
        await this.handleRunJenkinsChoice(chatId, wsId, true, { isAfterRevert: true, mode: 'all' });
        return;
      }

      if (data.startsWith('rjnk:one:')) {
        const parts = data.split(':');
        const wsId = parts[2];
        const jobIndex = Number(parts[3]);
        await this.telegram.clearInlineButtons(chatId, messageId);
        await this.handleRunJenkinsChoice(chatId, wsId, true, {
          isAfterRevert: true,
          mode: 'single',
          jobIndex
        });
        return;
      }

      if (data.startsWith('rjnk:no:')) {
        const wsId = data.slice('rjnk:no:'.length);
        await this.telegram.clearInlineButtons(chatId, messageId);
        await this.handleRunJenkinsChoice(chatId, wsId, false, { isAfterRevert: true });
        return;
      }

      if (data === 'cfg:menu') {
        await this.sendSettingsAndRegisterMenu(chatId, userId);
        return;
      }
    } catch (err) {
      await this.telegram.sendMessage({
        chatId,
        text: `❌ Error: ${escapeHtml(err.message || String(err))}`
      });
    }
  }

  // ── Menus: Select / Switch Workspaces & Per-Workspace AI Model Settings ────
  async sendIdeSelectorMenu(chatId, userId, heading = '🗂 <b>Select a Workspace:</b>') {
    return this.runWithMenuLock(chatId, async () => {
      const sess = this.configStore.getUserSession(userId);

      // Clean up any existing Settings menu when switching to Workspaces
      const prevSettingsMessageId =
        sess.lastSettingsMenuMessageId || this.lastSettingsMenuByChat.get(chatId)?.messageId;
      if (prevSettingsMessageId) {
        const delSettingsChatId = sess.lastSettingsMenuChatId || chatId;
        sess.lastSettingsMenuMessageId = null;
        sess.lastSettingsMenuChatId = null;
        this.lastSettingsMenuByChat.delete(chatId);
        try {
          await this.telegram.deleteMessage(delSettingsChatId, prevSettingsMessageId);
        } catch {
          // Ignore if already deleted or expired
        }
      }

      const prevMenuMessageId =
        sess.lastWorkspaceMenuMessageId || this.lastWorkspaceMenuByChat.get(chatId)?.messageId;
      const isAlreadyInWorkspaces = sess.currentView === 'WORKSPACES' && Boolean(prevMenuMessageId);

      if (isAlreadyInWorkspaces) {
        const delChatId = sess.lastWorkspaceMenuChatId || chatId;
        sess.lastWorkspaceMenuMessageId = null;
        sess.lastWorkspaceMenuChatId = null;
        this.lastWorkspaceMenuByChat.delete(chatId);
        try {
          await this.telegram.deleteMessage(delChatId, prevMenuMessageId);
        } catch {
          // Ignore if already deleted or expired
        }
      }

      const rows = [];
      const workspaces = this.configStore.config.workspaces || [];

      for (let i = 0; i < workspaces.length; i += 2) {
        const row = [];
        for (const ws of workspaces.slice(i, i + 2)) {
          const st = this.configStore.getWorkspaceState(ws.id);
          const activeMark = sess.selectedWorkspaceId === ws.id ? ' •' : '';
          const wsLabel = this.getWorkspaceLabel(ws);
          row.push({
            text: `${phaseIcon(st.phase)} ${wsLabel}${activeMark}`,
            callback_data: `ide:sel:${ws.id}`
          });
        }
        rows.push(row);
      }

      const settingsBtn = { text: '⚙️ Settings', callback_data: 'cfg:menu' };
      if (rows.length > 0 && rows[rows.length - 1].length === 1) {
        rows[rows.length - 1].push(settingsBtn);
      } else {
        rows.push([settingsBtn]);
      }

      const sent = await this.telegram.sendMessage({
        chatId,
        text:
          workspaces.length > 0
            ? `${heading}\n\n🟢 <i>Ready</i>\n⏳ <i>Running</i>\n🟣 <i>Waiting for your Yes/No</i>`
            : `No Workspaces configured yet.\n\nOpen <b>MAC → Settings</b> in your macOS menu bar to add a Workspace.`,
        replyMarkup: { inline_keyboard: rows }
      });

      if (sent?.message_id) {
        sess.currentView = 'WORKSPACES';
        sess.lastWorkspaceMenuMessageId = sent.message_id;
        sess.lastWorkspaceMenuChatId = chatId;
        this.lastWorkspaceMenuByChat.set(chatId, { messageId: sent.message_id, userId });
        await this.configStore.saveState();
      }
    });
  }

  async sendSettingsAndRegisterMenu(chatId, userId) {
    return this.runWithMenuLock(chatId, async () => {
      const sess = this.configStore.getUserSession(userId);

      // Clean up any existing Workspace menu when switching to Settings
      const prevWorkspaceMessageId =
        sess.lastWorkspaceMenuMessageId || this.lastWorkspaceMenuByChat.get(chatId)?.messageId;
      if (prevWorkspaceMessageId) {
        const delWorkspaceChatId = sess.lastWorkspaceMenuChatId || chatId;
        sess.lastWorkspaceMenuMessageId = null;
        sess.lastWorkspaceMenuChatId = null;
        this.lastWorkspaceMenuByChat.delete(chatId);
        try {
          await this.telegram.deleteMessage(delWorkspaceChatId, prevWorkspaceMessageId);
        } catch {
          // Ignore if already deleted or expired
        }
      }

      // If already in SETTINGS or previous settings menu exists, delete it so we reload without duplicates
      const prevSettingsMessageId =
        sess.lastSettingsMenuMessageId || this.lastSettingsMenuByChat.get(chatId)?.messageId;
      const isAlreadyInSettings = sess.currentView === 'SETTINGS' && Boolean(prevSettingsMessageId);

      if (isAlreadyInSettings || prevSettingsMessageId) {
        const delSettingsChatId = sess.lastSettingsMenuChatId || chatId;
        sess.lastSettingsMenuMessageId = null;
        sess.lastSettingsMenuChatId = null;
        this.lastSettingsMenuByChat.delete(chatId);
        try {
          await this.telegram.deleteMessage(delSettingsChatId, prevSettingsMessageId);
        } catch {
          // Ignore if already deleted or expired
        }
      }

      const ws = sess.selectedWorkspaceId ? this.getWorkspace(sess.selectedWorkspaceId) : null;
      const allWorkspaces = this.configStore.config.workspaces || [];

      const rows = [];

      // Dedicated AI Model configuration button for EACH configured Workspace
      for (const item of allWorkspaces) {
        const mInfo = this.resolveWorkspaceModel(item);
        const activeBadge = ws && ws.id === item.id ? ' •' : '';
        const itemLabel = this.getWorkspaceLabel(item);
        rows.push([
          {
            text: `🧠 ${itemLabel}${activeBadge}: ${mInfo.displayLabel}`,
            callback_data: `ide:cfg:${item.id}`
          }
        ]);
      }

      const ideModelsSummary =
        allWorkspaces.length > 0
          ? allWorkspaces
              .map((item) => {
                const mInfo = this.resolveWorkspaceModel(item);
                const activeTag = ws && ws.id === item.id ? ' <i>(active)</i>' : '';
                const itemLabel = this.getWorkspaceLabel(item);
                return `  • <code>${escapeHtml(itemLabel)}</code> → <code>${escapeHtml(mInfo.displayLabel)}</code>${activeTag}`;
              })
              .join('\n')
          : '  <i>(No Workspaces configured — open <b>MAC → Settings</b> in your macOS menu bar)</i>';

      const sent = await this.telegram.sendMessage({
        chatId,
        text:
          `⚙️ <b>AI Model Settings</b>\n\n` +
          `Select a Workspace below to change its AI model:\n\n${ideModelsSummary}`,
        replyMarkup: { inline_keyboard: rows }
      });

      if (sent?.message_id) {
        sess.currentView = 'SETTINGS';
        sess.lastSettingsMenuMessageId = sent.message_id;
        sess.lastSettingsMenuChatId = chatId;
        this.lastSettingsMenuByChat.set(chatId, { messageId: sent.message_id, userId });
        await this.configStore.saveState();
      }
    });
  }

  async sendWorkspaceRepoInfo(chatId, wsId, editMessageId = null) {
    const ws = this.getWorkspace(wsId);
    if (!ws) return;

    const wsLabel = this.getWorkspaceLabel(ws);
    const modelInfo = this.resolveWorkspaceModel(ws);

    const familyButtons = DEFAULT_AGENT_MODEL_FAMILIES.map((fam) => {
      const isSelected = modelInfo.family === fam.family;
      return {
        text: `${isSelected ? '✅ ' : '🧠 '}${fam.label}`,
        callback_data: `mdl:f:${ws.id}:${fam.shortCode}`
      };
    });

    const familyRows = [];
    for (let i = 0; i < familyButtons.length; i += 2) {
      familyRows.push(familyButtons.slice(i, i + 2));
    }

    const levelButtons = VALID_MODEL_LEVELS.map((lvl) => {
      const isSelected = modelInfo.effort === lvl;
      return {
        text: `${isSelected ? '✅ ' : ''}${lvl}`,
        callback_data: `mdl:l:${ws.id}:${lvl}`
      };
    });

    const engineLabel =
      ws.engine === 'aider'
        ? 'Aider CLI'
        : ws.engine === 'direct-api'
          ? 'Direct API'
          : 'AGY CLI';

    const text =
      `🧠 <b>AI Model & Engine — ${escapeHtml(wsLabel)}</b>\n\n` +
      `• <b>AI Engine:</b> <code>${escapeHtml(engineLabel)}</code>\n` +
      `• <b>AI Model:</b> <code>${escapeHtml(modelInfo.modelId || 'gemini-3.8-flash-high')}</code>\n` +
      `• <b>Model Level:</b> <code>${escapeHtml(modelInfo.effort || 'high')}</code>`;

    const replyMarkup = {
      inline_keyboard: [
        ...familyRows,
        levelButtons,
        [
          { text: '📜 Last Messages', callback_data: `chat:hist:${ws.id}` },
          { text: `💬 Open "${wsLabel}"`, callback_data: `ide:sel:${ws.id}` }
        ],
        [{ text: '< BACK', callback_data: 'cfg:menu' }]
      ]
    };

    if (editMessageId) {
      await this.telegram
        .editMessageText({
          chatId,
          messageId: editMessageId,
          text,
          replyMarkup
        })
        .catch(async () => {
          await this.telegram.sendMessage({ chatId, text, replyMarkup });
        });
      return;
    }

    await this.telegram.sendMessage({
      chatId,
      text,
      replyMarkup
    });
  }

  async handleUpdateWorkspaceModelFamily(chatId, wsId, shortCode, editMessageId = null) {
    const ws = this.getWorkspace(wsId);
    if (!ws) return;
    const fam =
      GEMINI_MODEL_FAMILIES.find((f) => f.shortCode === shortCode) ||
      DEFAULT_AGENT_MODEL_FAMILIES.find((f) => f.shortCode === shortCode);
    if (!fam) return;

    const current = this.resolveWorkspaceModel(ws);
    const nextLevel = VALID_MODEL_LEVELS.includes(current.effort) ? current.effort : 'high';
    const resolved = resolveEffectiveModelAndLevel({
      model: fam.family,
      modelLevel: nextLevel
    });

    ws.model = resolved.modelId || fam.family;
    ws.modelLevel = resolved.effort || nextLevel;
    await this.configStore.saveConfig();
    await this.sendWorkspaceRepoInfo(chatId, ws.id, editMessageId);
  }

  async handleUpdateWorkspaceModelLevel(chatId, wsId, level, editMessageId = null) {
    const ws = this.getWorkspace(wsId);
    if (!ws) return;
    if (!VALID_MODEL_LEVELS.includes(level)) return;

    const current = this.resolveWorkspaceModel(ws);
    const baseModel = current.family || ws.model || this.configStore.config.defaultModel || 'gemini-3.8-flash';
    const resolved = resolveEffectiveModelAndLevel({
      model: baseModel,
      modelLevel: level
    });

    ws.model = resolved.modelId || baseModel;
    ws.modelLevel = resolved.effort || level;
    await this.configStore.saveConfig();
    await this.sendWorkspaceRepoInfo(chatId, ws.id, editMessageId);
  }

  async handleSetModelCommand(chatId, wsId, rawArgs) {
    const ws = this.getWorkspace(wsId);
    if (!ws) return;
    const wsLabel = this.getWorkspaceLabel(ws);
    const tokens = String(rawArgs || '').trim().split(/\s+/).filter(Boolean);
    if (tokens.length === 0) {
      await this.sendWorkspaceRepoInfo(chatId, ws.id);
      return;
    }

    let rawLevel = '';
    if (tokens.length >= 2 && VALID_MODEL_LEVELS.includes(tokens[tokens.length - 1].toLowerCase())) {
      rawLevel = tokens.pop().toLowerCase();
    }
    const rawModel = tokens.join(' ').toLowerCase();
    const suffixMatch = rawModel.match(/^(.*)-(low|medium|high)$/);
    const baseCandidate = suffixMatch ? suffixMatch[1] : rawModel;
    const suffixLevel = suffixMatch ? suffixMatch[2] : '';

    const matchedFam = GEMINI_MODEL_FAMILIES.find(
      (f) =>
        f.shortCode === rawModel ||
        f.family === rawModel ||
        f.family === baseCandidate ||
        f.aliases.includes(rawModel) ||
        f.aliases.includes(baseCandidate)
    );

    if (!matchedFam) {
      await this.telegram.sendMessage({
        chatId,
        text: `⚠️ Choose one of the supported models below (${GEMINI_MODEL_FAMILIES.map((f) => escapeHtml(f.label)).join(', ')}) and levels (<code>low</code> / <code>medium</code> / <code>high</code>):`
      });
      await this.sendWorkspaceRepoInfo(chatId, ws.id);
      return;
    }

    const fallbackLevel =
      rawLevel || suffixLevel || (VALID_MODEL_LEVELS.includes(ws.modelLevel) ? ws.modelLevel : 'high');
    const resolved = resolveEffectiveModelAndLevel({
      model: matchedFam.family,
      modelLevel: fallbackLevel
    });

    ws.model = resolved.modelId;
    ws.modelLevel = resolved.effort;
    await this.configStore.saveConfig();

    await this.telegram.sendMessage({
      chatId,
      text:
        `✅ <b>Updated AI model for ${escapeHtml(wsLabel)}</b>\n\n` +
        `• Model: <code>${escapeHtml(ws.model || 'gemini-3.8-flash-high')}</code>\n` +
        `• Level: <code>${escapeHtml(ws.modelLevel || 'high')}</code>`
    });
    await this.sendWorkspaceRepoInfo(chatId, ws.id);
  }

  // ── Selecting Workspace & Same Chat (Default) vs New Chat Flow ─────────────
  async handleSelectIde(chatId, userId, wsId) {
    const ws = this.getWorkspace(wsId);
    if (!ws) {
      await this.sendIdeSelectorMenu(chatId, userId, 'Workspace not found — select an available Workspace:');
      return;
    }

    const wsLabel = this.getWorkspaceLabel(ws);
    const sess = this.configStore.getUserSession(userId);
    sess.selectedWorkspaceId = ws.id;
    sess.currentView = 'WORKSPACE_DETAIL';
    sess.lastWorkspaceMenuMessageId = null;
    this.lastWorkspaceMenuByChat.delete(chatId);

    const st = this.configStore.getWorkspaceState(ws.id);

    // If this Workspace is mid-workflow (agent running, commit choice, Jenkins choice, ok/revert), resume right where it paused!
    if (st.phase !== 'IDLE' && st.phase !== 'SELECT_CHAT') {
      await this.configStore.saveState();
      await this.sendCurrentWorkspaceGatePrompt(
        chatId,
        ws,
        `🗂 <b>Switched to Workspace: ${escapeHtml(wsLabel)}</b>\n\nResuming pending step:`
      );
      return;
    }

    st.phase = 'SELECT_CHAT';

    // Discover recent Antigravity conversations for this workspace
    const discovered = await discoverRecentWorkspaceConversations(
      this.configStore.config.antigravityBrainDir,
      ws.path,
      { maxResults: 1 }
    );
    this.cachedRecentChatsByWs.set(ws.id, discovered);

    // Same Chat is active by default when selecting a Workspace
    if (!st.conversationId) {
      if (discovered.length > 0) {
        st.conversationId = discovered[0].conversationId;
        st.continueLatest = false;
      } else {
        st.continueLatest = true;
      }
    }
    await this.configStore.saveState();

    const keyboard = this.buildIdeSelectedKeyboard(ws, discovered, st);

    const allJobs = this.getWorkspaceJenkinsJobs(ws);
    const shortJobsSummary = allJobs.map((j) => shortJenkinsJobLabel(j)).join(', ');
    const prodJobs = this.getWorkspaceProdJenkinsJobs(ws);
    const shortProdSummary = prodJobs.map((j) => shortJenkinsJobLabel(j)).join(', ');
    const hasProd = prodJobs.length > 0;
    const modelInfo = this.resolveWorkspaceModel(ws);

    const engineTag =
      ws.engine === 'aider'
        ? 'Aider CLI'
        : ws.engine === 'direct-api'
          ? 'Direct API'
          : 'AGY';

    const infoSections = [
      `🗂 <b>Workspace Selected</b>\n<b>${escapeHtml(wsLabel)}</b>\n<code>${escapeHtml(ws.path)}</code>`,
      `🧠 AI Model: <code>${escapeHtml(modelInfo.displayLabel)}</code> [${escapeHtml(engineTag)}]`
    ];

    if (hasProd) {
      if (shortJobsSummary) {
        infoSections.push(`🚀 Staging (${allJobs.length}): <code>${escapeHtml(shortJobsSummary)}</code>`);
      }
      infoSections.push(`🏁 Prod (${prodJobs.length}): <code>${escapeHtml(shortProdSummary)}</code>`);
    } else if (shortJobsSummary) {
      infoSections.push(`🚀 Jenkins (${allJobs.length}): <code>${escapeHtml(shortJobsSummary)}</code>`);
    }

    await this.telegram.sendMessage({
      chatId,
      text: infoSections.join('\n\n'),
      replyMarkup: { inline_keyboard: keyboard }
    });
  }

  buildIdeSelectedKeyboard(ws, _discovered = [], st = {}) {
    const isNewChatSelected = !st.conversationId && !st.continueLatest;
    const isSameChatSelected = !isNewChatSelected;

    return [
      [
        {
          text: `${isSameChatSelected ? '✅' : '💬'} Same Chat${isSameChatSelected ? ' •' : ''}`,
          callback_data: `chat:same:${ws.id}`
        },
        {
          text: `🆕 New Chat${isNewChatSelected ? ' •' : ''}`,
          callback_data: `chat:new:${ws.id}`
        }
      ],
      [
        { text: '📜 History', callback_data: `chat:hist:${ws.id}` },
        { text: '🧠 AI Model', callback_data: `ide:cfg:${ws.id}` }
      ]
    ];
  }

  async activateSameChat(chatId, userId, wsId) {
    const ws = this.getWorkspace(wsId);
    if (!ws) return;
    const wsLabel = this.getWorkspaceLabel(ws);
    const sess = this.configStore.getUserSession(userId);
    sess.selectedWorkspaceId = ws.id;
    sess.currentView = 'WORKSPACE_DETAIL';
    sess.lastWorkspaceMenuMessageId = null;
    this.lastWorkspaceMenuByChat.delete(chatId);

    const st = this.configStore.getWorkspaceState(ws.id);
    if (!st.conversationId) {
      const discovered = await discoverRecentWorkspaceConversations(
        this.configStore.config.antigravityBrainDir,
        ws.path,
        { maxResults: 1 }
      );
      if (discovered.length > 0) {
        st.conversationId = discovered[0].conversationId;
        st.continueLatest = false;
      } else {
        st.continueLatest = true;
      }
    }
    st.phase = 'IDLE';
    await this.configStore.saveState();

    await this.telegram.sendMessage({
      chatId,
      text:
        `✅ <b>Continuing Same Chat in ${escapeHtml(wsLabel)}</b>` +
        (st.conversationId ? ` (<code>${escapeHtml(st.conversationId.slice(0, 8))}</code>)` : '') +
        `.\n\nType your message or send a photo (with or without caption):`,
      replyMarkup: {
        inline_keyboard: [
          [
            { text: '🆕 New Chat', callback_data: `chat:new:${ws.id}` },
            { text: '📜 History', callback_data: `chat:hist:${ws.id}` }
          ],
          [{ text: '🧠 AI Model', callback_data: `ide:cfg:${ws.id}` }]
        ]
      }
    });
  }

  async activateNewChat(chatId, wsId) {
    const ws = this.getWorkspace(wsId);
    if (!ws) return;
    const wsLabel = this.getWorkspaceLabel(ws);
    const st = this.configStore.getWorkspaceState(ws.id);

    if (st.phase !== 'IDLE' && st.phase !== 'SELECT_CHAT') {
      await this.sendCurrentWorkspaceGatePrompt(
        chatId,
        ws,
        `⚠️ Complete or cancel the active turn in <b>${escapeHtml(wsLabel)}</b> before starting a new chat:`
      );
      return;
    }

    this.#cancelInputBatch(ws.id);
    st.conversationId = null;
    st.continueLatest = false;
    st.pendingPhotos = [];
    st.phase = 'IDLE';
    await this.configStore.saveState();

    await this.telegram.sendMessage({
      chatId,
      text:
        `🆕 <b>New Chat Ready in ${escapeHtml(wsLabel)}</b>\n\n` +
        `Type your message or attach a photo (with or without caption):`,
      replyMarkup: {
        inline_keyboard: [
          [
            { text: '💬 Same Chat', callback_data: `chat:same:${ws.id}` },
            { text: '🧠 AI Model', callback_data: `ide:cfg:${ws.id}` }
          ]
        ]
      }
    });
  }

  async sendLatestMessagesForWorkspace(chatId, wsId) {
    const ws = this.getWorkspace(wsId);
    if (!ws) return;
    const wsLabel = this.getWorkspaceLabel(ws);
    const st = this.configStore.getWorkspaceState(ws.id);
    const count = this.getConfiguredHistoryCount();

    if (!st.conversationId && !st.continueLatest) {
      await this.telegram.sendMessage({
        chatId,
        text: `📭 No messages in the current new chat for <b>${escapeHtml(wsLabel)}</b> yet.`
      });
      return;
    }

    let effectiveConvId = st.conversationId;
    if (!effectiveConvId) {
      const discovered = await discoverRecentWorkspaceConversations(
        this.configStore.config.antigravityBrainDir,
        ws.path,
        { maxResults: 1 }
      );
      if (discovered.length > 0) {
        effectiveConvId = discovered[0].conversationId;
      }
    }

    const { total, messages } = await getLatestConversationMessages({
      brainDir: this.configStore.config.antigravityBrainDir,
      conversationId: effectiveConvId,
      fallbackMessages: st.messages,
      limit: count
    });

    if (messages.length === 0) {
      await this.telegram.sendMessage({
        chatId,
        text: `📭 No previous messages found in <b>${escapeHtml(wsLabel)}</b> yet.`
      });
      return;
    }

    const formatted = messages
      .map((m) => {
        const who = m.role === 'user' ? '👤 <b>You</b>' : '🤖 <b>Agent</b>';
        return `${who}:\n${markdownToTelegramHtml(truncateText(m.text, 700))}`;
      })
      .join('\n\n──────────────\n\n');

    await this.telegram.sendMessage({
      chatId,
      text:
        `📜 <b>Latest ${messages.length} of ${total} message(s) in ${escapeHtml(wsLabel)}:</b>\n\n` +
        formatted
    });
  }

  // ── STEP 1: Run Antigravity Agent (Text + Up to 5 File/Photo Attachments) ──
  async startAgentTurn(chatId, ws, promptText, { extraNotice = '', isAddFix = false } = {}) {
    const st = this.configStore.getWorkspaceState(ws.id);
    const allQueuedFiles = [...(st.pendingPhotos || [])];
    const attachedPhotos = allQueuedFiles.slice(0, MAX_FILES_PER_TURN);
    const droppedFromQueue = Math.max(0, allQueuedFiles.length - attachedPhotos.length);
    st.pendingPhotos = [];

    if (!promptText && attachedPhotos.length === 0) {
      await this.telegram.sendMessage({
        chatId,
        text: '✏️ Type a message or attach a photo/file first.'
      });
      return;
    }

    if (!isAddFix || !st.baselineSnapshots) {
      const baselineSnapshots = await snapshotWorkspaceRepos(ws.repos || []);
      st.baselineSnapshots = baselineSnapshots;
    }

    const turnId = isAddFix && st.activeTurn?.id
      ? st.activeTurn.id
      : `turn-${Date.now()}-${crypto.randomBytes(3).toString('hex')}`;

    st.phase = 'RUNNING_AGENT';
    st.lastError = null;
    st.pendingDeltas = [];

    if (isAddFix && st.activeTurn) {
      st.activeTurn.fixPrompt = promptText;
      if (promptText) {
        st.activeTurn.prompt = `${st.activeTurn.prompt}\n[Fix]: ${promptText}`;
      }
    } else {
      st.activeTurn = {
        id: turnId,
        createdAt: this.nowProvider().toISOString(),
        prompt: promptText || '(Photo prompt)',
        photoCount: attachedPhotos.length,
        agentResponse: '',
        commits: [],
        revertCommits: [],
        builds: [],
        rollbackBuilds: []
      };
    }

    st.messages.push({
      role: 'user',
      text: promptText || `[Attached ${attachedPhotos.length} file(s)]`,
      conversationId: st.conversationId || null,
      at: this.nowProvider().toISOString()
    });
    if (st.messages.length > 80) st.messages = st.messages.slice(-80);
    await this.configStore.saveState();

    const combinedNotice =
      extraNotice ||
      (droppedFromQueue > 0
        ? `⚠️ Max ${MAX_FILES_PER_TURN} files allowed at once — attached first ${MAX_FILES_PER_TURN} file(s), skipped ${droppedFromQueue}.`
        : '');

    const wsLabel = this.getWorkspaceLabel(ws);
    const modelInfo = this.resolveWorkspaceModel(ws);
    const statusMsg = await this.telegram.sendMessage({
      chatId,
      text: isAddFix
        ? `🔧 <b>Applying fix in ${escapeHtml(wsLabel)}…</b>\n\n` +
          `🧠 <code>${escapeHtml(modelInfo.displayLabel)}</code>` +
          `\n<i>Working on requested fixes in the same process…</i>`
        : `🤖 Antigravity working…\n` +
          `<b>${escapeHtml(wsLabel)}</b>\n\n` +
          `🧠 <code>${escapeHtml(modelInfo.displayLabel)}</code>` +
          (attachedPhotos.length > 0
            ? `\n📎 Attached ${attachedPhotos.length}/${MAX_FILES_PER_TURN} file(s)`
            : '') +
          (combinedNotice ? `\n\n${escapeHtml(combinedNotice)}` : ''),
      replyMarkup: {
        inline_keyboard: [[{ text: '🛑 Stop Agent', callback_data: `agent:stop:${ws.id}` }]]
      }
    });

    // Run asynchronously so the bot keeps responding if the user switches IDEs!
    this.#trackAsync(
      this.#executeAgentTurn(chatId, ws, st, attachedPhotos, statusMsg?.message_id, {
        promptOverride: isAddFix ? promptText : '',
        isAddFix
      }).catch(
        async (err) => {
          st.phase = isAddFix ? 'AWAITING_COMMIT_CHOICE' : 'IDLE';
          st.lastError = err.message || String(err);
          await this.configStore.saveState();
          await this.telegram.sendMessage({
            chatId,
            text: `❌ Unexpected error in <b>${escapeHtml(wsLabel)}</b>: ${escapeHtml(st.lastError)}`
          });
          if (isAddFix) {
            const deltas = [];
            for (const repo of ws.repos || []) {
              const delta = await detectRepoChangesSinceSnapshot(repo, st.baselineSnapshots?.[repo.name]);
              if (delta.changedFiles.length > 0 || delta.headAdvanced) {
                deltas.push(delta);
              }
            }
            st.pendingDeltas = deltas;
            await this.sendCommitPrompt(chatId, ws, deltas);
          }
        }
      )
    );
  }

  async #executeAgentTurn(
    chatId,
    ws,
    st,
    attachedPhotos,
    statusMessageId,
    { promptOverride = '', isAutoCommitFix = false, isAddFix = false, originalErrorLog = '' } = {}
  ) {
    let lastProgressEditMs = 0;

    const wsLabel = this.getWorkspaceLabel(ws);
    const effectiveModel = this.resolveWorkspaceModel(ws);
    const effectivePrompt =
      promptOverride ||
      (st.activeTurn.prompt === '(Photo prompt)' ? '' : st.activeTurn.prompt);
    this.log('stage', `AI Agent Executing: ${wsLabel}`);
    this.log('agent', `Executing ${ws.engine || 'agy'} with model ${effectiveModel.modelId} on workspace "${wsLabel}"`);
    const runSingleAttempt = async (attemptConversationId) => {
      const { promise, abort } = this.agentRunner({
        agyBin: this.configStore.config.agyBin,
        aiderBin: this.configStore.config.aiderBin,
        agentEngine: ws.engine || this.configStore.config.agentEngine || 'agy',
        openaiApiKey: this.configStore.config.openaiApiKey,
        anthropicApiKey: this.configStore.config.anthropicApiKey,
        deepseekApiKey: this.configStore.config.deepseekApiKey,
        qwenApiKey: this.configStore.config.qwenApiKey,
        customApiBaseUrl: this.configStore.config.customApiBaseUrl,
        customApiKey: this.configStore.config.customApiKey,
        workspacePath: ws.path,
        prompt: effectivePrompt,
        imagePaths: attachedPhotos.map((p) => p.path),
        conversationId: attemptConversationId,
        // Never pass global `--continue` when a workspace has no conversationId yet,
        // because `agy` CLI shares `default-cli-project` across workspaces.
        continueLatest: false,
        model: effectiveModel.modelId || ws.model || 'gemini-3.8-flash-high',
        modelLevel: effectiveModel.effort || ws.modelLevel || 'high',
        skipPermissions: Boolean(this.configStore.config.skipPermissions),
        extraDirs: ws.extraDirs || [],
        onConversationId: (convId) => {
          st.conversationId = convId;
          st.continueLatest = false;
          // Backfill conversationId on most recent user message
          const lastMsg = st.messages[st.messages.length - 1];
          if (lastMsg && !lastMsg.conversationId) {
            lastMsg.conversationId = convId;
          }
        },
        onStepEvent: (evt) => {
          if (evt.toolName) {
            this.log('agent', `Tool execution: ${evt.toolName} (${evt.state || 'running'})`);
          }
          const nowMs = Date.now();
          if (statusMessageId && nowMs - lastProgressEditMs > 3000) {
            lastProgressEditMs = nowMs;
            const stepLabel = evt.toolName
              ? `${evt.stepType}: ${evt.toolName} (${evt.state})`
              : `${evt.stepType} (${evt.state})`;
            this.telegram
              .editMessageText({
                chatId,
                messageId: statusMessageId,
                text:
                  `🤖 Antigravity working…\n` +
                  `<b>${escapeHtml(wsLabel)}</b>\n\n` +
                  `⚙️ <code>${escapeHtml(stepLabel)}</code>`,
                replyMarkup: {
                  inline_keyboard: [[{ text: '🛑 Stop Agent', callback_data: `agent:stop:${ws.id}` }]]
                }
              })
              .catch(() => {});
          }
        }
      });

      this.runtime.set(ws.id, { abortAgent: abort });
      try {
        return await promise;
      } finally {
        this.runtime.delete(ws.id);
      }
    };

    try {
      const initialConvId = st.conversationId || null;
      let result;
      try {
        result = await runSingleAttempt(initialConvId);
      } catch (firstErr) {
        if (initialConvId && isMissingTrajectoryError(firstErr)) {
          // Stale, pruned, or Desktop-IDE-only trajectory ID — reset to a fresh CLI conversation and retry once automatically!
          st.conversationId = null;
          st.continueLatest = false;
          const lastMsg = st.messages[st.messages.length - 1];
          if (lastMsg && lastMsg.conversationId === initialConvId) {
            lastMsg.conversationId = null;
          }
          await this.configStore.saveState();
          result = await runSingleAttempt(null);
        } else {
          throw firstErr;
        }
      }

      if (result.conversationId) {
        st.conversationId = result.conversationId;
        st.continueLatest = false;
        const lastMsg = st.messages[st.messages.length - 1];
        if (lastMsg && !lastMsg.conversationId) {
          lastMsg.conversationId = result.conversationId;
        }
      }

      const replyText = result.response || '(Agent completed with no text output)';
      st.activeTurn.agentResponse = replyText;
      st.messages.push({
        role: 'assistant',
        text: replyText,
        conversationId: st.conversationId || null,
        at: this.nowProvider().toISOString()
      });
      if (st.messages.length > 80) st.messages = st.messages.slice(-80);

      if (statusMessageId) {
        await this.telegram.clearInlineButtons(chatId, statusMessageId);
      }

      await this.telegram.sendMessage({
        chatId,
        text: `🤖 <b>${escapeHtml(wsLabel)} — Agent Response:</b>\n\n${markdownToTelegramHtml(replyText)}`
      });
      this.log('agent', `Turn execution finished in workspace "${wsLabel}".`);
      this.log('stage', 'Ready for Telegram requests');
    } catch (agentErr) {
      this.log('agent', `Agent stopped/failed in workspace "${wsLabel}": ${agentErr.message}`);
      this.log('stage', 'Ready for Telegram requests');
      this.runtime.delete(ws.id);
      if (statusMessageId) {
        await this.telegram.clearInlineButtons(chatId, statusMessageId);
      }
      if (!isAddFix) {
        for (const repo of ws.repos || []) {
          await discardUncommittedTurnChanges(repo, st.baselineSnapshots?.[repo.name]).catch(() => {});
        }
        st.phase = 'IDLE';
        st.activeTurn = null;
        st.baselineSnapshots = null;
        st.pendingDeltas = [];
        st.lastError = agentErr.message;
        await this.configStore.saveState();

        await this.telegram.sendMessage({
          chatId,
          text:
            `❌ <b>Agent stopped/failed in ${escapeHtml(wsLabel)}:</b>\n\n` +
            `${escapeHtml(agentErr.message)}\n\n` +
            `Uncommitted edits from this run were cleaned up. Ready for your next message.`,
          replyMarkup: MAIN_REPLY_KEYBOARD
        });
      } else {
        st.phase = 'AWAITING_COMMIT_CHOICE';
        st.lastError = agentErr.message;
        await this.configStore.saveState();

        await this.telegram.sendMessage({
          chatId,
          text:
            `❌ <b>Agent stopped/failed while applying fix in ${escapeHtml(wsLabel)}:</b>\n\n` +
            `${escapeHtml(agentErr.message)}\n\n` +
            `Existing uncommitted edits are preserved.`
        });
        const deltas = [];
        for (const repo of ws.repos || []) {
          const delta = await detectRepoChangesSinceSnapshot(repo, st.baselineSnapshots?.[repo.name]);
          if (delta.changedFiles.length > 0 || delta.headAdvanced) {
            deltas.push(delta);
          }
        }
        st.pendingDeltas = deltas;
        await this.sendCommitPrompt(chatId, ws, deltas);
      }
      return;
    }

    // ── Inspect Changed Files Across Workspace Sub-Repos ─────────────────────
    const deltas = [];
    for (const repo of ws.repos || []) {
      const delta = await detectRepoChangesSinceSnapshot(repo, st.baselineSnapshots?.[repo.name]);
      if (delta.changedFiles.length > 0 || delta.headAdvanced) {
        deltas.push(delta);
      }
    }

    if (deltas.length === 0) {
      if (isAutoCommitFix) {
        st.phase = 'AWAITING_OK_OR_REVERT';
        st.lastError = originalErrorLog || 'Jenkins build failed';
        await this.configStore.saveState();

        await this.telegram.sendMessage({
          chatId,
          text: `ℹ️ <b>No code changes were made by the agent to fix the Jenkins build error.</b>`
        });
        await this.sendJenkinsFailurePrompt(chatId, ws, {
          jobName: st.activeTurn?.lastFailedJob || '',
          buildNumber: st.activeTurn?.lastFailedBuildNumber,
          result: 'FAILURE',
          errorLog: st.lastError
        });
        return;
      }

      st.history.push({
        id: st.activeTurn.id,
        createdAt: st.activeTurn.createdAt,
        finishedAt: this.nowProvider().toISOString(),
        prompt: st.activeTurn.prompt,
        outcome: 'NO_CHANGES'
      });
      st.phase = 'IDLE';
      st.activeTurn = null;
      st.baselineSnapshots = null;
      st.pendingDeltas = [];
      await this.configStore.saveState();

      await this.telegram.sendMessage({
        chatId,
        text: `ℹ️ <b>No files were changed in ${escapeHtml(wsLabel)}.</b>\n\nReady for your next message.`,
        replyMarkup: MAIN_REPLY_KEYBOARD
      });
      return;
    }

    if (isAutoCommitFix) {
      const commitMessage = buildAutoCommitMessage(`fix Jenkins build error in ${wsLabel}`);
      const commits = [];
      const branchToPush =
        st.activeTurn?.targetBranch || st.activeTurn?.commits?.[0]?.branch || '';

      try {
        for (const repo of ws.repos || []) {
          const freshDelta = await detectRepoChangesSinceSnapshot(
            repo,
            st.baselineSnapshots?.[repo.name]
          );

          if (freshDelta.changedFiles.length > 0) {
            const rec = await commitAndPushRepoChanges(repo, freshDelta, commitMessage, {
              push: this.gitPush,
              customBranch: branchToPush
            });
            if (rec) commits.push(rec);
          } else if (freshDelta.headAdvanced) {
            const recs = await collectAgentCommitsAndPush(repo, freshDelta, { push: this.gitPush });
            commits.push(...recs);
          }
        }
      } catch (gitErr) {
        if (gitErr.commitRecord) {
          commits.push(gitErr.commitRecord);
        } else if (Array.isArray(gitErr.commitRecords)) {
          commits.push(...gitErr.commitRecords);
        }
        st.activeTurn.commits = [...(st.activeTurn?.commits || []), ...commits];
        st.lastError = gitErr.message;
        st.phase = 'AWAITING_COMMIT_CHOICE';
        await this.configStore.saveState();
        await this.telegram.sendMessage({
          chatId,
          text: `❌ <b>Git commit/push failed during fix:</b>\n<code>${escapeHtml(gitErr.message)}</code>`
        });
        await this.sendCommitPrompt(chatId, ws, deltas);
        return;
      }

      st.activeTurn.commits = [...(st.activeTurn?.commits || []), ...commits];
      st.pendingDeltas = [];
      st.lastError = null;

      const commitLines = commits.map(
        (c) =>
          `• <code>${escapeHtml(c.repoName)}</code> @ <code>${escapeHtml(c.shortSha)}</code> → <code>origin/${escapeHtml(c.branch)}</code> (${c.changedFiles.length} file${c.changedFiles.length === 1 ? '' : 's'})`
      );

      await this.telegram.sendMessage({
        chatId,
        text:
          `✅ <b>Auto-committed &amp; pushed fix for Jenkins build failure</b>\n\n` +
          `Message: <code>${escapeHtml(commitMessage)}</code>\n\n` +
          commitLines.join('\n')
      });

      const matchedTargets = this.resolveMatchedJenkinsTargets(ws, st, { isAfterRevert: false });
      const allWsTargets = this.buildAllWorkspaceTargets(ws, commits);

      if (matchedTargets.length === 0 && allWsTargets.length === 0) {
        st.phase = 'AWAITING_OK_OR_REVERT';
        await this.configStore.saveState();
        await this.sendIsItOkayPrompt(
          chatId,
          ws,
          'ℹ️ No Jenkins job is mapped for the modified repository.'
        );
        return;
      }

      st.phase = 'AWAITING_JENKINS_CHOICE';
      await this.configStore.saveState();
      await this.sendRunJenkinsPrompt(chatId, ws, matchedTargets, { isAfterRevert: false });
      return;
    }

    st.pendingDeltas = deltas;
    st.phase = 'AWAITING_COMMIT_CHOICE';
    await this.configStore.saveState();

    await this.sendCommitPrompt(chatId, ws, deltas);
  }

  formatChangedFilesSummary(ws, deltas) {
    const wsLabel = this.getWorkspaceLabel(ws);
    let totalFiles = 0;
    const repoBlocks = [];

    for (const d of deltas) {
      const count = d.fileStatuses?.length || d.changedFiles?.length || 0;
      totalFiles += count;
      const lines = (d.fileStatuses || []).slice(0, 40).map(
        (f) => `  <code>${escapeHtml(f.status)}</code> <code>${escapeHtml(f.path)}</code>`
      );
      if ((d.fileStatuses || []).length > 40) {
        lines.push(`  <i>…and ${d.fileStatuses.length - 40} more file(s)</i>`);
      } else if (lines.length === 0 && d.headAdvanced) {
        lines.push('  <i>(Local commit created during turn)</i>');
      }
      repoBlocks.push(
        `📦 <b>${escapeHtml(d.repoName)}</b> (branch: <code>${escapeHtml(d.branch)}</code>):\n${lines.join('\n')}`
      );
    }

    return (
      `📝 <b>Changes made in ${escapeHtml(wsLabel)}</b> (${totalFiles} file${totalFiles === 1 ? '' : 's'} in ${deltas.length} repo${deltas.length === 1 ? '' : 's'}):\n\n` +
      `${repoBlocks.join('\n\n')}\n\n` +
      `<b>Commit &amp; push these changes?</b>`
    );
  }

  async sendCommitPrompt(chatId, ws, deltas) {
    const defaultBranches = [...new Set(deltas.map((d) => d.branch || 'master'))].join(', ');
    await this.telegram.sendMessage({
      chatId,
      text: this.formatChangedFilesSummary(ws, deltas),
      replyMarkup: {
        inline_keyboard: [
          [
            { text: `✅ Yes (${defaultBranches})`, callback_data: `cmt:yes:${ws.id}` },
            { text: '🌿 Custom Branch', callback_data: `cmt:br:${ws.id}` }
          ],
          [
            { text: '➕ Add Fix', callback_data: `cmt:fix:${ws.id}` },
            { text: '❌ No (Discard Changes)', callback_data: `cmt:no:${ws.id}` }
          ]
        ]
      }
    });
  }

  // ── STEP 2: Commit? Yes / No / Custom-Branch ───────────────────────────────
  async handleCommitNo(chatId, wsId) {
    const ws = this.getWorkspace(wsId);
    if (!ws) return;
    const wsLabel = this.getWorkspaceLabel(ws);
    const st = this.configStore.getWorkspaceState(ws.id);

    if (
      st.phase !== 'AWAITING_COMMIT_CHOICE' &&
      st.phase !== 'AWAITING_CUSTOM_BRANCH' &&
      st.phase !== 'AWAITING_FIX_PROMPT'
    ) {
      await this.sendCurrentWorkspaceGatePrompt(chatId, ws);
      return;
    }

    for (const repo of ws.repos || []) {
      if (st.baselineSnapshots?.[repo.name]) {
        await discardUncommittedTurnChanges(repo, st.baselineSnapshots[repo.name]).catch(() => {});
      }
    }

    if (st.activeTurn) {
      st.history.push({
        id: st.activeTurn.id,
        createdAt: st.activeTurn.createdAt,
        finishedAt: this.nowProvider().toISOString(),
        prompt: st.activeTurn.prompt,
        outcome: 'DISCARDED_BEFORE_COMMIT'
      });
    }

    st.phase = 'IDLE';
    st.activeTurn = null;
    st.baselineSnapshots = null;
    st.pendingDeltas = [];
    st.lastError = null;
    await this.configStore.saveState();

    await this.telegram.sendMessage({
      chatId,
      text:
        `🗑 Discarded uncommitted changes in <b>${escapeHtml(wsLabel)}</b> (did not commit).\n\n` +
        `Ready for your next message!`,
      replyMarkup: MAIN_REPLY_KEYBOARD
    });
  }

  async promptForAddFix(chatId, wsId) {
    const ws = this.getWorkspace(wsId);
    if (!ws) return;
    const wsLabel = this.getWorkspaceLabel(ws);
    const st = this.configStore.getWorkspaceState(ws.id);

    if (st.phase !== 'AWAITING_COMMIT_CHOICE') {
      await this.sendCurrentWorkspaceGatePrompt(chatId, ws);
      return;
    }

    st.phase = 'AWAITING_FIX_PROMPT';
    await this.configStore.saveState();

    await this.telegram.sendMessage({
      chatId,
      text:
        `➕ <b>Add Fix in ${escapeHtml(wsLabel)}</b>\n\n` +
        `Reply with what to fix or modify in the current process (your uncommitted changes are preserved):`,
      replyMarkup: {
        inline_keyboard: [[{ text: '↩️ Back to Commit Options', callback_data: `cmt:back:${ws.id}` }]]
      }
    });
  }

  async handleFixPromptSubmitted(chatId, ws, promptText) {
    const wsLabel = this.getWorkspaceLabel(ws);
    const st = this.configStore.getWorkspaceState(ws.id);

    if (st.phase !== 'AWAITING_FIX_PROMPT') {
      await this.sendCurrentWorkspaceGatePrompt(chatId, ws);
      return;
    }

    await this.startAgentTurn(chatId, ws, promptText, { isAddFix: true });
  }

  async promptForCustomBranch(chatId, wsId) {
    const ws = this.getWorkspace(wsId);
    if (!ws) return;
    const wsLabel = this.getWorkspaceLabel(ws);
    const st = this.configStore.getWorkspaceState(ws.id);

    if (st.phase !== 'AWAITING_COMMIT_CHOICE') {
      await this.sendCurrentWorkspaceGatePrompt(chatId, ws);
      return;
    }

    st.phase = 'AWAITING_CUSTOM_BRANCH';
    await this.configStore.saveState();

    await this.telegram.sendMessage({
      chatId,
      text:
        `🌿 <b>Custom Branch for ${escapeHtml(wsLabel)}</b>\n\n` +
        `Reply with the branch name to commit &amp; push to (e.g. <code>feat/mobile-fix</code>):`,
      replyMarkup: {
        inline_keyboard: [[{ text: '↩️ Back to Commit Options', callback_data: `cmt:back:${ws.id}` }]]
      }
    });
  }

  async handleCustomBranchSubmitted(chatId, ws, branchInput) {
    const branchName = String(branchInput || '').trim();
    const isValid = await validateGitBranchName(branchName);
    if (!isValid) {
      await this.telegram.sendMessage({
        chatId,
        text: `❌ Invalid git branch name: <code>${escapeHtml(branchName)}</code>. Please reply with a valid branch name (no spaces or <code>..</code>):`,
        replyMarkup: {
          inline_keyboard: [[{ text: '↩️ Back to Commit Options', callback_data: `cmt:back:${ws.id}` }]]
        }
      });
      return;
    }

    await this.handleCommitYes(chatId, ws.id, branchName);
  }

  async handleCommitYes(chatId, wsId, customBranch = '') {
    const ws = this.getWorkspace(wsId);
    if (!ws) return;
    const st = this.configStore.getWorkspaceState(ws.id);

    if (
      st.phase !== 'AWAITING_COMMIT_CHOICE' &&
      st.phase !== 'AWAITING_CUSTOM_BRANCH' &&
      st.phase !== 'AWAITING_FIX_PROMPT'
    ) {
      await this.sendCurrentWorkspaceGatePrompt(chatId, ws);
      return;
    }

    const commitMessage = buildAutoCommitMessage(st.activeTurn?.prompt || 'workspace update');
    const commits = [];

    try {
      for (const repo of ws.repos || []) {
        const freshDelta = await detectRepoChangesSinceSnapshot(
          repo,
          st.baselineSnapshots?.[repo.name]
        );

        if (freshDelta.changedFiles.length > 0) {
          const rec = await commitAndPushRepoChanges(repo, freshDelta, commitMessage, {
            push: this.gitPush,
            customBranch
          });
          if (rec) commits.push(rec);
        } else if (freshDelta.headAdvanced) {
          const recs = await collectAgentCommitsAndPush(repo, freshDelta, { push: this.gitPush });
          commits.push(...recs);
        }
      }
    } catch (gitErr) {
      if (gitErr.commitRecord) {
        commits.push(gitErr.commitRecord);
      } else if (Array.isArray(gitErr.commitRecords)) {
        commits.push(...gitErr.commitRecords);
      }
      if (st.activeTurn) {
        st.activeTurn.commits = commits;
      }
      st.lastError = gitErr.message;

      if (commits.length > 0) {
        st.phase = 'AWAITING_JENKINS_CHOICE';
        await this.configStore.saveState();
        await this.telegram.sendMessage({
          chatId,
          text:
            `⚠️ <b>Local commit created, but git push failed:</b>\n` +
            `<code>${escapeHtml(gitErr.message)}</code>`,
          replyMarkup: {
            inline_keyboard: [
              [
                { text: '🔄 Retry Git Push', callback_data: `cmt:repush:${ws.id}` },
                { text: '↩️ Revert Commit', callback_data: `ok:rev:${ws.id}` }
              ]
            ]
          }
        });
        return;
      }

      st.phase = 'AWAITING_COMMIT_CHOICE';
      await this.configStore.saveState();
      await this.telegram.sendMessage({
        chatId,
        text: `❌ <b>Git commit failed:</b>\n<code>${escapeHtml(gitErr.message)}</code>`
      });
      await this.sendCommitPrompt(chatId, ws, st.pendingDeltas);
      return;
    }

    st.activeTurn.commits = commits;
    st.pendingDeltas = [];
    st.lastError = null;

    // Output last action explicitly via message text!
    const commitLines = commits.map(
      (c) =>
        `• <code>${escapeHtml(c.repoName)}</code> @ <code>${escapeHtml(c.shortSha)}</code> → <code>origin/${escapeHtml(c.branch)}</code> (${c.changedFiles.length} file${c.changedFiles.length === 1 ? '' : 's'})`
    );

    await this.telegram.sendMessage({
      chatId,
      text:
        `✅ <b>Committed &amp; pushed${customBranch ? ` to custom branch "${escapeHtml(customBranch)}"` : ''}</b>\n\n` +
        `Message: <code>${escapeHtml(commitMessage)}</code>\n\n` +
        commitLines.join('\n')
    });

    const matchedTargets = this.resolveMatchedJenkinsTargets(ws, st, { isAfterRevert: false });
    const allWsTargets = this.buildAllWorkspaceTargets(ws, commits);

    if (matchedTargets.length === 0 && allWsTargets.length === 0) {
      st.phase = 'AWAITING_OK_OR_REVERT';
      await this.configStore.saveState();
      await this.sendIsItOkayPrompt(
        chatId,
        ws,
        'ℹ️ No Jenkins job is mapped for the modified repository.'
      );
      return;
    }

    st.phase = 'AWAITING_JENKINS_CHOICE';
    await this.configStore.saveState();
    await this.sendRunJenkinsPrompt(chatId, ws, matchedTargets, { isAfterRevert: false });
  }

  async handleRetryGitPush(chatId, wsId) {
    const ws = this.getWorkspace(wsId);
    if (!ws) return;
    const st = this.configStore.getWorkspaceState(ws.id);
    const commits = st.activeTurn?.commits || [];

    try {
      for (const c of commits) {
        if (!c.pushed && this.gitPush) {
          await pushRepoCommit(c);
        }
      }
      st.lastError = null;
      await this.configStore.saveState();

      await this.telegram.sendMessage({
        chatId,
        text: `✅ Pushed pending commit(s) to <code>origin</code>.`
      });

      const matchedTargets = this.resolveMatchedJenkinsTargets(ws, st, { isAfterRevert: false });
      const allWsTargets = this.buildAllWorkspaceTargets(ws, commits);

      if (matchedTargets.length > 0 || allWsTargets.length > 0) {
        st.phase = 'AWAITING_JENKINS_CHOICE';
        await this.configStore.saveState();
        await this.sendRunJenkinsPrompt(chatId, ws, matchedTargets, { isAfterRevert: false });
      } else {
        st.phase = 'AWAITING_OK_OR_REVERT';
        await this.configStore.saveState();
        await this.sendIsItOkayPrompt(chatId, ws);
      }
    } catch (err) {
      await this.telegram.sendMessage({
        chatId,
        text: `❌ <b>Git push still failed:</b>\n<code>${escapeHtml(err.message)}</code>`,
        replyMarkup: {
          inline_keyboard: [
            [
              { text: '🔄 Retry Git Push', callback_data: `cmt:repush:${ws.id}` },
              { text: '↩️ Revert Commit', callback_data: `ok:rev:${ws.id}` }
            ]
          ]
        }
      });
    }
  }

  resolveMatchedJenkinsTargets(ws, st, { isAfterRevert = false } = {}) {
    const mapCommitsWithLiveConfig = (records = []) =>
      records
        .map((c) => {
          const liveRepo = (ws?.repos || []).find((r) => r.name === c.repoName);
          const deployEnabled = liveRepo ? Boolean(liveRepo.deployEnabled) : Boolean(c.deployEnabled);
          const jenkinsJob = liveRepo ? liveRepo.jenkinsJob : c.jenkinsJob;
          if (!deployEnabled || !jenkinsJob) return null;
          return {
            jenkinsJob,
            branch: c.branch || liveRepo?.branch || 'master'
          };
        })
        .filter(Boolean);

    if (!isAfterRevert) {
      return this.dedupeJenkinsTargets(mapCommitsWithLiveConfig(st.activeTurn?.commits || []));
    }
    const directRev = this.dedupeJenkinsTargets(
      mapCommitsWithLiveConfig(st.activeTurn?.revertCommits || [])
    );
    if (directRev.length > 0) return directRev;
    return this.dedupeJenkinsTargets(st.activeTurn?.deployedTargets || []);
  }

  // ── STEP 3: Run Jenkins? Yes / No / All / Single Job ───────────────────────
  async sendRunJenkinsPrompt(chatId, ws, targets, { isAfterRevert = false } = {}) {
    const wsLabel = this.getWorkspaceLabel(ws);
    const st = this.configStore.getWorkspaceState(ws.id);
    const sourceCommits = isAfterRevert
      ? st.activeTurn?.revertCommits || []
      : st.activeTurn?.commits || [];
    const allWsTargets = this.buildAllWorkspaceTargets(ws, sourceCommits);
    const hasProd = this.hasWorkspaceProdJenkins(ws);
    const envLabel = hasProd ? 'Staging Jenkins' : 'Jenkins';
    const prefix = isAfterRevert ? 'rjnk' : 'jnk';
    const keyboard = [];
    let bodyText = '';

    if (targets.length > 0) {
      const jobsDesc = targets
        .map(
          (t) =>
            `• <code>${escapeHtml(t.jenkinsJob)}</code> (VERSION=<code>${escapeHtml(t.branch)}</code>)`
        )
        .join('\n');

      bodyText = isAfterRevert
        ? `🚀 <b>Run ${envLabel} to deploy reverted commit(s)?</b>\n\n${jobsDesc}`
        : `🚀 <b>Run ${envLabel} deploy?</b>\n\n${jobsDesc}`;

      keyboard.push([
        { text: `🚀 Yes, Run ${envLabel}`, callback_data: `${prefix}:yes:${ws.id}` },
        { text: '⏭ No', callback_data: `${prefix}:no:${ws.id}` }
      ]);

      if (allWsTargets.length > targets.length) {
        keyboard.push([
          {
            text: `🚀 Run All ${allWsTargets.length} ${wsLabel} ${hasProd ? 'Staging ' : ''}Jobs`,
            callback_data: `${prefix}:all:${ws.id}`
          }
        ]);
      }
    } else {
      const allDesc = allWsTargets
        .map(
          (t) =>
            `• <code>${escapeHtml(t.jenkinsJob)}</code> (VERSION=<code>${escapeHtml(t.branch)}</code>)`
        )
        .join('\n');

      bodyText = isAfterRevert
        ? `🚀 <b>Run ${envLabel} to redeploy ${escapeHtml(wsLabel)} after revert?</b>\n\n${allDesc}`
        : `🚀 <b>Modified shared repository in ${escapeHtml(wsLabel)} — run ${envLabel} deploy?</b>\n\n${allDesc}`;

      keyboard.push([
        {
          text: `🚀 Run All ${allWsTargets.length} ${hasProd ? 'Staging ' : ''}Jobs`,
          callback_data: `${prefix}:all:${ws.id}`
        },
        { text: '⏭ No', callback_data: `${prefix}:no:${ws.id}` }
      ]);

      for (let i = 0; i < allWsTargets.length; i += 2) {
        const row = [];
        for (let j = i; j < Math.min(i + 2, allWsTargets.length); j++) {
          row.push({
            text: `▶️ ${shortJenkinsJobLabel(allWsTargets[j].jenkinsJob)}`,
            callback_data: `${prefix}:one:${ws.id}:${j}`
          });
        }
        keyboard.push(row);
      }
    }

    await this.telegram.sendMessage({
      chatId,
      text: bodyText,
      replyMarkup: { inline_keyboard: keyboard }
    });
  }

  async handleRunJenkinsChoice(
    chatId,
    wsId,
    shouldRun,
    { isAfterRevert = false, mode = 'matched', jobIndex = -1 } = {}
  ) {
    const ws = this.getWorkspace(wsId);
    if (!ws) return;
    const wsLabel = this.getWorkspaceLabel(ws);
    const st = this.configStore.getWorkspaceState(ws.id);

    if (!shouldRun) {
      if (isAfterRevert) {
        if (st.activeTurn) {
          st.history.push({
            id: st.activeTurn.id,
            createdAt: st.activeTurn.createdAt,
            finishedAt: this.nowProvider().toISOString(),
            prompt: st.activeTurn.prompt,
            commits: st.activeTurn.commits,
            revertCommits: st.activeTurn.revertCommits,
            outcome: 'REVERTED_NO_JENKINS'
          });
        }
        st.phase = 'IDLE';
        st.activeTurn = null;
        st.baselineSnapshots = null;
        st.pendingDeltas = [];
        st.lastError = null;
        await this.configStore.saveState();

        await this.telegram.sendMessage({
          chatId,
          text:
            `⏭ Skipped Jenkins after revert.\n\n` +
            `Bad commit remains reverted on <code>origin</code>.\n\n` +
            `<b>${escapeHtml(wsLabel)}</b> is ready for your next message!`,
          replyMarkup: MAIN_REPLY_KEYBOARD
        });
        return;
      }

      // Forward skip Jenkins -> still ask "Is it okay? Yes / Revert"
      st.phase = 'AWAITING_OK_OR_REVERT';
      await this.configStore.saveState();

      await this.telegram.sendMessage({
        chatId,
        text: `⏭ Skipped Jenkins deploy for <b>${escapeHtml(wsLabel)}</b>.`
      });
      await this.sendIsItOkayPrompt(chatId, ws);
      return;
    }

    // Resolve target job(s) to trigger
    const sourceCommits = isAfterRevert
      ? st.activeTurn?.revertCommits || []
      : st.activeTurn?.commits || [];
    const allWsTargets = this.buildAllWorkspaceTargets(ws, sourceCommits);

    let deployTargets = [];
    if (mode === 'all') {
      deployTargets = allWsTargets;
    } else if (mode === 'single' && jobIndex >= 0 && jobIndex < allWsTargets.length) {
      deployTargets = [allWsTargets[jobIndex]];
    } else {
      deployTargets = this.resolveMatchedJenkinsTargets(ws, st, { isAfterRevert });
      if (deployTargets.length === 0) {
        deployTargets = allWsTargets;
      }
    }

    if (st.activeTurn && !isAfterRevert) {
      st.activeTurn.deployedTargets = deployTargets;
    }

    st.phase = isAfterRevert ? 'RUNNING_REVERT_JENKINS' : 'RUNNING_JENKINS';
    st.lastError = null;
    await this.configStore.saveState();

    const jobNames = deployTargets.map((d) => `${d.jenkinsJob} (${d.branch})`).join(', ');
    const progressMsg = await this.telegram.sendMessage({
      chatId,
      text:
        `🚀 <b>Triggered Jenkins deploy…</b>\n` +
        `<b>${escapeHtml(wsLabel)}</b>\n\n` +
        `<code>${escapeHtml(jobNames)}</code>`
    });

    this.#trackAsync(
      this.#executeJenkinsBuilds(
        chatId,
        ws,
        st,
        deployTargets,
        isAfterRevert,
        progressMsg?.message_id
      ).catch(async (err) => {
        st.phase = isAfterRevert ? 'AWAITING_REVERT_JENKINS_CHOICE' : 'AWAITING_OK_OR_REVERT';
        st.lastError = err.message;
        await this.configStore.saveState();
        await this.telegram.sendMessage({
          chatId,
          text: `❌ Jenkins unexpected error: ${escapeHtml(err.message)}`
        });
      })
    );
  }

  async #executeJenkinsBuilds(chatId, ws, st, deployTargets, isAfterRevert, progressMsgId) {
    const wsLabel = this.getWorkspaceLabel(ws);
    const jenkins = this.jenkinsFactory(this.configStore.config.jenkins);
    const results = [];
    let failedBuild = null;

    for (const target of deployTargets) {
      let lastEditMs = 0;
      try {
        this.log('jenkins', `Build triggered for ${target.jenkinsJob} (branch: ${target.branch})`);
        this.log('stage', `Jenkins CI Deploying: ${target.jenkinsJob}`);
        const res = await jenkins.triggerAndWaitForBuild({
          jobName: target.jenkinsJob,
          branch: target.branch,
          onUpdate: (upd) => {
            this.log('jenkins', `Build update: ${target.jenkinsJob} (${upd.message || upd.status})`);
            const nowMs = Date.now();
            if (progressMsgId && nowMs - lastEditMs > 3000) {
              lastEditMs = nowMs;
              this.telegram
                .editMessageText({
                  chatId,
                  messageId: progressMsgId,
                  text:
                    `🚀 <b>Jenkins running…</b>\n` +
                    `<b>${escapeHtml(wsLabel)}</b>\n\n` +
                    `<code>${escapeHtml(upd.message || `${target.jenkinsJob}: ${upd.status}`)}</code>`
                })
                .catch(() => {});
            }
          }
        });

        results.push(res);
        this.log('jenkins', `Build ${target.jenkinsJob} completed with status: ${res.result}`);
        this.log('stage', res.result === 'SUCCESS' ? 'CI/CD Build Succeeded' : 'CI/CD Build Failed');
        if (res.result !== 'SUCCESS' && res.result !== 'TRIGGERED') {
          failedBuild = {
            jobName: target.jenkinsJob,
            branch: target.branch,
            buildNumber: res.buildNumber,
            buildUrl: res.buildUrl,
            result: res.result,
            errorLog: res.consoleTail || `Jenkins ended with status ${res.result}`
          };
          break;
        }
      } catch (err) {
        failedBuild = {
          jobName: target.jenkinsJob,
          branch: target.branch,
          buildNumber: null,
          buildUrl: '',
          result: 'ERROR',
          errorLog: err.message
        };
        break;
      }
    }

    if (st.activeTurn) {
      if (isAfterRevert) {
        st.activeTurn.rollbackBuilds = results;
      } else {
        st.activeTurn.builds = results;
      }
    }

    // ── Jenkins FAILED -> Output Error Log! ──────────────────────────────────
    if (failedBuild) {
      const logSnippet = truncateText(failedBuild.errorLog || 'No console output available.', 2600);

      if (isAfterRevert) {
        st.phase = 'AWAITING_REVERT_JENKINS_CHOICE';
        st.lastError = failedBuild.errorLog;
        await this.configStore.saveState();

        await this.telegram.sendMessage({
          chatId,
          text:
            `❌ <b>Rollback Jenkins Build Failed:</b> <code>${escapeHtml(failedBuild.jobName)}${failedBuild.buildNumber ? ` #${failedBuild.buildNumber}` : ''}</code> (${escapeHtml(failedBuild.result)})\n\n` +
            `<b>Error Log:</b>\n<pre>${escapeHtml(logSnippet)}</pre>`,
          replyMarkup: {
            inline_keyboard: [
              [
                { text: '🔄 Retry Jenkins', callback_data: `rjnk:yes:${ws.id}` },
                { text: '⏹ Finish Without Jenkins', callback_data: `rjnk:no:${ws.id}` }
              ]
            ]
          }
        });
        return;
      }

      st.phase = 'AWAITING_OK_OR_REVERT';
      st.lastError = failedBuild.errorLog;
      if (st.activeTurn) {
        st.activeTurn.lastFailedJob = failedBuild.jobName;
        st.activeTurn.lastFailedBuildNumber = failedBuild.buildNumber;
        st.activeTurn.lastFailedBuild = failedBuild;
      }
      await this.configStore.saveState();

      await this.sendJenkinsFailurePrompt(chatId, ws, failedBuild);
      return;
    }

    // ── Jenkins SUCCEEDED! ───────────────────────────────────────────────────
    const buildSummary = results
      .map(
        (r) =>
          `• <code>${escapeHtml(r.jobName)}${r.buildNumber ? ` #${r.buildNumber}` : ''}</code>: <b>${escapeHtml(r.result)}</b>`
      )
      .join('\n');

    if (isAfterRevert) {
      if (st.activeTurn) {
        st.history.push({
          id: st.activeTurn.id,
          createdAt: st.activeTurn.createdAt,
          finishedAt: this.nowProvider().toISOString(),
          prompt: st.activeTurn.prompt,
          commits: st.activeTurn.commits,
          revertCommits: st.activeTurn.revertCommits,
          builds: st.activeTurn.builds,
          rollbackBuilds: results,
          outcome: 'REVERTED_AND_REDEPLOYED'
        });
      }
      st.phase = 'IDLE';
      st.activeTurn = null;
      st.baselineSnapshots = null;
      st.pendingDeltas = [];
      st.lastError = null;
      await this.configStore.saveState();

      await this.telegram.sendMessage({
        chatId,
        text:
          `✅ <b>Rollback Jenkins Deploy Succeeded!</b>\n\n${buildSummary}\n\n` +
          `<b>${escapeHtml(wsLabel)}</b> is restored and ready for your next message!`,
        replyMarkup: MAIN_REPLY_KEYBOARD
      });
      return;
    }

    st.phase = 'AWAITING_OK_OR_REVERT';
    st.lastError = null;
    await this.configStore.saveState();

    const hasProd = this.hasWorkspaceProdJenkins(ws);
    const deployHeading = hasProd
      ? '✅ <b>Staging Jenkins Deploy Succeeded!</b>'
      : '✅ <b>Jenkins Deploy Succeeded!</b>';
    const liveLinkLine = ws.liveUrl ? `\n\n🌐 Live: ${escapeHtml(ws.liveUrl)}` : '';
    await this.sendIsItOkayPrompt(
      chatId,
      ws,
      `${deployHeading}\n\n${buildSummary}${liveLinkLine}`
    );
  }

  async sendJenkinsFailurePrompt(chatId, ws, failedBuild) {
    const logSnippet = truncateText(failedBuild?.errorLog || 'No console output available.', 2600);
    const jobTitle = failedBuild?.jobName
      ? `<code>${escapeHtml(failedBuild.jobName)}${failedBuild.buildNumber ? ` #${failedBuild.buildNumber}` : ''}</code> (${escapeHtml(failedBuild.result || 'FAILURE')})`
      : 'Build failed';

    await this.telegram.sendMessage({
      chatId,
      text:
        `❌ <b>Jenkins Build Failed:</b> ${jobTitle}\n\n` +
        `<b>Error Log:</b>\n<pre>${escapeHtml(logSnippet)}</pre>\n\n` +
        `<b>Revert commit or fix error with AI?</b>`,
      replyMarkup: {
        inline_keyboard: [
          [
            { text: '↩️ Revert', callback_data: `ok:rev:${ws.id}` },
            { text: '🔧 Fix Error', callback_data: `fix:err:${ws.id}` }
          ]
        ]
      }
    });
  }

  // ── STEP 4: Is It Okay? -> Yes (Prod / Skip Prod) / Revert ─────────────────
  async sendIsItOkayPrompt(chatId, ws, prefixHtml = '') {
    const st = this.configStore.getWorkspaceState(ws.id);
    const hasProd = this.hasWorkspaceProdJenkins(ws);
    const cleanPrefix = String(prefixHtml || '').trim();

    if (hasProd) {
      const prodTargets = this.resolveProdJenkinsTargets(ws, st);
      const prodSummary = prodTargets
        .map((t) => `${shortJenkinsJobLabel(t.jenkinsJob)} (${t.branch})`)
        .join(', ');
      const sections = [];
      if (cleanPrefix) sections.push(cleanPrefix);
      if (prodSummary) {
        sections.push(
          `🏁 Prod job${prodTargets.length === 1 ? '' : 's'}: <code>${escapeHtml(prodSummary)}</code>`
        );
      }
      sections.push('<b>Is it okay?</b>');

      await this.telegram.sendMessage({
        chatId,
        text: sections.join('\n\n'),
        replyMarkup: {
          inline_keyboard: [
            [{ text: '🚀 Yes, deploy on prod', callback_data: `ok:prod:${ws.id}` }],
            [
              { text: '✅ Yes (skip prod deploy)', callback_data: `ok:yes:${ws.id}` },
              { text: '↩️ Revert', callback_data: `ok:rev:${ws.id}` }
            ]
          ]
        }
      });
      return;
    }

    await this.telegram.sendMessage({
      chatId,
      text: cleanPrefix ? `${cleanPrefix}\n\n<b>Is it okay?</b>` : '<b>Is it okay?</b>',
      replyMarkup: {
        inline_keyboard: [
          [
            { text: '✅ Yes (Confirm)', callback_data: `ok:yes:${ws.id}` },
            { text: '↩️ Revert', callback_data: `ok:rev:${ws.id}` }
          ]
        ]
      }
    });
  }

  async handleOkConfirm(chatId, wsId) {
    const ws = this.getWorkspace(wsId);
    if (!ws) return;
    const wsLabel = this.getWorkspaceLabel(ws);
    const st = this.configStore.getWorkspaceState(ws.id);
    const hasProd = this.hasWorkspaceProdJenkins(ws);

    if (st.phase !== 'AWAITING_OK_OR_REVERT') {
      await this.sendCurrentWorkspaceGatePrompt(chatId, ws);
      return;
    }

    if (st.lastError && (!st.activeTurn?.prodBuilds || st.activeTurn.prodBuilds.length === 0)) {
      await this.sendJenkinsFailurePrompt(chatId, ws, st.activeTurn?.lastFailedBuild || {
        jobName: st.activeTurn?.lastFailedJob || '',
        buildNumber: st.activeTurn?.lastFailedBuildNumber,
        result: 'FAILURE',
        errorLog: st.lastError
      });
      return;
    }

    if (st.activeTurn) {
      st.history.push({
        id: st.activeTurn.id,
        createdAt: st.activeTurn.createdAt,
        finishedAt: this.nowProvider().toISOString(),
        prompt: st.activeTurn.prompt,
        commits: st.activeTurn.commits,
        builds: st.activeTurn.builds,
        outcome: hasProd ? 'CONFIRMED_SKIPPED_PROD' : 'CONFIRMED'
      });
    }

    st.phase = 'IDLE';
    st.activeTurn = null;
    st.baselineSnapshots = null;
    st.pendingDeltas = [];
    st.lastError = null;
    await this.configStore.saveState();

    await this.telegram.sendMessage({
      chatId,
      text:
        `✅ Confirmed changes in <b>${escapeHtml(wsLabel)}</b>${hasProd ? ' (skipped production deploy)' : ''}.\n\n` +
        `Ready for your next message!`,
      replyMarkup: MAIN_REPLY_KEYBOARD
    });
  }

  async handleOkDeployProd(chatId, wsId) {
    const ws = this.getWorkspace(wsId);
    if (!ws) return;
    const wsLabel = this.getWorkspaceLabel(ws);
    const st = this.configStore.getWorkspaceState(ws.id);

    if (st.phase !== 'AWAITING_OK_OR_REVERT') {
      await this.sendCurrentWorkspaceGatePrompt(chatId, ws);
      return;
    }

    const prodTargets = this.resolveProdJenkinsTargets(ws, st);
    if (prodTargets.length === 0) {
      await this.handleOkConfirm(chatId, wsId);
      return;
    }

    if (st.activeTurn) {
      st.activeTurn.prodDeployedTargets = prodTargets;
    }

    st.phase = 'RUNNING_PROD_JENKINS';
    st.lastError = null;
    await this.configStore.saveState();

    const jobNames = prodTargets.map((d) => `${d.jenkinsJob} (${d.branch})`).join(', ');
    const progressMsg = await this.telegram.sendMessage({
      chatId,
      text:
        `🚀 <b>Triggered Production Jenkins deploy…</b>\n` +
        `<b>${escapeHtml(wsLabel)}</b>\n\n` +
        `<code>${escapeHtml(jobNames)}</code>`
    });

    this.#trackAsync(
      this.#executeProdJenkinsBuilds(
        chatId,
        ws,
        st,
        prodTargets,
        progressMsg?.message_id
      ).catch(async (err) => {
        st.phase = 'AWAITING_OK_OR_REVERT';
        st.lastError = err.message;
        await this.configStore.saveState();
        await this.telegram.sendMessage({
          chatId,
          text: `❌ Production Jenkins unexpected error: ${escapeHtml(err.message)}`
        });
      })
    );
  }

  async #executeProdJenkinsBuilds(chatId, ws, st, prodTargets, progressMsgId) {
    const wsLabel = this.getWorkspaceLabel(ws);
    const jenkins = this.jenkinsFactory(this.configStore.config.jenkins);
    const results = [];
    let failedBuild = null;

    for (const target of prodTargets) {
      let lastEditMs = 0;
      try {
        const res = await jenkins.triggerAndWaitForBuild({
          jobName: target.jenkinsJob,
          branch: target.branch,
          onUpdate: (upd) => {
            const nowMs = Date.now();
            if (progressMsgId && nowMs - lastEditMs > 3000) {
              lastEditMs = nowMs;
              this.telegram
                .editMessageText({
                  chatId,
                  messageId: progressMsgId,
                  text:
                    `🚀 <b>Production Jenkins running…</b>\n` +
                    `<b>${escapeHtml(wsLabel)}</b>\n\n` +
                    `<code>${escapeHtml(upd.message || `${target.jenkinsJob}: ${upd.status}`)}</code>`
                })
                .catch(() => {});
            }
          }
        });

        results.push(res);
        if (res.result !== 'SUCCESS' && res.result !== 'TRIGGERED') {
          failedBuild = {
            jobName: target.jenkinsJob,
            branch: target.branch,
            buildNumber: res.buildNumber,
            buildUrl: res.buildUrl,
            result: res.result,
            errorLog: res.consoleTail || `Jenkins ended with status ${res.result}`
          };
          break;
        }
      } catch (err) {
        failedBuild = {
          jobName: target.jenkinsJob,
          branch: target.branch,
          buildNumber: null,
          buildUrl: '',
          result: 'ERROR',
          errorLog: err.message
        };
        break;
      }
    }

    if (st.activeTurn) {
      st.activeTurn.prodBuilds = results;
    }

    if (failedBuild) {
      const logSnippet = truncateText(failedBuild.errorLog || 'No console output available.', 2600);
      st.phase = 'AWAITING_OK_OR_REVERT';
      st.lastError = failedBuild.errorLog;
      await this.configStore.saveState();

      await this.telegram.sendMessage({
        chatId,
        text:
          `❌ <b>Production Jenkins Build Failed:</b> <code>${escapeHtml(failedBuild.jobName)}${failedBuild.buildNumber ? ` #${failedBuild.buildNumber}` : ''}</code> (${escapeHtml(failedBuild.result)})\n\n` +
          `<b>Error Log:</b>\n<pre>${escapeHtml(logSnippet)}</pre>\n\n` +
          `<b>Retry production deploy, skip prod, or revert commit?</b>`,
        replyMarkup: {
          inline_keyboard: [
            [{ text: '🔄 Retry Prod Deploy', callback_data: `ok:prod:${ws.id}` }],
            [
              { text: '✅ Yes (skip prod deploy)', callback_data: `ok:yes:${ws.id}` },
              { text: '↩️ Revert', callback_data: `ok:rev:${ws.id}` }
            ]
          ]
        }
      });
      return;
    }

    const buildSummary = results
      .map(
        (r) =>
          `• <code>${escapeHtml(r.jobName)}${r.buildNumber ? ` #${r.buildNumber}` : ''}</code>: <b>${escapeHtml(r.result)}</b>`
      )
      .join('\n');

    if (st.activeTurn) {
      st.history.push({
        id: st.activeTurn.id,
        createdAt: st.activeTurn.createdAt,
        finishedAt: this.nowProvider().toISOString(),
        prompt: st.activeTurn.prompt,
        commits: st.activeTurn.commits,
        builds: st.activeTurn.builds,
        prodBuilds: results,
        outcome: 'CONFIRMED_PROD_DEPLOYED'
      });
    }

    st.phase = 'IDLE';
    st.activeTurn = null;
    st.baselineSnapshots = null;
    st.pendingDeltas = [];
    st.lastError = null;
    await this.configStore.saveState();

    await this.telegram.sendMessage({
      chatId,
      text:
        `✅ <b>Production Jenkins Deploy Succeeded!</b>\n\n${buildSummary}\n\n` +
        `Confirmed &amp; deployed to production in <b>${escapeHtml(wsLabel)}</b>.\n\nReady for your next message!`,
      replyMarkup: MAIN_REPLY_KEYBOARD
    });
  }

  async handleRevertBadCommit(chatId, wsId) {
    const ws = this.getWorkspace(wsId);
    if (!ws) return;
    const wsLabel = this.getWorkspaceLabel(ws);
    const st = this.configStore.getWorkspaceState(ws.id);

    const commits = st.activeTurn?.commits || [];
    if (commits.length === 0) {
      st.phase = 'IDLE';
      st.activeTurn = null;
      await this.configStore.saveState();
      await this.telegram.sendMessage({
        chatId,
        text: 'ℹ️ No commits found to revert.'
      });
      return;
    }

    try {
      const reverted = await revertAndPushTurnCommits(commits, { push: this.gitPush });
      st.activeTurn.revertCommits = reverted;
      st.lastError = null;

      const revLines = reverted.map(
        (r) =>
          `• <code>${escapeHtml(r.repoName)}</code>: reverted bad commit <code>${escapeHtml(r.originalCommitSha.slice(0, 7))}</code> → revert commit <code>${escapeHtml(r.revertShortSha)}</code>${r.pushed ? ` pushed to <code>origin/${escapeHtml(r.branch)}</code>` : ''}`
      );

      // Output revert action explicitly via message text!
      await this.telegram.sendMessage({
        chatId,
        text: `↩️ <b>Reverted last commit(s) as bad</b>\n\n${revLines.join('\n')}`
      });

      const matchedRevTargets = this.resolveMatchedJenkinsTargets(ws, st, { isAfterRevert: true });
      const allWsRevTargets = this.buildAllWorkspaceTargets(ws, reverted);
      if (matchedRevTargets.length === 0 && allWsRevTargets.length === 0) {
        st.history.push({
          id: st.activeTurn.id,
          createdAt: st.activeTurn.createdAt,
          finishedAt: this.nowProvider().toISOString(),
          prompt: st.activeTurn.prompt,
          commits: st.activeTurn.commits,
          revertCommits: reverted,
          outcome: 'REVERTED'
        });
        st.phase = 'IDLE';
        st.activeTurn = null;
        st.baselineSnapshots = null;
        await this.configStore.saveState();

        await this.telegram.sendMessage({
          chatId,
          text: `✅ Revert complete (no Jenkins job mapped).\n\nReady for your next message in <b>${escapeHtml(wsLabel)}</b>!`,
          replyMarkup: MAIN_REPLY_KEYBOARD
        });
        return;
      }

      // Automatically trigger rollback Jenkins deploy without asking intermediate confirmation
      await this.handleRunJenkinsChoice(chatId, ws.id, true, {
        isAfterRevert: true,
        mode: matchedRevTargets.length > 0 ? 'matched' : 'all'
      });
    } catch (revErr) {
      st.lastError = revErr.message;
      await this.configStore.saveState();
      await this.telegram.sendMessage({
        chatId,
        text: `❌ <b>Git revert error:</b>\n<code>${escapeHtml(revErr.message)}</code>`,
        replyMarkup: {
          inline_keyboard: [[{ text: '🔄 Retry Revert', callback_data: `ok:rev:${ws.id}` }]]
        }
      });
    }
  }

  async handleFixJenkinsError(chatId, wsId) {
    const ws = this.getWorkspace(wsId);
    if (!ws) return;
    const wsLabel = this.getWorkspaceLabel(ws);
    const st = this.configStore.getWorkspaceState(ws.id);

    if (st.phase !== 'AWAITING_OK_OR_REVERT') {
      await this.sendCurrentWorkspaceGatePrompt(chatId, ws);
      return;
    }

    const errorLog =
      st.lastError || st.activeTurn?.lastFailedBuild?.errorLog || 'Jenkins build failed';
    const failedJob = st.activeTurn?.lastFailedJob || '';
    const failedBuildNumber = st.activeTurn?.lastFailedBuildNumber;
    const failedJobStr = failedJob
      ? `${failedJob}${failedBuildNumber ? ` #${failedBuildNumber}` : ''}`
      : 'Jenkins build';

    const fixPrompt =
      `The Jenkins CI build failed with the following error log:\n\n` +
      `Job: ${failedJobStr}\n` +
      `Error:\n` +
      `\`\`\`\n${errorLog}\n\`\`\`\n\n` +
      `Please investigate the error log above, identify the bug or missing/mismatched type/dependency/syntax/configuration, and fix the codebase to resolve this build error.`;

    const baselineSnapshots = await snapshotWorkspaceRepos(ws.repos || []);
    st.baselineSnapshots = baselineSnapshots;
    st.phase = 'RUNNING_AGENT';
    st.lastError = null;

    if (!st.activeTurn) {
      st.activeTurn = {
        id: `turn_${Date.now()}`,
        createdAt: this.nowProvider().toISOString(),
        prompt: fixPrompt,
        commits: []
      };
    } else {
      st.activeTurn.fixPrompt = fixPrompt;
    }
    await this.configStore.saveState();

    const statusMsg = await this.telegram.sendMessage({
      chatId,
      text:
        `🔧 <b>Fixing Jenkins build error with AI…</b>\n` +
        `<b>${escapeHtml(wsLabel)}</b>\n\n` +
        `<i>Analyzing failure log and applying fixes…</i>`,
      replyMarkup: {
        inline_keyboard: [[{ text: '🛑 Stop Agent', callback_data: `agent:stop:${ws.id}` }]]
      }
    });

    this.#trackAsync(
      this.#executeAgentTurn(chatId, ws, st, [], statusMsg?.message_id, {
        promptOverride: fixPrompt,
        isAutoCommitFix: true,
        originalErrorLog: errorLog
      }).catch(async (err) => {
        st.phase = 'AWAITING_OK_OR_REVERT';
        st.lastError = err.message;
        await this.configStore.saveState();
        await this.telegram.sendMessage({
          chatId,
          text: `❌ Error fixing Jenkins error with agent: ${escapeHtml(err.message)}`
        });
        await this.sendJenkinsFailurePrompt(chatId, ws, {
          jobName: failedJob,
          buildNumber: failedBuildNumber,
          result: 'ERROR',
          errorLog: err.message
        });
      })
    );
  }

  /**
   * Re-sends the active decision prompt for `ws` (used when switching back to an IDE with a pending step).
   */
  async sendCurrentWorkspaceGatePrompt(chatId, ws, bannerHtml = '') {
    const wsLabel = this.getWorkspaceLabel(ws);
    const st = this.configStore.getWorkspaceState(ws.id);
    const prefix = bannerHtml ? `${bannerHtml}\n\n` : '';

    switch (st.phase) {
      case 'RUNNING_AGENT':
        await this.telegram.sendMessage({
          chatId,
          text: `${prefix}⏳ Antigravity agent is currently running in <b>${escapeHtml(wsLabel)}</b>.`,
          replyMarkup: {
            inline_keyboard: [[{ text: '🛑 Stop Agent', callback_data: `agent:stop:${ws.id}` }]]
          }
        });
        break;
      case 'AWAITING_COMMIT_CHOICE':
        if (bannerHtml) {
          await this.telegram.sendMessage({ chatId, text: bannerHtml });
        }
        await this.sendCommitPrompt(chatId, ws, st.pendingDeltas || []);
        break;
      case 'AWAITING_CUSTOM_BRANCH':
        await this.telegram.sendMessage({
          chatId,
          text: `${prefix}🌿 Reply with the custom branch name for <b>${escapeHtml(wsLabel)}</b>:`,
          replyMarkup: {
            inline_keyboard: [[{ text: '↩️ Back to Commit Options', callback_data: `cmt:back:${ws.id}` }]]
          }
        });
        break;
      case 'AWAITING_FIX_PROMPT':
        await this.telegram.sendMessage({
          chatId,
          text: `${prefix}➕ Reply with what to fix or modify in <b>${escapeHtml(wsLabel)}</b>:`,
          replyMarkup: {
            inline_keyboard: [[{ text: '↩️ Back to Commit Options', callback_data: `cmt:back:${ws.id}` }]]
          }
        });
        break;
      case 'AWAITING_JENKINS_CHOICE': {
        if (bannerHtml) {
          await this.telegram.sendMessage({ chatId, text: bannerHtml });
        }
        const targets = this.resolveMatchedJenkinsTargets(ws, st, { isAfterRevert: false });
        await this.sendRunJenkinsPrompt(chatId, ws, targets, { isAfterRevert: false });
        break;
      }
      case 'RUNNING_JENKINS':
      case 'RUNNING_REVERT_JENKINS':
        await this.telegram.sendMessage({
          chatId,
          text: `${prefix}⏳ Jenkins deployment is currently running for <b>${escapeHtml(wsLabel)}</b>.`
        });
        break;
      case 'RUNNING_PROD_JENKINS':
        await this.telegram.sendMessage({
          chatId,
          text: `${prefix}⏳ Production Jenkins deployment is currently running for <b>${escapeHtml(wsLabel)}</b>.`
        });
        break;
      case 'AWAITING_OK_OR_REVERT':
        if (st.lastError && (!st.activeTurn?.prodBuilds || st.activeTurn.prodBuilds.length === 0)) {
          await this.sendJenkinsFailurePrompt(chatId, ws, st.activeTurn?.lastFailedBuild || {
            jobName: st.activeTurn?.lastFailedJob || '',
            buildNumber: st.activeTurn?.lastFailedBuildNumber,
            result: 'FAILURE',
            errorLog: st.lastError
          });
        } else {
          await this.sendIsItOkayPrompt(chatId, ws, bannerHtml);
        }
        break;
      case 'AWAITING_REVERT_JENKINS_CHOICE': {
        if (bannerHtml) {
          await this.telegram.sendMessage({ chatId, text: bannerHtml });
        }
        const revTargets = this.resolveMatchedJenkinsTargets(ws, st, { isAfterRevert: true });
        await this.sendRunJenkinsPrompt(chatId, ws, revTargets, { isAfterRevert: true });
        break;
      }
      default:
        break;
    }
  }
}
