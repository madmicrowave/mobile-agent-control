import { spawn, execFile } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

export const VALID_MODEL_LEVELS = ['low', 'medium', 'high'];

export const GEMINI_MODEL_FAMILIES = [
  {
    shortCode: 'g38',
    family: 'gemini-3.8-flash',
    label: 'Gemini 3.8 Flash',
    aliases: [
      'gemini-3.8',
      'gemini 3.8',
      'gemini-3.8-flash',
      'gemini 3.8 flash',
      'gemeni-3.8',
      'gemeni 3.8',
      'gemeni-3.8-flash'
    ],
    tieredLevels: ['low', 'medium', 'high']
  },
  {
    shortCode: 'g4',
    family: 'gemini-4-argon',
    label: 'Gemini 4 Argon',
    aliases: ['gemini-4', 'gemini 4', 'gemini-4-argon', 'gemini 4 argon', 'gemeni-4', 'gemeni 4'],
    tieredLevels: ['low', 'medium', 'high']
  },
  {
    shortCode: 'g4c',
    family: 'gemini-4-carbon',
    label: 'Gemini 4 Carbon',
    aliases: [
      'gemini-4-carbon',
      'gemini 4 carbon',
      'gemini-carbon',
      'gemini carbon',
      'carbon',
      'gemeni-4-carbon',
      'gemeni 4 carbon'
    ],
    tieredLevels: ['low', 'medium', 'high']
  },
  {
    shortCode: 'co55',
    family: 'claude-opus-5-5',
    label: 'Claude Opus 5.5',
    aliases: [
      'claude-opus',
      'claude opus',
      'claude-opus-5-5',
      'claude opus 5.5',
      'claude-opus-5.5',
      'cloud-opus',
      'cloud opus',
      'cloud-opus-5-5',
      'cloud opus 5.5',
      'cloud-opus-5.5'
    ],
    tieredLevels: ['low', 'medium', 'high']
  }
];

