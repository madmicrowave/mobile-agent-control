import fsp from 'node:fs/promises';
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
 */
export async function discoverRecentWorkspaceConversations(
  brainDir,
  workspacePath,
  { maxScan = 25, maxResults = 5 } = {}
) {
  if (!brainDir || !workspacePath) return [];
  const normalizedWs = path.resolve(workspacePath);
  const escapedWs = normalizedWs.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const wsBoundaryRe = new RegExp(`${escapedWs}(?:[/\\\\"'\\s)|<>]|$)`);

  let entries;
  try {
    entries = await fsp.readdir(brainDir, { withFileTypes: true });
  } catch {
    return [];
  }

  const candidates = [];
  for (const entry of entries) {
    if (!entry.isDirectory() || entry.name.startsWith('.')) continue;
    const transcriptPath = path.join(
      brainDir,
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
