import http from 'node:http';
import https from 'node:https';
import fsp from 'node:fs/promises';
import path from 'node:path';

export function escapeHtml(text) {
  return String(text ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

export function escapeHtmlAttr(text) {
  return escapeHtml(text).replace(/"/g, '&quot;');
}

export function unescapeHtmlEntities(text) {
  return String(text ?? '')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&amp;/g, '&');
}

const TELEGRAM_HTML_TAGS = new Set([
  'b',
  'strong',
  'i',
  'em',
  'u',
  'ins',
  's',
  'strike',
  'del',
  'code',
  'pre',
  'blockquote',
  'a',
  'tg-spoiler'
]);

const GFM_ALERT_LABELS = {
  NOTE: 'ℹ️ <b>Note</b>',
  TIP: '💡 <b>Tip</b>',
  IMPORTANT: '📌 <b>Important</b>',
  WARNING: '⚠️ <b>Warning</b>',
  CAUTION: '🚨 <b>Caution</b>'
};

function renderLocalFileRef(rawLabel, rawUrl, forceCode = false) {
  const cleanLabel = String(rawLabel || '')
    .replace(/^`+|`+$/g, '')
    .trim();
  const lineMatch = String(rawUrl || '').match(/#(L\d+(?:-L?\d+)?)$/i);
  const lineSuffix = lineMatch ? `#${lineMatch[1]}` : '';

  const withoutHash = String(rawUrl || '').split('#')[0].split('?')[0];
  let decodedPath = withoutHash.replace(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\/(?:localhost)?/i, '');
  try {
    decodedPath = decodeURIComponent(decodedPath);
  } catch {
    // keep raw path if malformed percent-encoding
  }
  const baseName = path.posix.basename(decodedPath.replace(/\\/g, '/'));

  if (!cleanLabel) {
    const fallback = (baseName || withoutHash) + lineSuffix;
    return `<code>${escapeHtml(fallback)}</code>`;
  }

  if (forceCode || !/\s/.test(cleanLabel)) {
    const shouldAppendLine =
      Boolean(lineSuffix) &&
      !cleanLabel.includes('#') &&
      Boolean(baseName) &&
      (cleanLabel === baseName || cleanLabel.endsWith(`/${baseName}`));
    return `<code>${escapeHtml(shouldAppendLine ? `${cleanLabel}${lineSuffix}` : cleanLabel)}</code>`;
  }

  if (baseName && !cleanLabel.includes(baseName)) {
    return `${escapeHtml(cleanLabel)} (<code>${escapeHtml(baseName + lineSuffix)}</code>)`;
  }
  return `<code>${escapeHtml(cleanLabel)}</code>`;
}

function formatInlineMarkdown(escapedText) {
  let out = escapedText;
  // Bold + Italic: ***text***
  out = out.replace(/\*\*\*(?=\S)([^\n]*?\S)\*\*\*/g, '<b><i>$1</i></b>');
  // Bold: **text**
  out = out.replace(/\*\*(?=\S)([^\n]*?\S)\*\*/g, '<b>$1</b>');
  // Bold: __text__ (word-bounded)
  out = out.replace(/(?<![a-zA-Z0-9_])__(?=\S)([^\n]*?\S)__(?![a-zA-Z0-9_])/g, '<b>$1</b>');
  // Strikethrough: ~~text~~
  out = out.replace(/~~(?=\S)([^\n]*?\S)~~/g, '<s>$1</s>');
  // Italic: *text*
  out = out.replace(/(?<!\*)\*(?=\S)([^\n*]*?\S)\*(?!\*)/g, '<i>$1</i>');
  // Italic: _text_ (word-bounded so snake_case_identifiers remain untouched)
  out = out.replace(/(?<![a-zA-Z0-9_])_(?=\S)([^\n_]*?\S)_(?![a-zA-Z0-9_])/g, '<i>$1</i>');
  return out;
}

/**
 * Converts GitHub-Flavored Markdown (such as Antigravity agent responses and transcripts)
 * into clean, valid Telegram Bot API HTML (`parse_mode: 'HTML'`).
 * - Formats headings, bold, italic, strikethrough, inline code, fenced code blocks, lists,
 *   horizontal rules, and blockquotes / GFM alerts.
 * - Strips local `file:///...` IDE paths from Markdown links into compact `<code>filename</code>`
 *   badges so Telegram does not print long local paths or auto-link `.ch`/`.io` folder names.
 */
export function markdownToTelegramHtml(markdown) {
  let src = String(markdown ?? '')
    .replace(/\x00/g, '')
    .replace(/\r\n?/g, '\n');
  if (!src) return '';

  const tokens = [];
  const putToken = (html) => {
    const id = `\x00TK${tokens.length}Z\x00`;
    tokens.push(html);
    return id;
  };

  // 1. Extract fenced code blocks (```lang ... ``` or ~~~ ... ~~~, including truncated EOF fences)
  src = src.replace(
    /(^|\n)[ \t]*(`{3,}|~{3,})([^\n]*)\n([\s\S]*?)(?:\n[ \t]*\2[ \t]*(?=\n|$)|$)/g,
    (_match, lead, _fence, infoStr, body) => {
      const langMatch = String(infoStr || '').trim().match(/^[a-zA-Z0-9_+#.-]+/);
      const cleanBody = String(body || '').replace(/\n$/, '');
      const html = langMatch
        ? `<pre><code class="language-${escapeHtmlAttr(langMatch[0])}">${escapeHtml(cleanBody)}</code></pre>`
        : `<pre>${escapeHtml(cleanBody)}</pre>`;
      return `${lead}${putToken(html)}`;
    }
  );

  // 2. Single left-to-right pass for Markdown links/images `[label](url)` and inline `` `code` ``
  src = src.replace(
    /(!?)\[(`+[^`\n]+`+|[^\]\n]+)\]\(((?:\([^)\s]*\)|[^)\s])+)\)|(`+)(?!`)([^\n]+?)\4(?!`)/g,
    (_match, bang, linkLabel, linkUrl, _ticks, inlineCode) => {
      if (inlineCode !== undefined) {
        return putToken(`<code>${escapeHtml(inlineCode)}</code>`);
      }

      const rawUrl = String(linkUrl || '').trim();
      const hadBackticks = /^`+[\s\S]*`+$/.test(String(linkLabel || '').trim());
      const cleanLabel = String(linkLabel || '')
        .replace(/^`+|`+$/g, '')
        .trim();

      if (/^(?:https?:\/\/|tg:\/\/|mailto:)/i.test(rawUrl)) {
        const prefix = bang === '!' ? '🖼 ' : '';
        return putToken(
          `<a href="${escapeHtmlAttr(rawUrl)}">${prefix}${escapeHtml(cleanLabel || rawUrl)}</a>`
        );
      }

      const prefix = bang === '!' ? '🖼 ' : '';
      return putToken(`${prefix}${renderLocalFileRef(linkLabel, rawUrl, hadBackticks)}`);
    }
  );

  // 3. Convert bare `file:///...` URLs into compact `<code>basename</code>` badges
  src = src.replace(/file:\/\/(?:localhost)?\/[^\s<>)\]"'`]+/gi, (rawMatch) => {
    const trailMatch = rawMatch.match(/[.,;:!?]+$/);
    const trailing = trailMatch ? trailMatch[0] : '';
    const cleanUrl = trailing ? rawMatch.slice(0, -trailing.length) : rawMatch;
    return `${putToken(renderLocalFileRef('', cleanUrl, true))}${trailing}`;
  });

  // 4. HTML-escape all remaining prose text
  src = escapeHtml(src);

  // 5. Block-level transforms (blockquotes, horizontal rules, headings, task & bullet lists)
  const rawLines = src.split('\n');
  const outLines = [];
  let i = 0;

  while (i < rawLines.length) {
    const line = rawLines[i];

    // Consecutive blockquote lines (`> ...`)
    if (/^\s*&gt;\s?/.test(line)) {
      const quoteLines = [];
      while (i < rawLines.length && /^\s*&gt;\s?/.test(rawLines[i])) {
        quoteLines.push(rawLines[i].replace(/^\s*&gt;\s?/, ''));
        i += 1;
      }
      if (quoteLines.length > 0) {
        const alertMatch = quoteLines[0].match(
          /^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*(.*)$/i
        );
        if (alertMatch) {
          const badge = GFM_ALERT_LABELS[alertMatch[1].toUpperCase()];
          const restFirst = alertMatch[2].trim();
          quoteLines[0] = restFirst ? `${badge}: ${restFirst}` : badge;
        }
      }
      const formattedQuote = quoteLines.map((ql) => formatInlineMarkdown(ql)).join('\n');
      outLines.push(putToken(`<blockquote>${formattedQuote}</blockquote>`));
      continue;
    }

    i += 1;

    // Horizontal rule (`---`, `***`, `___`)
    if (/^\s*(?:-{3,}|\*{3,}|_{3,})\s*$/.test(line)) {
      outLines.push('──────────────');
      continue;
    }

    // Markdown ATX Heading (`#` .. `######`)
    const headingMatch = line.match(/^\s*#{1,6}\s+(.+?)\s*#*$/);
    if (headingMatch) {
      const inner = formatInlineMarkdown(headingMatch[1]).replace(/<\/?b>/g, '');
      outLines.push(`<b>${inner}</b>`);
      continue;
    }

    // Task list items (`- [x] ...` / `- [ ] ...`)
    const taskMatch = line.match(/^(\s*)[-*+]\s+\[([ xX])\]\s+(.+)$/);
    if (taskMatch) {
      const box = taskMatch[2].toLowerCase() === 'x' ? '☑' : '☐';
      outLines.push(`${taskMatch[1]}${box} ${formatInlineMarkdown(taskMatch[3])}`);
      continue;
    }

    // Unordered bullet list (`- item`, `* item`, `+ item`)
    const bulletMatch = line.match(/^(\s*)[-*+]\s+(.+)$/);
    if (bulletMatch) {
      outLines.push(`${bulletMatch[1]}• ${formatInlineMarkdown(bulletMatch[2])}`);
      continue;
    }

    outLines.push(formatInlineMarkdown(line));
  }

  let result = outLines.join('\n').replace(/\n{3,}/g, '\n\n');

  // 6. Restore extracted HTML tokens (supports nested tokens such as inline code inside blockquotes)
  for (let pass = 0; pass < 5 && /\x00TK\d+Z\x00/.test(result); pass++) {
    result = result.replace(/\x00TK(\d+)Z\x00/g, (_m, idx) => tokens[Number(idx)] ?? '');
  }

  return result;
}

function getOpenHtmlTagStack(htmlChunk) {
  const stack = [];
  const tagRe = /<\/?([a-zA-Z0-9-]+)(?:\s[^>]*)?>/g;
  let match;
  while ((match = tagRe.exec(htmlChunk)) !== null) {
    const full = match[0];
    const name = match[1].toLowerCase();
    if (!TELEGRAM_HTML_TAGS.has(name) || full.endsWith('/>')) continue;
    if (full.startsWith('</')) {
      for (let idx = stack.length - 1; idx >= 0; idx--) {
        if (stack[idx].name === name) {
          stack.splice(idx, 1);
          break;
        }
      }
    } else {
      stack.push({ name, openTag: full });
    }
  }
  return stack;
}

function adjustCutOutsideHtmlConstructs(str, rawCut, minPos) {
  let cut = rawCut;
  const lastLt = str.lastIndexOf('<', cut - 1);
  if (lastLt >= minPos) {
    const gtAfterLt = str.indexOf('>', lastLt);
    if (gtAfterLt === -1 || gtAfterLt >= cut) {
      cut = lastLt;
    }
  }
  const searchFrom = Math.max(minPos, cut - 12);
  const lastAmp = str.lastIndexOf('&', cut - 1);
  if (lastAmp >= searchFrom) {
    const semi = str.indexOf(';', lastAmp);
    if (semi !== -1 && semi >= cut && semi - lastAmp <= 12) {
      cut = lastAmp;
    }
  }
  return cut;
}

/**
 * Splits long text/HTML into chunks under `maxLen` characters on newline boundaries
 * while keeping Telegram HTML tags (`<pre>`, `<code>`, `<b>`, `<blockquote>`, `<a>`, etc.)
 * properly balanced across every chunk.
 */
export function splitTelegramText(text, maxLen = 3800) {
  const str = String(text || '');
  if (str.length <= maxLen) return [str];

  const hasHtml = /<\/?[a-zA-Z]/.test(str);
  const closingReserve = hasHtml ? Math.min(90, Math.max(18, Math.floor(maxLen * 0.2))) : 0;

  const chunks = [];
  let remaining = str;
  let reopenPrefixLen = 0;

  while (remaining.length > maxLen) {
    const budget = Math.max(reopenPrefixLen + 2, maxLen - closingReserve);
    const minPreferred = Math.max(
      reopenPrefixLen + 1,
      reopenPrefixLen + Math.floor((budget - reopenPrefixLen) * 0.35)
    );

    let cut = remaining.lastIndexOf('\n', budget);
    if (cut < minPreferred) {
      cut = remaining.lastIndexOf(' ', budget);
    }
    if (cut < minPreferred) {
      cut = Math.min(remaining.length, budget);
    }

    if (hasHtml) {
      cut = adjustCutOutsideHtmlConstructs(remaining, cut, reopenPrefixLen + 1);
    }
    if (cut <= reopenPrefixLen) {
      cut = Math.min(remaining.length, Math.max(reopenPrefixLen + 1, budget));
    }

    let head = remaining.slice(0, cut);
    let openStack = hasHtml ? getOpenHtmlTagStack(head) : [];
    let closingTags = openStack
      .slice()
      .reverse()
      .map((t) => `</${t.name}>`)
      .join('');

    if (head.length + closingTags.length > maxLen && cut - (head.length + closingTags.length - maxLen) > reopenPrefixLen) {
      cut = adjustCutOutsideHtmlConstructs(
        remaining,
        cut - (head.length + closingTags.length - maxLen),
        reopenPrefixLen + 1
      );
      head = remaining.slice(0, cut);
      openStack = hasHtml ? getOpenHtmlTagStack(head) : [];
      closingTags = openStack
        .slice()
        .reverse()
        .map((t) => `</${t.name}>`)
        .join('');
    }

    chunks.push(head + closingTags);

    const rest = remaining.slice(cut).replace(/^\n/, '');
    if (!rest) {
      remaining = '';
      break;
    }

    const reopenTags = openStack.map((t) => t.openTag).join('');
    const nextRemaining = reopenTags + rest;
    if (hasHtml && !unescapeHtmlEntities(nextRemaining.replace(/<[^>]+>/g, '')).trim()) {
      remaining = '';
      break;
    }

    remaining = nextRemaining;
    reopenPrefixLen = reopenTags.length;
  }

  if (remaining.length > 0) {
    chunks.push(remaining);
  }
  return chunks;
}

function requestRaw(urlString, { method = 'GET', headers = {}, body = null, timeoutMs = 35_000, signal } = {}) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      const err = new Error('Request aborted');
      err.name = 'AbortError';
      reject(err);
      return;
    }

    const url = new URL(urlString);
    const transport = url.protocol === 'https:' ? https : http;

    const req = transport.request(
      url,
      {
        method,
        headers,
        timeout: timeoutMs
      },
      (res) => {
        const chunks = [];
        res.on('data', (chunk) => chunks.push(chunk));
        res.on('end', () => {
          if (signal) signal.removeEventListener('abort', onAbort);
          resolve({
            status: res.statusCode || 0,
            headers: res.headers,
            buffer: Buffer.concat(chunks)
          });
        });
      }
    );

    function onAbort() {
      const err = new Error('Request aborted');
      err.name = 'AbortError';
      req.destroy(err);
    }

    if (signal) {
      signal.addEventListener('abort', onAbort, { once: true });
    }

    req.on('timeout', () => {
      req.destroy(new Error(`Telegram API request timed out after ${timeoutMs}ms`));
    });

    req.on('error', (err) => {
      if (signal) signal.removeEventListener('abort', onAbort);
      reject(err);
    });

    if (body) {
      req.write(body);
    }
    req.end();
  });
}

