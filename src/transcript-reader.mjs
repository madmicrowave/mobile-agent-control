import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

/**
 * Strips Antigravity IDE XML metadata wrappers and bot controller suffixes from a USER_INPUT step.
 */
export function cleanUserPromptText(rawContent) {
  let text = String(rawContent || '');

  const reqMatch = text.match(/<USER_REQUEST>\s*([\s\S]*?)\s*<\/USER_REQUEST>/i);
  if (reqMatch) {
    text = reqMatch[1];
  } else {
    text = text
      .replace(/<ADDITIONAL_METADATA>[\s\S]*?<\/ADDITIONAL_METADATA>/gi, '')
      .replace(/<USER_SETTINGS_CHANGE>[\s\S]*?<\/USER_SETTINGS_CHANGE>/gi, '');
  }

  text = text
    .replace(/\[(?:Telegram|Mobile) Controller Instruction:[\s\S]*?\]\s*$/i, '')
    .replace(/\[Attached User Photo\(s\)[\s\S]*?\]\s*$/i, '')
    .trim();

  return text;
}

/**
 * Parses `<brainDir>/<conversationId>/.system_generated/logs/transcript.jsonl` into
 * `{ role: 'user' | 'assistant', text, createdAt }[]`.
 */
export async function readTranscriptMessages(brainDir, conversationId) {
  if (!brainDir || !conversationId) return [];
  const transcriptPath = path.join(
    brainDir,
    conversationId,
    '.system_generated',
    'logs',
    'transcript.jsonl'
  );

  let raw;
  try {
    raw = await fsp.readFile(transcriptPath, 'utf8');
  } catch {
    return [];
  }

  const messages = [];
  for (const line of raw.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    let step;
    try {
      step = JSON.parse(trimmed);
    } catch {
      continue;
    }

    if (step.type === 'USER_INPUT' && typeof step.content === 'string') {
      const cleaned = cleanUserPromptText(step.content);
      if (cleaned) {
        messages.push({
          role: 'user',
          text: cleaned,
          createdAt: step.created_at || null
        });
      }
    } else if (
      step.type === 'PLANNER_RESPONSE' &&
      typeof step.content === 'string' &&
      step.content.trim().length > 0
    ) {
      messages.push({
        role: 'assistant',
        text: step.content.trim(),
        createdAt: step.created_at || null
      });
    }
  }

  return messages;
}

/**
 * Returns the latest `limit` messages for `conversationId`, combining `transcript.jsonl`
 * (if present on disk) with any locally cached bot messages as fallback.
 */
export async function getLatestConversationMessages({
  brainDir,
  conversationId,
  fallbackMessages = [],
  limit = 6
}) {
  const safeLimit = Math.max(1, Math.min(50, Number(limit) || 6));
  const fromTranscript = await readTranscriptMessages(brainDir, conversationId);

  if (fromTranscript.length > 0) {
    return {
      total: fromTranscript.length,
      messages: fromTranscript.slice(-safeLimit)
    };
  }

  const filtered = conversationId
    ? fallbackMessages.filter((m) => !m.conversationId || m.conversationId === conversationId)
    : fallbackMessages;

  return {
    total: filtered.length,
    messages: filtered.slice(-safeLimit)
  };
}

/**
 * Discovers recent Antigravity conversations in `<brainDir>` whose transcript references `workspacePath`.
 * When a sibling `conversations/` trajectory store directory exists (as in `~/.gemini/antigravity-cli`),
 * only returns conversations that also have a corresponding `<conversationId>.db` trajectory file.
 */
