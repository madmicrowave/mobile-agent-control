import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import os from 'node:os';
import { resolveDefaultAgyBin } from './agy-runner.mjs';

export const INITIAL_WORKSPACES_SEED = [];

/**
 * Expands leading `~` and strips surrounding quotes (e.g. when dragging folders into Terminal).
 */
export function expandUserPath(rawInput) {
  let cleaned = String(rawInput || '').trim();
  if (
    (cleaned.startsWith('"') && cleaned.endsWith('"')) ||
    (cleaned.startsWith("'") && cleaned.endsWith("'"))
  ) {
    cleaned = cleaned.slice(1, -1).trim();
  }
  if (!cleaned) return '';
  if (cleaned === '~') return os.homedir();
  if (cleaned.startsWith('~/') || cleaned.startsWith('~\\')) {
    return path.resolve(os.homedir(), cleaned.slice(2));
  }
  return path.resolve(cleaned);
}

/**
 * Returns candidate parent directories to scan when suggesting unregistered workspaces.
 */
export function getCandidateScanRoots(configuredWorkspaces = []) {
  const home = os.homedir();
  const roots = new Set();

  for (const ws of configuredWorkspaces || []) {
    if (ws?.path) {
      roots.add(path.dirname(path.resolve(ws.path)));
    }
  }

  for (const rel of ['code', 'projects', 'workspace', 'workspaces', 'dev', 'src']) {
    roots.add(path.join(home, rel));
  }

  return [...roots];
}

/**
 * Returns local calendar date formatted as `YYYY-MM-DD` for daily password expiration.
 */