export class TelegramApi {
  constructor({ token, baseUrl = 'https://api.telegram.org' }) {
    if (!token || !String(token).trim()) {
      throw new Error('Telegram Bot Token is missing');
    }
    this.token = String(token).trim();
    this.baseUrl = String(baseUrl || 'https://api.telegram.org').replace(/\/+$/, '');
  }

  async call(method, params = {}, { timeoutMs = 30_000, signal } = {}) {
    const url = `${this.baseUrl}/bot${this.token}/${method}`;
    const payload = Buffer.from(JSON.stringify(params), 'utf8');

    const res = await requestRaw(url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'Content-Length': String(payload.length),
        Accept: 'application/json'
      },
      body: payload,
      timeoutMs,
      signal
    });

    let parsed;
    try {
      parsed = JSON.parse(res.buffer.toString('utf8'));
    } catch {
      throw new Error(`Invalid JSON from Telegram API (${method}, HTTP ${res.status})`);
    }

    if (!parsed.ok) {
      const err = new Error(parsed.description || `Telegram API error in ${method}`);
      err.errorCode = parsed.error_code || res.status;
      throw err;
    }

    return parsed.result;
  }

  async getMe() {
    return this.call('getMe');
  }

  async setMyCommands(commands) {
    return this.call('setMyCommands', { commands });
  }

  async getUpdates({ offset = 0, timeout = 25, signal } = {}) {
    return this.call(
      'getUpdates',
      {
        offset,
        timeout,
        allowed_updates: ['message', 'callback_query']
      },
      {
        timeoutMs: (timeout + 12) * 1000,
        signal
      }
    );
  }

  async sendMessage({
    chatId,
    text,
    parseMode = 'HTML',
    replyMarkup = undefined,
    disableWebPagePreview = true
  }) {
    const chunks = splitTelegramText(text, 3800);
    let lastMsg = null;

    for (let i = 0; i < chunks.length; i++) {
      const isLast = i === chunks.length - 1;
      const body = {
        chat_id: chatId,
        text: chunks[i],
        disable_web_page_preview: disableWebPagePreview,
        ...(parseMode ? { parse_mode: parseMode } : {}),
        ...(isLast && replyMarkup ? { reply_markup: replyMarkup } : {})
      };

      try {
        lastMsg = await this.call('sendMessage', body);
      } catch (err) {
        // Fallback without parse_mode if Telegram rejects any entity
        if (parseMode && /can't parse entities/i.test(err.message || '')) {
          const fallbackBody = { ...body };
          delete fallbackBody.parse_mode;
          fallbackBody.text = unescapeHtmlEntities(chunks[i].replace(/<[^>]+>/g, ''));
          lastMsg = await this.call('sendMessage', fallbackBody);
        } else {
          throw err;
        }
      }
    }

    return lastMsg;
  }

  async editMessageText({
    chatId,
    messageId,
    text,
    parseMode = 'HTML',
    replyMarkup = undefined,
    disableWebPagePreview = true
  }) {
    const rawStr = String(text || '');
    let safeText = rawStr;
    if (rawStr.length > 3900) {
      const parts = splitTelegramText(rawStr, 3880);
      safeText = parts.length > 1 ? `${parts[0]}\n…` : parts[0];
    }

    const body = {
      chat_id: chatId,
      message_id: messageId,
      text: safeText,
      disable_web_page_preview: disableWebPagePreview,
      ...(parseMode ? { parse_mode: parseMode } : {}),
      ...(replyMarkup ? { reply_markup: replyMarkup } : {})
    };

    try {
      return await this.call('editMessageText', body);
    } catch (err) {
      if (/message is not modified/i.test(err.message || '')) {
        return null;
      }
      if (parseMode && /can't parse entities/i.test(err.message || '')) {
        const fallbackBody = { ...body };
        delete fallbackBody.parse_mode;
        fallbackBody.text = unescapeHtmlEntities(safeText.replace(/<[^>]+>/g, ''));
        return this.call('editMessageText', fallbackBody);
      }
      throw err;
    }
  }

  async clearInlineButtons(chatId, messageId) {
    if (!chatId || !messageId) return;
    try {
      await this.call('editMessageReplyMarkup', {
        chat_id: chatId,
        message_id: messageId,
        reply_markup: { inline_keyboard: [] }
      });
    } catch {
      // Ignore if message was already edited or too old
    }
  }

  async answerCallbackQuery(callbackQueryId, text = '', showAlert = false) {
    try {
      return await this.call('answerCallbackQuery', {
        callback_query_id: callbackQueryId,
        ...(text ? { text: String(text).slice(0, 195) } : {}),
        show_alert: showAlert
      });
    } catch {
      return null;
    }
  }

  async deleteMessage(chatId, messageId) {
    try {
      return await this.call('deleteMessage', {
        chat_id: chatId,
        message_id: messageId
      });
    } catch {
      return false;
    }
  }

  async downloadFile(fileId, destPath, preferredExt = '') {
    const fileInfo = await this.call('getFile', { file_id: fileId });
    if (!fileInfo?.file_path) {
      throw new Error('Telegram getFile returned no file_path');
    }

    const downloadUrl = `${this.baseUrl}/file/bot${this.token}/${fileInfo.file_path}`;
    const res = await requestRaw(downloadUrl, { method: 'GET', timeoutMs: 60_000 });
    if (res.status < 200 || res.status >= 300) {
      throw new Error(`Failed to download Telegram file (HTTP ${res.status})`);
    }

    const cleanPrefExt =
      preferredExt && /^\.[a-z0-9]{1,10}$/i.test(preferredExt) ? preferredExt.toLowerCase() : '';
    const ext = path.extname(fileInfo.file_path) || cleanPrefExt || '.jpg';
    const finalPath = destPath.endsWith(ext) ? destPath : `${destPath}${ext}`;
    await fsp.mkdir(path.dirname(finalPath), { recursive: true, mode: 0o700 });
    await fsp.writeFile(finalPath, res.buffer, { mode: 0o600 });
    return finalPath;
  }
}