export async function discoverRecentWorkspaceConversations(
  brainDir,
  workspacePath,
  { maxScan = 25, maxResults = 5 } = {}
) {
  if (!brainDir || !workspacePath) return [];
  const resolvedBrainDir = path.resolve(brainDir);
  const normalizedWs = path.resolve(workspacePath);
  const escapedWs = normalizedWs.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const wsBoundaryRe = new RegExp(`${escapedWs}(?:[/\\\\"'\\s)|<>]|$)`);

  let entries;
  try {
    entries = await fsp.readdir(resolvedBrainDir, { withFileTypes: true });
  } catch {
    return [];
  }

  const conversationsStoreDir = path.join(path.dirname(resolvedBrainDir), 'conversations');
  let hasConversationsStoreDir = false;
  try {
    const storeStat = await fsp.stat(conversationsStoreDir);
    hasConversationsStoreDir = storeStat.isDirectory();
  } catch {
    hasConversationsStoreDir = false;
  }

  const candidates = [];
  for (const entry of entries) {
    if (!entry.isDirectory() || entry.name.startsWith('.')) continue;
    if (hasConversationsStoreDir) {
      try {
        await fsp.access(path.join(conversationsStoreDir, `${entry.name}.db`));
      } catch {
        continue;
      }
    }
    const transcriptPath = path.join(
      resolvedBrainDir,
      entry.name,
      '.system_generated',
      'logs',
      'transcript.jsonl'
    );
    try {
      const stat = await fsp.stat(transcriptPath);
      candidates.push({
        conversationId: entry.name,
        transcriptPath,
        mtimeMs: stat.mtimeMs
      });
    } catch {
      // No transcript in this folder
    }
  }

  candidates.sort((a, b) => b.mtimeMs - a.mtimeMs);

  const matches = [];
  for (const item of candidates.slice(0, maxScan)) {
    try {
      const raw = await fsp.readFile(item.transcriptPath, 'utf8');
      if (!wsBoundaryRe.test(raw)) {
        continue;
      }
      const msgs = await readTranscriptMessages(brainDir, item.conversationId);
      if (msgs.length === 0) continue;
      const lastUser = [...msgs].reverse().find((m) => m.role === 'user') || msgs[msgs.length - 1];
      const oneLine = lastUser.text.replace(/\s+/g, ' ').trim();
      matches.push({
        conversationId: item.conversationId,
        updatedAt: new Date(item.mtimeMs).toISOString(),
        messageCount: msgs.length,
        preview: oneLine.length > 60 ? `${oneLine.slice(0, 57)}...` : oneLine
      });
      if (matches.length >= maxResults) break;
    } catch {
      // ignore unreadable file
    }
  }

  return matches;
}

export const ACTIVE_DESKTOP_SESSION_MAX_AGE_MS = 48 * 60 * 60 * 1000; // 48 hours

/**
 * Checks whether a desktop session has recent activity within the active threshold.
 */
export function isDesktopSessionActive(
  desktopSession,
  maxAgeMs = ACTIVE_DESKTOP_SESSION_MAX_AGE_MS
) {
  if (!desktopSession || !desktopSession.conversationId) return false;
  const mtime =
    desktopSession.mtimeMs ||
    (desktopSession.updatedAt ? new Date(desktopSession.updatedAt).getTime() : 0);
  if (!mtime) return false;
  const age = Date.now() - mtime;
  return age >= 0 && age <= maxAgeMs;
}

/**
 * Scans the local Mac for recent Desktop agent sessions for `workspacePath`.
 * Checks:
 *  1. Antigravity Desktop IDE (~/.gemini/antigravity/brain)
 *  2. Antigravity IDE app data (~/.gemini/antigravity-ide/brain)
 *  3. Antigravity CLI (~/.gemini/antigravity-cli/brain or customBrainDir)
 *  4. Aider (.aider.chat.history.md in workspacePath)
 *
 * Returns the most recent desktop session object, or null.
 */