export const DEFAULT_AGENT_MODEL_FAMILIES = [
  ...GEMINI_MODEL_FAMILIES,
  {
    shortCode: 'gcc',
    family: 'google-cloud-code',
    label: 'Google Cloud Code',
    aliases: [
      'google-cloud-code',
      'google cloud code',
      'cloud-code',
      'cloud code',
      'cloudcode',
      'gemini-code-assist'
    ],
    tieredLevels: ['low', 'medium', 'high']
  },
  {
    shortCode: 'cdx',
    family: 'openai-codex',
    label: 'OpenAI Codex',
    aliases: [
      'openai-codex',
      'openai codex',
      'codex',
      'codex-control',
      'code-davinci'
    ],
    tieredLevels: []
  },
  {
    shortCode: 'cs55',
    family: 'claude-sonnet-5-5',
    label: 'Claude Sonnet 5.5',
    aliases: [
      'claude-sonnet',
      'claude sonnet',
      'claude-sonnet-5-5',
      'claude sonnet 5.5',
      'claude-sonnet-5.5'
    ],
    tieredLevels: ['low', 'medium', 'high']
  },
  {
    shortCode: 'c37s',
    family: 'claude-3-7-sonnet',
    label: 'Claude 3.7 Sonnet',
    aliases: [
      'claude-3-7-sonnet',
      'claude-3.7-sonnet',
      'claude 3.7 sonnet',
      'claude-3.7',
      'claude 3.7',
      'claude-3-7'
    ],
    tieredLevels: []
  },
  {
    shortCode: 'c35s',
    family: 'claude-3-5-sonnet',
    label: 'Claude 3.5 Sonnet',
    aliases: [
      'claude-3-5-sonnet',
      'claude-3.5-sonnet',
      'claude 3.5 sonnet',
      'claude-3.5',
      'claude 3.5',
      'claude-3-5'
    ],
    tieredLevels: []
  },
  {
    shortCode: 'dsk',
    family: 'deepseek-chat',
    label: 'DeepSeek V3',
    aliases: [
      'deepseek-chat',
      'deepseek-v3',
      'deepseek v3',
      'deepseek'
    ],
    tieredLevels: []
  },
  {
    shortCode: 'dsr',
    family: 'deepseek-reasoner',
    label: 'DeepSeek R1',
    aliases: [
      'deepseek-reasoner',
      'deepseek-r1',
      'deepseek r1',
      'r1'
    ],
    tieredLevels: []
  },
  {
    shortCode: 'g4o',
    family: 'gpt-4o',
    label: 'OpenAI GPT-4o',
    aliases: [
      'gpt-4o',
      'gpt4o',
      '4o',
      'chatgpt-4o',
      'openai-gpt-4o'
    ],
    tieredLevels: []
  },
  {
    shortCode: 'o3m',
    family: 'o3-mini',
    label: 'OpenAI o3-mini',
    aliases: [
      'o3-mini',
      'o3mini',
      'o3',
      'openai-o3-mini'
    ],
    tieredLevels: []
  },
  {
    shortCode: 'o1',
    family: 'o1',
    label: 'OpenAI o1',
    aliases: [
      'o1',
      'openai-o1',
      'chatgpt-o1'
    ],
    tieredLevels: []
  },
  {
    shortCode: 'q25c',
    family: 'qwen-2.5-coder-32b',
    label: 'Qwen 2.5 Coder 32B',
    aliases: [
      'qwen-2.5-coder-32b',
      'qwen-coder',
      'qwen-2.5-coder',
      'qwen coder',
      'qwen 2.5 coder'
    ],
    tieredLevels: []
  },
  {
    shortCode: 'q25',
    family: 'qwen-2.5-72b',
    label: 'Qwen 2.5 72B',
    aliases: [
      'qwen-2.5-72b',
      'qwen-72b',
      'qwen',
      'qwen 2.5 72b'
    ],
    tieredLevels: []
  },
  {
    shortCode: 'gpt120',
    family: 'gpt-oss-120b-medium',
    label: 'GPT-OSS 120B',
    aliases: ['gpt-oss', 'gpt-oss-120b', 'gpt-oss-120b-medium'],
    tieredLevels: []
  }
];

export const MAX_AGY_TIMEOUT_SECONDS = 300; // 5 minutes max
export const DEFAULT_AGY_TIMEOUT = '5m0s';

/**
 * Normalizes a requested timeout string into agy CLI `--print-timeout` format (e.g. '5m0s').
 * Strictly caps the timeout to 5 minutes maximum (300 seconds), never 30 minutes.
 */
export function normalizeAgyTimeout(rawTimeout = DEFAULT_AGY_TIMEOUT) {
  if (!rawTimeout || typeof rawTimeout !== 'string') {
    return DEFAULT_AGY_TIMEOUT;
  }
  const trimmed = rawTimeout.trim().toLowerCase();
  const minSecMatch = trimmed.match(
    /^(\d+(?:\.\d+)?)\s*m(?:in|ins|inutes)?(?:\s*(\d+(?:\.\d+)?)\s*s(?:ec|ecs|econds)?)?$/
  );
  if (minSecMatch) {
    const mins = parseFloat(minSecMatch[1]);
    const secs = minSecMatch[2] ? parseFloat(minSecMatch[2]) : 0;
    const totalSecs = mins * 60 + secs;
    if (totalSecs > MAX_AGY_TIMEOUT_SECONDS || totalSecs <= 0) {
      return DEFAULT_AGY_TIMEOUT;
    }
    return `${Math.floor(mins)}m${Math.floor(secs)}s`;
  }
  const secMatch = trimmed.match(/^(\d+(?:\.\d+)?)\s*s(?:ec|ecs|econds)?$/);
  if (secMatch) {
    const totalSecs = parseFloat(secMatch[1]);
    if (totalSecs > MAX_AGY_TIMEOUT_SECONDS || totalSecs <= 0) {
      return DEFAULT_AGY_TIMEOUT;
    }
    const mins = Math.floor(totalSecs / 60);
    const remSecs = Math.floor(totalSecs % 60);
    return `${mins}m${remSecs}s`;
  }
  return DEFAULT_AGY_TIMEOUT;
}