export function getLocalDateKey(date = new Date()) {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, '0');
  const d = String(date.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

/**
 * Extracts `def name = 'foo'` or `name = 'foo'` from a Jenkinsfile if present.
 */
export function parseJenkinsfileJobName(jenkinsfileContent) {
  if (!jenkinsfileContent) return null;
  const match = jenkinsfileContent.match(/^\s*(?:def\s+)?name\s*=\s*['"]([^'"]+)['"]/m);
  return match ? match[1].trim() : null;
}

/**
 * Scans a workspace directory to discover git repositories (either the root itself
 * or immediate child directories) and extracts default Jenkins job names from Jenkinsfiles.
 */
export async function discoverWorkspaceRepos(
  workspacePath,
  existingRepoOverrides = {},
  presetRepoJobs = null
) {
  const resolvedRoot = expandUserPath(workspacePath);
  const repos = [];

  async function inspectCandidate(repoDir, relName) {
    const gitMarker = path.join(repoDir, '.git');
    try {
      await fsp.access(gitMarker);
    } catch {
      return;
    }

    let detectedJob = null;
    const jenkinsfilePath = path.join(repoDir, 'Jenkinsfile');
    try {
      const content = await fsp.readFile(jenkinsfilePath, 'utf8');
      detectedJob = parseJenkinsfileJobName(content);
    } catch {
      // Shared library or repo without Jenkinsfile
    }

    const prev = existingRepoOverrides[relName] || {};

    let jenkinsJob;
    let deployEnabled;

    if (presetRepoJobs && Object.prototype.hasOwnProperty.call(presetRepoJobs, relName)) {
      jenkinsJob = prev.jenkinsJob || presetRepoJobs[relName] || '';
      deployEnabled =
        prev.deployEnabled !== undefined ? Boolean(prev.deployEnabled) : Boolean(jenkinsJob);
    } else {
      jenkinsJob = prev.jenkinsJob !== undefined ? prev.jenkinsJob : (detectedJob || '');
      deployEnabled =
        prev.deployEnabled !== undefined
          ? Boolean(prev.deployEnabled)
          : Boolean(detectedJob || prev.jenkinsJob);
    }

    repos.push({
      name: relName,
      path: prev.path ? expandUserPath(prev.path) : repoDir,
      jenkinsJob,
      branch: prev.branch || '',
      deployEnabled
    });
  }

  await inspectCandidate(resolvedRoot, path.basename(resolvedRoot));

  try {
    const entries = await fsp.readdir(resolvedRoot, { withFileTypes: true });
    const sorted = entries
      .filter((e) => e.isDirectory() && !e.name.startsWith('.'))
      .sort((a, b) => a.name.localeCompare(b.name));

    for (const entry of sorted) {
      await inspectCandidate(path.join(resolvedRoot, entry.name), entry.name);
    }
  } catch {
    // Ignore missing directory in synthetic tests
  }

  return repos;
}

/**
 * Scans parent directories to suggest candidate IDE workspaces in Telegram.
 */
export async function scanCandidateWorkspaces(
  roots = getCandidateScanRoots(),
  alreadyConfiguredPaths = new Set()
) {
  const candidates = [];
  const seen = new Set([...alreadyConfiguredPaths].map((p) => path.resolve(p)));

  for (const root of roots) {
    let entries;
    try {
      entries = await fsp.readdir(root, { withFileTypes: true });
    } catch {
      continue;
    }

    for (const entry of entries) {
      if (!entry.isDirectory() || entry.name.startsWith('.')) continue;
      const fullPath = path.resolve(root, entry.name);
      if (seen.has(fullPath)) continue;

      const repos = await discoverWorkspaceRepos(fullPath);
      if (repos.length > 0) {
        seen.add(fullPath);
        candidates.push({
          name: entry.name,
          path: fullPath,
          repoCount: repos.length,
          jenkinsJobs: repos.filter((r) => r.jenkinsJob).map((r) => r.jenkinsJob)
        });
      }
    }
  }

  return candidates.sort((a, b) => a.name.localeCompare(b.name));
}

export function slugifyWorkspaceId(name) {
  const base = String(name || 'workspace')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
  return base || `ws-${crypto.randomBytes(3).toString('hex')}`;
}

function parseAllowedUserIds(raw) {
  if (!raw) return [];
  if (Array.isArray(raw)) {
    return raw.map((v) => String(v).trim()).filter(Boolean);
  }
  return String(raw)
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
}

export class ConfigStore {
  constructor(dataDir) {
    this.dataDir = dataDir;
    this.uploadsDir = path.join(dataDir, 'uploads');
    this.configFile = path.join(dataDir, 'config.json');
    this.stateFile = path.join(dataDir, 'state.json');
    this.config = null;
    this.state = null;
    this.lastConfigMtimeMs = 0;
    this.runSessionId = crypto.randomUUID();
    this.runtimePassword = '';
  }

  setRuntimePassword(password) {
    const cleaned = String(password || '').trim();
    if (!cleaned) {
      throw new Error('Session password cannot be empty');
    }
    this.runtimePassword = cleaned;
    this.runSessionId = crypto.randomUUID();
  }

  #normalizeConfigShape() {
    const defaultBrainDir = path.join(os.homedir(), '.gemini', 'antigravity', 'brain');

    // Password is entered fresh on every `npm start` run and never stored on disk
    delete this.config.password;
    delete this.config.pin;
    delete this.config.sessionSecret;

    if (process.env.TELEGRAM_BOT_TOKEN) {
      this.config.telegramBotToken = process.env.TELEGRAM_BOT_TOKEN.trim();
    } else if (typeof this.config.telegramBotToken !== 'string') {
      this.config.telegramBotToken = '';
    }
    if (process.env.TELEGRAM_API_BASE_URL) {
      this.config.telegramApiBaseUrl = process.env.TELEGRAM_API_BASE_URL.trim();
    } else if (!this.config.telegramApiBaseUrl) {
      this.config.telegramApiBaseUrl = 'https://api.telegram.org';
    }
    if (process.env.ALLOWED_TELEGRAM_USER_IDS) {
      this.config.allowedUserIds = parseAllowedUserIds(process.env.ALLOWED_TELEGRAM_USER_IDS);
    } else if (!Array.isArray(this.config.allowedUserIds)) {
      this.config.allowedUserIds = [];
    }
    if (!this.config.defaultHistoryCount) {
      this.config.defaultHistoryCount = Number(process.env.DEFAULT_HISTORY_COUNT || 6) || 6;
    }
    if (!this.config.agyBin) {
      this.config.agyBin = process.env.AGY_BIN || resolveDefaultAgyBin();
    }
    if (!this.config.antigravityBrainDir) {
      this.config.antigravityBrainDir = process.env.ANTIGRAVITY_BRAIN_DIR || defaultBrainDir;
    }
    if (typeof this.config.defaultModel !== 'string') {
      this.config.defaultModel = process.env.DEFAULT_AGENT_MODEL || '';
    }
    if (typeof this.config.defaultModelLevel !== 'string') {
      this.config.defaultModelLevel = process.env.DEFAULT_AGENT_MODEL_LEVEL || '';
    }
    if (this.config.defaultModelLevel) {
      const normDefaultLvl = this.config.defaultModelLevel.trim().toLowerCase();
      this.config.defaultModelLevel = ['low', 'medium', 'high'].includes(normDefaultLvl)
        ? normDefaultLvl
        : 'high';
    }
    if (this.config.skipPermissions === undefined) {
      this.config.skipPermissions = true;
    }
    if (!this.config.jenkins) {
      this.config.jenkins = {
        baseUrl: '',
        username: '',
        apiToken: '',
        jobPrefix: '',
        insecureTls: false,
        pollIntervalMs: 3000,
        buildTimeoutMs: 25 * 60 * 1000
      };
    }
    if (process.env.JENKINS_BASE_URL && !this.config.jenkins.baseUrl) {
      this.config.jenkins.baseUrl = process.env.JENKINS_BASE_URL.trim();
    }
    if (process.env.JENKINS_USER && !this.config.jenkins.username) {
      this.config.jenkins.username = process.env.JENKINS_USER.trim();
    }
    if (process.env.JENKINS_API_TOKEN && !this.config.jenkins.apiToken) {
      this.config.jenkins.apiToken = process.env.JENKINS_API_TOKEN.trim();
    }
    if (
      process.env.JENKINS_JOB_PREFIX !== undefined &&
      process.env.JENKINS_JOB_PREFIX !== '' &&
      !this.config.jenkins.jobPrefix
    ) {
      this.config.jenkins.jobPrefix = process.env.JENKINS_JOB_PREFIX.trim();
    }
    if (!Array.isArray(this.config.workspaces)) {
      this.config.workspaces = [];
    }

    for (const ws of this.config.workspaces) {
      const fallbackSlug = slugifyWorkspaceId(
        ws.label || ws.name || path.basename(String(ws.path || 'workspace'))
      );
      ws.id = String(ws.id || fallbackSlug).trim();
      ws.label = String(ws.label || ws.name || ws.id).trim();
      delete ws.name;

      if (!Array.isArray(ws.jenkinsJobs)) {
        ws.jenkinsJobs = [];
      }
      if (!Array.isArray(ws.extraDirs)) {
        ws.extraDirs = [];
      }
      if (typeof ws.model !== 'string') {
        ws.model = '';
      }
      if (typeof ws.modelLevel !== 'string') {
        ws.modelLevel = '';
      } else if (ws.modelLevel.trim()) {
        const normLvl = ws.modelLevel.trim().toLowerCase();
        ws.modelLevel = ['low', 'medium', 'high'].includes(normLvl) ? normLvl : 'high';
      }
      if (!Array.isArray(ws.repos)) {
        ws.repos = [];
      }
    }
  }

  async init({ seedWorkspaces = INITIAL_WORKSPACES_SEED } = {}) {
    await fsp.mkdir(this.dataDir, { recursive: true, mode: 0o700 });
    await fsp.mkdir(this.uploadsDir, { recursive: true, mode: 0o700 });

    try {
      const raw = await fsp.readFile(this.configFile, 'utf8');
      this.config = JSON.parse(raw);
    } catch {
      this.config = null;
    }

    const defaultBrainDir = path.join(os.homedir(), '.gemini', 'antigravity', 'brain');

    if (!this.config) {
      this.config = {
        telegramBotToken: process.env.TELEGRAM_BOT_TOKEN || '',
        telegramApiBaseUrl: process.env.TELEGRAM_API_BASE_URL || 'https://api.telegram.org',
        allowedUserIds: parseAllowedUserIds(process.env.ALLOWED_TELEGRAM_USER_IDS),
        defaultHistoryCount: Number(process.env.DEFAULT_HISTORY_COUNT || 6) || 6,
        agyBin: process.env.AGY_BIN || resolveDefaultAgyBin(),
        antigravityBrainDir: process.env.ANTIGRAVITY_BRAIN_DIR || defaultBrainDir,
        defaultModel: process.env.DEFAULT_AGENT_MODEL || 'gemini-3.8-flash',
        defaultModelLevel: process.env.DEFAULT_AGENT_MODEL_LEVEL || 'high',
        skipPermissions: true,
        jenkins: {
          baseUrl: process.env.JENKINS_BASE_URL || '',
          username: process.env.JENKINS_USER || '',
          apiToken: process.env.JENKINS_API_TOKEN || '',
          jobPrefix: process.env.JENKINS_JOB_PREFIX || '',
          insecureTls: false,
          pollIntervalMs: 3000,
          buildTimeoutMs: 25 * 60 * 1000
        },
        workspaces: []
      };

      for (const seed of seedWorkspaces) {
        if (fs.existsSync(seed.path)) {
          const repos = await discoverWorkspaceRepos(seed.path, {}, seed.repoJobs || null);
          const wsId =
            seed.id || slugifyWorkspaceId(seed.label || seed.name || path.basename(seed.path));
          const wsLabel = String(seed.label || seed.name || wsId).trim();
          this.config.workspaces.push({
            id: wsId,
            label: wsLabel,
            path: seed.path,
            extraDirs: seed.extraDirs || [],
            liveUrl: seed.liveUrl || '',
            jenkinsJobs: seed.jenkinsJobs ? [...seed.jenkinsJobs] : [],
            model: seed.model || '',
            modelLevel: seed.modelLevel || '',
            repos
          });
        }
      }
    } else {
      this.#normalizeConfigShape();
    }

    for (const ws of this.config.workspaces) {
      if (ws.repos.length === 0 && ws.path && fs.existsSync(ws.path)) {
        ws.repos = await discoverWorkspaceRepos(ws.path);
      }
    }
    await this.saveConfig();

    try {
      const rawState = await fsp.readFile(this.stateFile, 'utf8');
      this.state = JSON.parse(rawState);
    } catch {
      this.state = null;
    }

    if (!this.state || typeof this.state !== 'object') {
      this.state = {
        telegramOffset: 0,
        userSessions: {},
        workspaces: {}
      };
    }
    this.state.telegramOffset = Number(this.state.telegramOffset || 0);
    this.state.userSessions = this.state.userSessions || {};
    this.state.workspaces = this.state.workspaces || {};

    // Every new application run requires re-authenticating with the new startup password
    for (const [, sess] of Object.entries(this.state.userSessions)) {
      if (sess && typeof sess === 'object') {
        sess.unlockedRunId = null;
        sess.inputMode = null;
        sess.inputTargetWsId = null;
        delete sess.unlockedDate;
        delete sess.historyCount;
      }
    }

    // Recover any transient running states if bot restarted mid-operation
    for (const [, wsState] of Object.entries(this.state.workspaces)) {
      if (wsState.phase === 'RUNNING_AGENT') {
        wsState.phase = 'IDLE';
        wsState.activeTurn = null;
        wsState.lastError = 'Previous agent run was interrupted by bot restart.';
      } else if (wsState.phase === 'RUNNING_JENKINS') {
        wsState.phase = 'AWAITING_JENKINS_CHOICE';
        wsState.lastError = 'Bot restarted during Jenkins build. Choose whether to re-run Jenkins.';
      } else if (wsState.phase === 'RUNNING_REVERT_JENKINS') {
        wsState.phase = 'AWAITING_REVERT_JENKINS_CHOICE';
        wsState.lastError = 'Bot restarted during rollback Jenkins build. Choose whether to re-run Jenkins.';
      } else if (wsState.phase === 'AWAITING_DECISION') {
        wsState.phase = 'AWAITING_OK_OR_REVERT';
      }
    }
    await this.saveState();
  }

  /**
   * Hot-reloads `config.json` from disk if modified externally (e.g. via `npm run setup` or manual edits),
   * so background service updates take effect immediately without restarting.
   */
  async reloadConfigIfChanged() {
    try {
      const stat = await fsp.stat(this.configFile);
      if (stat.mtimeMs > this.lastConfigMtimeMs) {
        const raw = await fsp.readFile(this.configFile, 'utf8');
        const parsed = JSON.parse(raw);
        if (parsed && typeof parsed === 'object') {
          this.config = parsed;
          this.#normalizeConfigShape();
          this.lastConfigMtimeMs = stat.mtimeMs;
          return true;
        }
      }
    } catch {
      // Ignore transient write/rename races
    }
    return false;
  }

  async saveConfig() {
    const tmp = `${this.configFile}.tmp`;
    await fsp.writeFile(tmp, JSON.stringify(this.config, null, 2), { mode: 0o600 });
    await fsp.rename(tmp, this.configFile);
    try {
      const stat = await fsp.stat(this.configFile);
      this.lastConfigMtimeMs = stat.mtimeMs;
    } catch {
      // ignore
    }
  }

  async saveState() {
    const tmp = `${this.stateFile}.tmp`;
    await fsp.writeFile(tmp, JSON.stringify(this.state, null, 2), { mode: 0o600 });
    await fsp.rename(tmp, this.stateFile);
  }

  getWorkspaceState(workspaceId) {
    if (!this.state.workspaces[workspaceId]) {
      this.state.workspaces[workspaceId] = {
        phase: 'SELECT_CHAT',
        conversationId: null,
        continueLatest: false,
        pendingPhotos: [],
        baselineSnapshots: null,
        pendingDeltas: [],
        activeTurn: null,
        lastError: null,
        messages: [],
        history: []
      };
    }
    const st = this.state.workspaces[workspaceId];
    st.pendingPhotos = st.pendingPhotos || [];
    st.pendingDeltas = st.pendingDeltas || [];
    st.messages = st.messages || [];
    st.history = st.history || [];
    return st;
  }

  getUserSession(telegramUserId) {
    const key = String(telegramUserId);
    if (!this.state.userSessions[key]) {
      this.state.userSessions[key] = {
        unlockedRunId: null,
        unlockedAt: null,
        selectedWorkspaceId: null,
        inputMode: null,
        inputTargetWsId: null
      };
    }
    const sess = this.state.userSessions[key];
    delete sess.unlockedDate;
    delete sess.historyCount;
    return sess;
  }

  isUserAllowed(telegramUserId) {
    const allowlist = this.config.allowedUserIds || [];
    if (allowlist.length === 0) return true;
    return allowlist.includes(String(telegramUserId));
  }

  isUserUnlocked(telegramUserId) {
    if (!this.runtimePassword) return false;
    const sess = this.getUserSession(telegramUserId);
    return sess.unlockedRunId === this.runSessionId;
  }

  unlockUser(telegramUserId, now = new Date()) {
    const sess = this.getUserSession(telegramUserId);
    sess.unlockedRunId = this.runSessionId;
    sess.unlockedAt = now.toISOString();
  }

  lockUser(telegramUserId) {
    const sess = this.getUserSession(telegramUserId);
    sess.unlockedRunId = null;
    sess.inputMode = null;
    sess.inputTargetWsId = null;
  }

  verifyPassword(candidate) {
    const expected = Buffer.from(String(this.runtimePassword || ''), 'utf8');
    const actual = Buffer.from(String(candidate || ''), 'utf8');
    if (expected.length === 0 || expected.length !== actual.length) return false;
    return crypto.timingSafeEqual(expected, actual);
  }
}
