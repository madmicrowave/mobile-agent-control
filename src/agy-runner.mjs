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
    shortCode: 'gpt120',
    family: 'gpt-oss-120b-medium',
    label: 'GPT-OSS 120B',
    aliases: ['gpt-oss', 'gpt-oss-120b', 'gpt-oss-120b-medium'],
    tieredLevels: []
  }
];

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
  timeout = '30m0s'
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
  const args = ['-p', fullPrompt, '--output-format', 'stream-json', '--print-timeout', timeout];

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
    args.push('--model', resolvedModel.modelId);
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
  onConversationId = () => {},
  onTextDelta = () => {},
  onStepEvent = () => {}
}) {
  const args = buildAgyArgs({
    prompt,
    imagePaths,
    conversationId,
    continueLatest,
    model,
    modelLevel,
    skipPermissions,
    extraDirs
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

    const rl = readline.createInterface({
      input: child.stdout,
      crlfDelay: Infinity
    });

    rl.on('line', (line) => {
      const trimmed = line.trim();
      if (!trimmed) return;

      let parsed;
      try {
        parsed = JSON.parse(trimmed);
      } catch {
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
          onStepEvent({
            stepIndex: su.step_index,
            stepType: su.step_type,
            state: su.state,
            toolName: su.tool_name || su.name || ''
          });
        }
      } else if (parsed.event === 'result' && parsed.result) {
        finalResult = parsed.result;
        if (finalResult.conversation_id && finalResult.conversation_id !== detectedConversationId) {
          detectedConversationId = finalResult.conversation_id;
          onConversationId(detectedConversationId);
        }
      }
    });

    child.stderr.on('data', (chunk) => {
      stderrText += chunk.toString('utf8');
      if (stderrText.length > 8000) {
        stderrText = stderrText.slice(-8000);
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

      if (code !== 0 && !finalResult) {
        const detail = stderrText.trim() || `exit code ${code}`;
        reject(new Error(`agy exited with error: ${detail}`));
        return;
      }

      const responseText =
        finalResult && typeof finalResult.response === 'string'
          ? finalResult.response
          : streamedText;

      if (finalResult && finalResult.status && finalResult.status !== 'SUCCESS') {
        reject(
          new Error(
            `Agent finished with status ${finalResult.status}: ${responseText || stderrText.trim()}`
          )
        );
      } else {
        resolve({
          conversationId: detectedConversationId,
          response: responseText.trim(),
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