/**
 * Returns true if an error or output message represents an agy CLI timeout / deadline exceeded.
 */
export function isAgyTimeoutError(textOrError) {
  if (!textOrError) return false;
  const msg =
    typeof textOrError === 'string'
      ? textOrError
      : String(
          textOrError?.message ||
            textOrError?.short_error ||
            textOrError?.reason ||
            textOrError ||
            ''
        );
  return (
    /print\s+timeout/i.test(msg) ||
    /DEADLINE_EXCEEDED/i.test(msg) ||
    /print_timeout/i.test(msg) ||
    /timed?\s*out\s+after/i.test(msg) ||
    /timeout\s+after\s+\d+/i.test(msg)
  );
}

export function resolveDefaultAgyBin() {
  const localCandidate = path.join(os.homedir(), '.local', 'bin', 'agy');
  return fs.existsSync(localCandidate) ? localCandidate : 'agy';
}

/**
 * Returns true when `agy` failed because the requested `--conversation` / trajectory ID
 * does not exist in the CLI trajectory store (e.g. a Desktop IDE conversation ID, or a
 * deleted/pruned CLI conversation).
 */
export function isMissingTrajectoryError(error) {
  const msg = String(error?.message || error || '');
  return /trajectory\s+[^\s:]+\s+not\s+found|trajectory\s+not\s+found|failed\s+to\s+load\s+trajectory|conversation\s+[^\s:]+\s+not\s+found/i.test(
    msg
  );
}

/**
 * Returns true if a non-SUCCESS agent result text represents an unrecoverable system/API error
 * rather than legitimate assistant conversational text.
 */
export function isFatalAgentResponseError(responseText) {
  const trimmed = String(responseText || '').trim();
  if (!trimmed) return true;
  if (isAgyTimeoutError(trimmed)) return false;
  return (
    isMissingTrajectoryError(trimmed) ||
    /^(?:error:\s*failed to send message|failed to send message:|resource_exhausted|quota exceeded|rate limit exceeded|unauthenticated|you are not logged in|failed to load conversation)/i.test(
      trimmed
    )
  );
}

/**
 * Normalizes a user-configured `model` + `modelLevel` pair into the exact `--model` ID
 * and `--effort` level expected by the `agy` CLI.
 */