export async function findLatestDesktopSession(
  workspacePath,
  { customBrainDir = null, maxLookbackMs = 14 * 24 * 60 * 60 * 1000 } = {}
) {
  if (!workspacePath) return null;
  const normalizedWs = path.resolve(workspacePath);
  const escapedWs = normalizedWs.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const wsBoundaryRe = new RegExp(`${escapedWs}(?:[/\\\\"'\\s)|<>]|$)`);

  const home = os.homedir();
  const searchTargets = [
    {
      source: 'antigravity-desktop',
      label: 'Antigravity Desktop IDE',
      brainDir: path.join(home, '.gemini', 'antigravity', 'brain'),
      requiresDb: false
    },
    {
      source: 'antigravity-ide',
      label: 'Antigravity IDE',
      brainDir: path.join(home, '.gemini', 'antigravity-ide', 'brain'),
      requiresDb: false
    },
    {
      source: 'antigravity-cli',
      label: 'Antigravity CLI',
      brainDir: path.join(home, '.gemini', 'antigravity-cli', 'brain'),
      requiresDb: true
    }
  ];

  if (customBrainDir && typeof customBrainDir === 'string') {
    const resolvedCustom = path.resolve(customBrainDir);
    if (!searchTargets.some((t) => path.resolve(t.brainDir) === resolvedCustom)) {
      searchTargets.unshift({
        source: 'antigravity-custom',
        label: 'Antigravity Desktop IDE',
        brainDir: resolvedCustom,
        requiresDb: false
      });
    }
  }

  const now = Date.now();
  const candidates = [];

  for (const target of searchTargets) {
    let entries;
    try {
      entries = await fsp.readdir(target.brainDir, { withFileTypes: true });
    } catch {
      continue;
    }

    const convStoreDir = path.join(path.dirname(target.brainDir), 'conversations');

    for (const e of entries) {
      if (!e.isDirectory() || e.name.startsWith('.')) continue;

      if (target.requiresDb) {
        try {
          await fsp.access(path.join(convStoreDir, `${e.name}.db`));
        } catch {
          continue;
        }
      }

      const tPath = path.join(target.brainDir, e.name, '.system_generated', 'logs', 'transcript.jsonl');
      try {
        const stat = await fsp.stat(tPath);
        if (maxLookbackMs > 0 && now - stat.mtimeMs > maxLookbackMs) {
          continue;
        }

        const raw = await fsp.readFile(tPath, 'utf8');
        if (!wsBoundaryRe.test(raw)) continue;

        const msgs = await readTranscriptMessages(target.brainDir, e.name);
        if (msgs.length === 0) continue;

        const lastUser = [...msgs].reverse().find((m) => m.role === 'user');
        const lastAsst = [...msgs].reverse().find((m) => m.role === 'assistant');

        const isActive = now - stat.mtimeMs <= ACTIVE_DESKTOP_SESSION_MAX_AGE_MS;

        candidates.push({
          source: target.source,
          sourceLabel: target.label,
          conversationId: e.name,
          brainDir: target.brainDir,
          updatedAt: new Date(stat.mtimeMs).toISOString(),
          mtimeMs: stat.mtimeMs,
          isActive,
          messageCount: msgs.length,
          lastUserMessage: lastUser || null,
          lastAssistantMessage: lastAsst || null,
          preview: lastUser ? lastUser.text.replace(/\s+/g, ' ').trim() : ''
        });
      } catch {
        // file unreadable or missing
      }
    }
  }

  // Check Aider history
  const aiderHistoryPath = path.join(normalizedWs, '.aider.chat.history.md');
  try {
    const aStat = await fsp.stat(aiderHistoryPath);
    if (aStat.size > 0 && (maxLookbackMs <= 0 || now - aStat.mtimeMs <= maxLookbackMs)) {
      const aRaw = await fsp.readFile(aiderHistoryPath, 'utf8');
      const lines = aRaw.split(/\r?\n/);
      let lastUserText = '';

      for (let i = lines.length - 1; i >= 0; i--) {
        const l = lines[i];
        if (!lastUserText && (l.startsWith('#### ') || l.startsWith('> '))) {
          lastUserText = l.replace(/^#{1,4}\s*|>\s*/, '').trim();
          if (lastUserText) break;
        }
      }

      if (lastUserText || aRaw.trim().length > 0) {
        const isActive = now - aStat.mtimeMs <= ACTIVE_DESKTOP_SESSION_MAX_AGE_MS;
        candidates.push({
          source: 'aider',
          sourceLabel: 'Aider CLI',
          conversationId: 'aider-history',
          brainDir: normalizedWs,
          updatedAt: new Date(aStat.mtimeMs).toISOString(),
          mtimeMs: aStat.mtimeMs,
          isActive,
          messageCount: 1,
          lastUserMessage: lastUserText ? { role: 'user', text: lastUserText, createdAt: null } : null,
          lastAssistantMessage: null,
          preview: lastUserText || 'Aider terminal session'
        });
      }
    }
  } catch {
    // No aider history
  }

  candidates.sort((a, b) => b.mtimeMs - a.mtimeMs);
  return candidates[0] || null;
}