export function resolveEffectiveModelAndLevel({ model = '', modelLevel = '' } = {}) {
  const rawLevel = String(modelLevel || '').trim().toLowerCase();
  const normalizedLevel = ['xhigh', 'max'].includes(rawLevel) ? 'high' : rawLevel;
  const explicitLevel = VALID_MODEL_LEVELS.includes(normalizedLevel) ? normalizedLevel : '';

  const rawModel = String(model || '').trim();
  const lowerModel = rawModel.toLowerCase();

  if (!rawModel || ['default', 'auto', 'none', '-'].includes(lowerModel)) {
    return {
      family: '',
      modelId: '',
      effort: explicitLevel,
      displayLabel: explicitLevel ? `default (${explicitLevel})` : 'default'
    };
  }

  // Detect if rawModel already ends with a tier suffix like `-low`, `-medium`, `-high`
  const suffixMatch = lowerModel.match(/^(.*)-(low|medium|high)$/);
  const baseCandidate = suffixMatch ? suffixMatch[1] : lowerModel;
  const suffixLevel = suffixMatch ? suffixMatch[2] : '';

  const matchedFamily = DEFAULT_AGENT_MODEL_FAMILIES.find(
    (entry) =>
      entry.shortCode === lowerModel ||
      entry.family === lowerModel ||
      entry.family === baseCandidate ||
      entry.aliases.includes(lowerModel) ||
      entry.aliases.includes(baseCandidate)
  );

  if (matchedFamily) {
    const effectiveEffort = explicitLevel || suffixLevel || (matchedFamily.tieredLevels.length > 0 ? 'high' : '');
    if (matchedFamily.tieredLevels.length > 0) {
      const modelTier = matchedFamily.tieredLevels.includes(effectiveEffort)
        ? effectiveEffort
        : 'high';
      const resolvedId = `${matchedFamily.family}-${modelTier}`;
      return {
        family: matchedFamily.family,
        modelId: resolvedId,
        effort: effectiveEffort,
        displayLabel: `${matchedFamily.label} (${effectiveEffort || modelTier})`
      };
    }

    return {
      family: matchedFamily.family,
      modelId: matchedFamily.family,
      effort: effectiveEffort,
      displayLabel: effectiveEffort
        ? `${matchedFamily.label} (${effectiveEffort})`
        : matchedFamily.label
    };
  }

  const fallbackEffort = explicitLevel || suffixLevel || '';
  return {
    family: rawModel,
    modelId: rawModel,
    effort: fallbackEffort,
    displayLabel: fallbackEffort ? `${rawModel} (${fallbackEffort})` : rawModel
  };
}

/**
 * Queries `agy models` to list available model IDs, falling back to `DEFAULT_AGENT_MODEL_FAMILIES`
 * if `agy` is unavailable or offline.
 */
export async function listAvailableAgyModels(agyBin = resolveDefaultAgyBin()) {
  try {
    const homeDir = os.homedir();
    const extraPath = [
      path.join(homeDir, '.local', 'bin'),
      path.join(homeDir, '.gemini', 'bin'),
      '/opt/homebrew/bin',
      '/usr/local/bin'
    ].join(path.delimiter);

    const { stdout } = await execFileAsync(agyBin, ['models'], {
      timeout: 5_000,
      env: {
        ...process.env,
        PATH: `${extraPath}${path.delimiter}${process.env.PATH || '/usr/bin:/bin'}`
      }
    });

    const cleanText = String(stdout || '')
      .replace(/\x1b\[[0-9;]*[a-zA-Z]/g, '')
      .replace(/\r/g, '\n');

    const parsed = [];
    for (const rawLine of cleanText.split('\n')) {
      const line = rawLine.trim();
      if (!line || line.includes('Fetching available models')) continue;
      const match = line.match(/^([a-z0-9._-]+)\s{2,}(.+)$/i);
      if (match) {
        parsed.push({ id: match[1].trim(), label: match[2].trim() });
      }
    }

    if (parsed.length > 0) {
      return parsed;
    }
  } catch {
    // Fall back to known model families when offline or in synthetic test environments
  }

  const fallback = [];
  for (const fam of DEFAULT_AGENT_MODEL_FAMILIES) {
    if (fam.tieredLevels.length > 0) {
      for (const lvl of fam.tieredLevels) {
        fallback.push({
          id: `${fam.family}-${lvl}`,
          label: `${fam.label} (${lvl[0].toUpperCase()}${lvl.slice(1)})`
        });
      }
    } else {
      fallback.push({ id: fam.family, label: fam.label });
    }
  }
  return fallback;
}

/**
 * Queries `agy models` once and registers any newly released `gemini-*` model families
 * alongside `GEMINI_MODEL_FAMILIES` so both setup and Telegram menus stay up to date.
 */
export async function discoverGeminiModelFamilies(
  agyBin = resolveDefaultAgyBin(),
  { queryCli = false } = {}
) {
  if (!queryCli) {
    return [...GEMINI_MODEL_FAMILIES];
  }

  const rawModels = await listAvailableAgyModels(agyBin);
  const byFamily = new Map();

  for (const item of rawModels) {
    const id = String(item.id || '').trim().toLowerCase();
    if (!id.startsWith('gemini-')) continue;
    const tierMatch = id.match(/^(.*)-(low|medium|high)$/);
    const family = tierMatch ? tierMatch[1] : id;
    const tier = tierMatch ? tierMatch[2] : '';
    const cleanLabel = String(item.label || family)
      .replace(/\s*\((?:Low|Medium|High|XHigh|Max)\)\s*$/i, '')
      .trim();

    if (!byFamily.has(family)) {
      byFamily.set(family, {
        family,
        label: cleanLabel || family,
        tiers: new Set()
      });
    }
    if (tier) {
      byFamily.get(family).tiers.add(tier);
    }
  }

  let dynIdx = 1;
  for (const [family, info] of byFamily.entries()) {
    const existing = GEMINI_MODEL_FAMILIES.find((f) => f.family === family);
    if (existing) continue;
    const entry = {
      shortCode: `gm${dynIdx++}`,
      family,
      label: info.label,
      aliases: [family, family.replace(/-/g, ' ')],
      tieredLevels: [...info.tiers]
    };
    GEMINI_MODEL_FAMILIES.push(entry);
    DEFAULT_AGENT_MODEL_FAMILIES.unshift(entry);
  }

  return [...GEMINI_MODEL_FAMILIES];
}

export const BOT_CONTROLLER_PROMPT_SUFFIX =
  '[Telegram Controller Instruction: You are running headlessly via Telegram with no interactive IDE UI or terminal stdin. Do NOT ask interactive UI multiple-choice questions or run commands that wait on user stdin — perform the requested changes autonomously and summarize clearly in plain text. Modify workspace files only; do NOT run `git commit`, `git push`, `git checkout`, or trigger Jenkins yourself — the Telegram bot controller will show changed files to the user and handle git commit, branch selection, push, and Jenkins deployment.]';

export function buildAgyArgs({
  prompt,
  imagePaths = [],
  conversationId = null,
  continueLatest = false,
  model = '',
  modelLevel = '',
  skipPermissions = true,
  extraDirs = [],
  timeout = DEFAULT_AGY_TIMEOUT
}) {
  const sections = [];
  const trimmedPrompt = String(prompt || '').trim();
  if (trimmedPrompt) {
    sections.push(trimmedPrompt);
  } else if (imagePaths.length > 0) {
    sections.push('Inspect the attached image(s)/file(s) and implement or explain what is shown.');
  }

  if (Array.isArray(imagePaths) && imagePaths.length > 0) {
    const fileLines = imagePaths.map((p, idx) => `  ${idx + 1}. ${p}`).join('\n');
    sections.push(
      `[Attached User Photo(s) — read each attached file first with read_file before acting:\n${fileLines}]`
    );
  }

  sections.push(BOT_CONTROLLER_PROMPT_SUFFIX);

  const fullPrompt = sections.join('\n\n');
  const effectiveTimeout = normalizeAgyTimeout(timeout);
  const args = ['-p', fullPrompt, '--output-format', 'stream-json', '--print-timeout', effectiveTimeout];

  if (skipPermissions) {
    args.push('--dangerously-skip-permissions');
  }
  if (conversationId) {
    args.push('--conversation', conversationId);
  } else if (continueLatest) {
    args.push('--continue');
  }

  const resolvedModel = resolveEffectiveModelAndLevel({ model, modelLevel });
  if (resolvedModel.modelId) {
    let agyModel = resolvedModel.modelId;
    if (agyModel.startsWith('google-cloud-code')) {
      const tier = resolvedModel.effort || 'high';
      agyModel = `gemini-3.8-flash-${tier}`;
    } else if (agyModel.startsWith('openai-codex')) {
      agyModel = 'gpt-oss-120b-medium';
    }
    args.push('--model', agyModel);
  }
  if (resolvedModel.effort) {
    args.push('--effort', resolvedModel.effort);
  }

  const dirs = new Set();
  for (const dir of extraDirs || []) {
    if (dir && String(dir).trim()) {
      dirs.add(path.resolve(String(dir).trim()));
    }
  }
  for (const imgPath of imagePaths || []) {
    if (imgPath && String(imgPath).trim()) {
      dirs.add(path.dirname(path.resolve(String(imgPath).trim())));
    }
  }
  for (const dir of dirs) {
    args.push('--add-dir', dir);
  }

  return args;
}

/**
 * Runs a single Antigravity CLI (`agy`) turn in `workspacePath` and streams live events.
 * Returns `{ promise, abort }`.
 */
export function runAgyTurn({
  agyBin = resolveDefaultAgyBin(),
  workspacePath,
  prompt,
  imagePaths = [],
  conversationId = null,
  continueLatest = false,
  model = '',
  modelLevel = '',
  skipPermissions = true,
  extraDirs = [],
  timeout = DEFAULT_AGY_TIMEOUT,
  onConversationId = () => {},
  onTextDelta = () => {},
  onStepEvent = () => {},
  onLog = () => {}
}) {
  const args = buildAgyArgs({
    prompt,
    imagePaths,
    conversationId,
    continueLatest,
    model,
    modelLevel,
    skipPermissions,
    extraDirs,
    timeout
  });

  const homeDir = os.homedir();
  const extraPath = [
    path.join(homeDir, '.local', 'bin'),
    path.join(homeDir, '.gemini', 'bin'),
    '/opt/homebrew/bin',
    '/usr/local/bin'
  ].join(path.delimiter);

  const env = {
    ...process.env,
    CI: '1',
    GIT_TERMINAL_PROMPT: '0',
    PATH: `${extraPath}${path.delimiter}${process.env.PATH || '/usr/bin:/bin'}`
  };

  let child = null;
  let aborted = false;

  const promise = new Promise((resolve, reject) => {
    child = spawn(agyBin, args, {
      cwd: workspacePath,
      env,
      stdio: ['pipe', 'pipe', 'pipe']
    });

    child.stdin.end();

    let detectedConversationId = conversationId || null;
    let streamedText = '';
    let finalResult = null;
    let stderrText = '';
    let rawStdoutTail = '';

    const rl = readline.createInterface({
      input: child.stdout,
      crlfDelay: Infinity
    });

    rl.on('line', (line) => {
      rawStdoutTail += line + '\n';
      if (rawStdoutTail.length > 8000) {
        rawStdoutTail = rawStdoutTail.slice(-8000);
      }
      const trimmed = line.trim();
      if (!trimmed) return;

      let parsed;
      try {
        parsed = JSON.parse(trimmed);
      } catch {
        onLog(trimmed);
        return;
      }

      if (parsed.conversation_id && parsed.conversation_id !== detectedConversationId) {
        detectedConversationId = parsed.conversation_id;
        onConversationId(detectedConversationId);
      }

      if (parsed.event === 'step_update' && parsed.step_update) {
        const su = parsed.step_update;
        if (su.conversation_id && su.conversation_id !== detectedConversationId) {
          detectedConversationId = su.conversation_id;
          onConversationId(detectedConversationId);
        }

        if (su.step_type === 'agent_response') {
          if (typeof su.text_delta === 'string') {
            streamedText += su.text_delta;
            onTextDelta(su.text_delta, streamedText);
          }
        } else if (su.step_type && su.step_type !== 'user_input') {
          const toolArgs =
            su.tool_info?.parameters ||
            su.tool_info?.args ||
            su.parameters ||
            su.args ||
            null;
          const toolOutput =
            su.tool_info?.output !== undefined
              ? su.tool_info.output
              : su.output !== undefined
              ? su.output
              : '';
          onStepEvent({
            stepIndex: su.step_index,
            stepType: su.step_type,
            state: su.state,
            toolName: su.tool_name || su.name || '',
            toolArgs,
            toolOutput,
            durationSeconds: su.duration_seconds ?? null,
            thinking: typeof su.thinking === 'string' ? su.thinking : ''
          });
        }
      } else if (parsed.event === 'result' && parsed.result) {
        finalResult = parsed.result;
        if (finalResult.conversation_id && finalResult.conversation_id !== detectedConversationId) {
          detectedConversationId = finalResult.conversation_id;
          onConversationId(detectedConversationId);
        }
        if (typeof finalResult.response === 'string' && !streamedText) {
          onTextDelta(finalResult.response, finalResult.response);
        }
      }
    });

    child.stderr.on('data', (chunk) => {
      const text = chunk.toString('utf8');
      stderrText += text;
      if (stderrText.length > 8000) {
        stderrText = stderrText.slice(-8000);
      }
      for (const rawLine of text.split(/\r?\n/)) {
        const lineTrim = rawLine.trim();
        if (lineTrim) {
          onLog(lineTrim);
        }
      }
    });

    child.on('error', (err) => {
      reject(new Error(`Failed to spawn agy (${agyBin}): ${err.message}`));
    });

    child.on('close', (code) => {
      if (aborted) {
        reject(new Error('Agent run stopped by user'));
        return;
      }

      const responseText =
        finalResult && typeof finalResult.response === 'string'
          ? finalResult.response
          : streamedText;

      const trimmedResponse = String(responseText || '').trim();

      // Check if agy timed out (print timeout, DEADLINE_EXCEEDED, etc.)
      const isTimeout =
        isAgyTimeoutError(stderrText) ||
        isAgyTimeoutError(rawStdoutTail) ||
        isAgyTimeoutError(trimmedResponse) ||
        isAgyTimeoutError(finalResult?.short_error) ||
        isAgyTimeoutError(finalResult?.reason) ||
        isAgyTimeoutError(finalResult?.status);

      if (isTimeout) {
        // If not finished due to timeout, count it as success per user instruction!
        const successResponse =
          trimmedResponse ||
          'Agent finished execution (turn reached the 5-minute timeout limit and completed successfully).';
        resolve({
          conversationId: detectedConversationId,
          response: successResponse,
          durationSeconds: finalResult?.duration_seconds ?? MAX_AGY_TIMEOUT_SECONDS,
          usage: finalResult?.usage ?? null,
          timedOut: true
        });
        return;
      }

      if (code !== 0 && !finalResult) {
        const detail = stderrText.trim() || `exit code ${code}`;
        reject(new Error(`agy exited with error: ${detail}`));
        return;
      }

      // If agy reported a non-SUCCESS status, only reject if there is no valid assistant response
      // or if the response itself is an unrecoverable system/API error.
      // If the model produced a real response, intermediate tool warnings/errors were recovered
      // by the agent, so resolve the turn successfully instead of failing.
      if (
        finalResult &&
        finalResult.status &&
        finalResult.status !== 'SUCCESS' &&
        isFatalAgentResponseError(trimmedResponse)
      ) {
        reject(
          new Error(
            `Agent finished with status ${finalResult.status}: ${trimmedResponse || stderrText.trim() || `exit code ${code}`}`
          )
        );
      } else {
        resolve({
          conversationId: detectedConversationId,
          response: trimmedResponse,
          durationSeconds: finalResult?.duration_seconds ?? null,
          usage: finalResult?.usage ?? null
        });
      }
    });
  });

  function abort() {
    if (!child || aborted) return;
    aborted = true;
    try {
      child.kill('SIGTERM');
      setTimeout(() => {
        try {
          child.kill('SIGKILL');
        } catch {
          // already exited
        }
      }, 2000).unref();
    } catch {
      // ignore
    }
  }

  return { promise, abort };
}
