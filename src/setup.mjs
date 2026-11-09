import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import readline from 'node:readline/promises';
import { stdin as input, stdout as output } from 'node:process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { loadProjectDotEnv } from './env-loader.mjs';
import {
  ConfigStore,
  expandUserPath,
  getCandidateScanRoots,
  parseJenkinsfileJobName,
  scanCandidateWorkspaces,
  slugifyWorkspaceId
} from './config.mjs';
import {
  GEMINI_MODEL_FAMILIES,
  VALID_MODEL_LEVELS,
  discoverGeminiModelFamilies,
  resolveEffectiveModelAndLevel
} from './agy-runner.mjs';
import { runGit } from './git-manager.mjs';
import { JenkinsClient } from './jenkins-client.mjs';
import { TelegramApi } from './telegram-api.mjs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
export const PROJECT_ROOT = path.resolve(__dirname, '..');

function maskSecret(val) {
  const s = String(val || '');
  if (!s) return 'not set';
  if (s.length <= 8) return '****';
  return `${s.slice(0, 4)}...${s.slice(-4)}`;
}

function parseYesNo(answer, defaultBool = true) {
  const s = String(answer || '').trim().toLowerCase();
  if (!s) return defaultBool;
  if (['y', 'yes', 'true', '1'].includes(s)) return true;
  if (['n', 'no', 'false', '0'].includes(s)) return false;
  return defaultBool;
}

function parseModelSelection(
  answer,
  fallbackModel = 'gemini-3.8-flash',
  families = GEMINI_MODEL_FAMILIES
) {
  const raw = String(answer || '').trim();
  if (!raw) return fallbackModel;
  const lower = raw.toLowerCase();
  if (['default', 'auto', 'none', '-'].includes(lower)) {
    return 'gemini-3.8-flash';
  }
  if (/^\d+$/.test(raw)) {
    const idx = Number(raw) - 1;
    if (idx >= 0 && idx < families.length) {
      return families[idx].family;
    }
  }
  const suffixMatch = lower.match(/^(.*)-(low|medium|high)$/);
  const baseCandidate = suffixMatch ? suffixMatch[1] : lower;
  const matched = families.find(
    (fam) =>
      fam.shortCode === lower ||
      fam.family === lower ||
      fam.family === baseCandidate ||
      fam.aliases.includes(lower) ||
      fam.aliases.includes(baseCandidate)
  );
  return matched ? matched.family : fallbackModel;
}

function parseModelLevelSelection(answer, fallbackLevel = 'high') {
  const raw = String(answer || '').trim().toLowerCase();
  if (!raw) return VALID_MODEL_LEVELS.includes(fallbackLevel) ? fallbackLevel : 'high';
  if (['default', 'auto', 'none', '-'].includes(raw)) {
    return 'high';
  }
  if (/^\d+$/.test(raw)) {
    const idx = Number(raw) - 1;
    if (idx >= 0 && idx < VALID_MODEL_LEVELS.length) {
      return VALID_MODEL_LEVELS[idx];
    }
  }
  if (VALID_MODEL_LEVELS.includes(raw)) {
    return raw;
  }
  return VALID_MODEL_LEVELS.includes(fallbackLevel) ? fallbackLevel : 'high';
}

export function parseEnvironmentMode(answer, fallback = 'single') {
  const raw = String(answer || '').trim().toLowerCase();
  if (!raw) return fallback === 'multi' ? 'multi' : 'single';
  if (['1', 's', 'single'].includes(raw)) return 'single';
  if (['2', 'm', 'multi', 'prod', 'staging+prod', 'staging/prod'].includes(raw)) return 'multi';
  return fallback === 'multi' ? 'multi' : 'single';
}

export function cleanJenkinsJobInput(raw) {
  let input = String(raw || '').trim();
  if (!input || input === '-' || input.toLowerCase() === 'none') return '';

  if (/^https?:\/\//i.test(input)) {
    try {
      const parsed = new URL(input);
      input = parsed.pathname;
    } catch {
      // keep raw input
    }
  }

  input = input.replace(/^\/+|\/+$/g, '');
  if (!input) return '';

  if (/^job\//i.test(input) || /\/job\//i.test(input)) {
    const parts = input
      .split(/\/?job\//i)
      .map((seg) => {
        try {
          return decodeURIComponent(seg.trim());
        } catch {
          return seg.trim();
        }
      })
      .filter(Boolean);
    return parts.join('/');
  }

  return input;
}

async function detectCurrentGitBranch(repoPath) {
  try {
    const { stdout } = await runGit(repoPath, ['branch', '--show-current'], { timeoutMs: 5_000 });
    if (stdout.trim()) return stdout.trim();
  } catch {
    // ignore
  }
  return 'main';
}

/**
 * Scans `workspacePath` (both root and all immediate non-hidden child folders),
 * returning `{ gitRepos, nonGitFolders }` with detected Git branches and Jenkinsfile hints.
 */
export async function scanWorkspaceDirectoryForSetup(workspacePath) {
  const resolvedRoot = expandUserPath(workspacePath);
  const gitRepos = [];
  const nonGitFolders = [];

  async function inspectGitDir(dirPath, relName) {
    try {
      await fsp.access(path.join(dirPath, '.git'));
    } catch {
      return null;
    }

    let detectedJob = '';
    try {
      const jf = await fsp.readFile(path.join(dirPath, 'Jenkinsfile'), 'utf8');
      detectedJob = parseJenkinsfileJobName(jf) || '';
    } catch {
      // No Jenkinsfile
    }

    const detectedBranch = await detectCurrentGitBranch(dirPath);
    return {
      name: relName,
      path: dirPath,
      detectedBranch,
      detectedJob
    };
  }

  const rootRepo = await inspectGitDir(resolvedRoot, path.basename(resolvedRoot));
  if (rootRepo) {
    gitRepos.push(rootRepo);
  }

  let entries = [];
  try {
    entries = await fsp.readdir(resolvedRoot, { withFileTypes: true });
  } catch {
    entries = [];
  }

  const childDirs = entries
    .filter((e) => e.isDirectory() && !e.name.startsWith('.') && e.name !== 'node_modules')
    .sort((a, b) => a.name.localeCompare(b.name));

  for (const entry of childDirs) {
    const fullChild = path.join(resolvedRoot, entry.name);
    const repoInfo = await inspectGitDir(fullChild, entry.name);
    if (repoInfo) {
      gitRepos.push(repoInfo);
    } else {
      nonGitFolders.push(entry.name);
    }
  }

  return { resolvedRoot, gitRepos, nonGitFolders };
}

/**
 * Tests Jenkins connectivity in the local terminal console without exposing credentials in Telegram.
 */
export async function runTestJenkinsConsole({
  dataDir = path.join(PROJECT_ROOT, 'data'),
  store = null,
  cfg = null,
  jenkinsFactory = (j) => new JenkinsClient(j),
  log = console.log,
  warn = console.warn
} = {}) {
  let activeCfg = cfg;
  if (!activeCfg) {
    loadProjectDotEnv(PROJECT_ROOT);
    const resolvedStore = store || new ConfigStore(dataDir);
    if (!store) {
      await resolvedStore.init();
    }
    activeCfg = resolvedStore.config;
  }

  const jenkinsCfg = activeCfg?.jenkins || {};
  if (!String(jenkinsCfg.baseUrl || '').trim()) {
    warn('  ⚠️  Jenkins Base URL is not configured yet.');
    return { ok: false, jobs: [], error: 'Jenkins Base URL is not configured' };
  }

  log(`  🔌 Testing Jenkins connection to ${jenkinsCfg.baseUrl} ...`);
  try {
    const client = jenkinsFactory(jenkinsCfg);
    const res = await client.testConnection();
    const jobs = res.jobs || [];
    const sample = jobs.slice(0, 10).join(', ');
    log(`  ✅ Jenkins Connected! Found ${jobs.length} job(s).`);
    if (sample) {
      log(`     Sample jobs: ${sample}${jobs.length > 10 ? ' ...' : ''}`);
    }
    return { ok: true, jobs };
  } catch (err) {
    const message = err.message || String(err);
    warn(`  ❌ Jenkins Connection Failed: ${message}`);
    return { ok: false, jobs: [], error: message };
  }
}

/**
 * Interactive console prompt to configure/update Jenkins URL, Username, and API Token,
 * and optionally test connectivity directly in the terminal.
 */
export async function runConfigureJenkinsWizard({
  dataDir = path.join(PROJECT_ROOT, 'data'),
  store = null,
  ask,
  log = console.log,
  warn = console.warn,
  testJenkins = true,
  jenkinsFactory = (j) => new JenkinsClient(j),
  stepOffset = null,
  showBanner = false
} = {}) {
  loadProjectDotEnv(PROJECT_ROOT);

  const activeStore = store || new ConfigStore(dataDir);
  if (!store) {
    await activeStore.init();
  }
  const cfg = activeStore.config;

  if (showBanner) {
    log('');
    log('============================================================');
    log('  Antigravity IDE — Update Jenkins Configuration (Console)');
    log('============================================================');
    log('Press Enter on any prompt to keep the current value in [brackets].');
    log('');
  }

  const n1 = stepOffset !== null ? `${stepOffset}. ` : '1. ';
  const n2 = stepOffset !== null ? `${stepOffset + 1}. ` : '2. ';
  const n3 = stepOffset !== null ? `${stepOffset + 2}. ` : '3. ';

  while (true) {
    const jUrlDefault = cfg.jenkins.baseUrl || 'none';
    const jUrlAns = (
      await ask(`${n1}Jenkins Base URL (e.g. https://jenkins.example.com, or "-" for none) [${jUrlDefault}]: `)
    ).trim();
    if (jUrlAns === '-' || jUrlAns.toLowerCase() === 'none') {
      cfg.jenkins.baseUrl = '';
    } else if (jUrlAns) {
      cfg.jenkins.baseUrl = jUrlAns.replace(/\/+$/, '');
    }

    const jUserAns = (
      await ask(`${n2}Jenkins Username [${cfg.jenkins.username || 'none'}]: `)
    ).trim();
    if (jUserAns === '-' || jUserAns.toLowerCase() === 'none') {
      cfg.jenkins.username = '';
    } else if (jUserAns) {
      cfg.jenkins.username = jUserAns;
    }

    const jTokAns = (
      await ask(`${n3}Jenkins API Token [${maskSecret(cfg.jenkins.apiToken)}]: `)
    ).trim();
    if (jTokAns === '-' || jTokAns.toLowerCase() === 'none') {
      cfg.jenkins.apiToken = '';
    } else if (jTokAns) {
      cfg.jenkins.apiToken = jTokAns;
    }

    await activeStore.saveConfig();

    if (testJenkins && cfg.jenkins.baseUrl) {
      const shouldTest = parseYesNo(
        await ask('   Test Jenkins connection now? (y/n) [y]: '),
        true
      );
      if (shouldTest) {
        const testRes = await runTestJenkinsConsole({
          cfg,
          jenkinsFactory,
          log,
          warn
        });
        if (!testRes.ok) {
          const retry = parseYesNo(
            await ask('   Re-enter Jenkins URL & credentials? (y/n) [n]: '),
            false
          );
          if (retry) {
            log('');
            continue;
          }
        }
      }
    }

    break;
  }

  if (showBanner) {
    log('');
    log(`Saved Jenkins configuration to ${activeStore.configFile} (permissions 0600).`);
    log('');
  }

  return activeStore;
}

/**
 * Interactive console wizard to scan/discover unregistered available IDEs, add new IDE workspaces,
 * edit existing workspaces, and configure per-IDE Gemini models/levels and Jenkins jobs.
 */
export async function runWorkspacesWizard({
  dataDir = path.join(PROJECT_ROOT, 'data'),
  store = null,
  ask,
  log = console.log,
  warn = console.warn,
  queryCliModels = true,
  mode = 'setup'
} = {}) {
  loadProjectDotEnv(PROJECT_ROOT);

  const activeStore = store || new ConfigStore(dataDir);
  if (!store) {
    await activeStore.init();
  }
  const cfg = activeStore.config;

  const geminiFamilies = await discoverGeminiModelFamilies(cfg.agyBin, {
    queryCli: Boolean(queryCliModels)
  });

  async function askWorkspaceGeminiModelAndLevel(existingWs = null) {
    log('\n  AI Models:');
    geminiFamilies.forEach((fam, idx) => {
      log(`    ${idx + 1}) ${fam.family.padEnd(20)} — ${fam.label}`);
    });
    const fallbackModel = existingWs?.model || cfg.defaultModel || 'gemini-3.8-flash';
    const rawModelAns = await ask(
      `  AI model (1-${geminiFamilies.length}) [${fallbackModel}]: `
    );
    const selectedModelInput = parseModelSelection(rawModelAns, fallbackModel, geminiFamilies);

    const rawExistingLvl = String(existingWs?.modelLevel || cfg.defaultModelLevel || 'high').toLowerCase();
    const fallbackLevel = VALID_MODEL_LEVELS.includes(rawExistingLvl) ? rawExistingLvl : 'high';
    const rawLevelAns = await ask(
      `  Model level (${VALID_MODEL_LEVELS.join(' / ')}) [${fallbackLevel}]: `
    );
    const selectedLevelInput = parseModelLevelSelection(rawLevelAns, fallbackLevel);

    const resolvedAgent = resolveEffectiveModelAndLevel({
      model: selectedModelInput,
      modelLevel: selectedLevelInput
    });
    return {
      wsModel: resolvedAgent.modelId || selectedModelInput || 'gemini-3.8-flash-high',
      wsModelLevel: resolvedAgent.effort || selectedLevelInput || 'high',
      resolvedAgent
    };
  }

  log('');
  log('------------------------------------------------------------');
  log(
    mode === 'add-ide'
      ? '  Register / Add Available IDE Workspace (Console)'
      : '  7. Workspaces Setup (Register Available IDEs, AI Model & Jenkins Jobs)'
  );
  log('------------------------------------------------------------');

  while (true) {
    if (cfg.workspaces.length > 0) {
      log('');
      log(`Configured workspaces (${cfg.workspaces.length}):`);
      cfg.workspaces.forEach((ws, i) => {
        const deployCount = (ws.repos || []).filter((r) => r.deployEnabled && r.jenkinsJob).length;
        const prodCount = (ws.prodJenkinsJobs || []).length;
        const envBadge = ws.environmentMode === 'multi' ? `multi (${prodCount} prod)` : 'single';
        const resolvedModel = resolveEffectiveModelAndLevel({
          model: ws.model || cfg.defaultModel || 'gemini-3.8-flash',
          modelLevel: ws.modelLevel || cfg.defaultModelLevel || 'high'
        });
        log(
          `  ${i + 1}) ${ws.label || ws.id} (${ws.id}) — ${ws.path} [Model: ${resolvedModel.displayLabel}, Env: ${envBadge}] (${(ws.repos || []).length} repos, ${deployCount} deployable)`
        );
      });
    } else {
      log('');
      log('No workspaces configured yet.');
    }

    const existingPaths = new Set((cfg.workspaces || []).map((w) => path.resolve(w.path)));
    const candidateRoots = getCandidateScanRoots(cfg.workspaces || []);
    const candidates = (await scanCandidateWorkspaces(candidateRoots, existingPaths)).slice(0, 12);

    if (candidates.length > 0) {
      log('');
      log(`Available unregistered IDE folders discovered (${candidates.length}):`);
      candidates.forEach((cand, idx) => {
        log(
          `  +${idx + 1}) ${cand.name} — ${cand.path} (${cand.repoCount} repo${cand.repoCount === 1 ? '' : 's'})`
        );
      });
    }

    log('');
    log('Options:');
    log('  • Paste a workspace directory path to scan & register/update it');
    if (candidates.length > 0) {
      log('  • Enter "+<number>" (e.g. "+1") to register a discovered available IDE');
    }
    if (cfg.workspaces.length > 0) {
      log('  • Enter a workspace number (e.g. "1") to re-scan & edit it');
      log('  • Enter "model <number>" (or "models") to change AI model & level');
      log('  • Enter "remove <number>" (or "clear") to unregister workspace(s)');
    }
    log('  • Press Enter on an empty line when finished');

    const promptLabel =
      mode === 'add-ide'
        ? '\nPaste workspace directory path or +<number> (or Enter to finish): '
        : '\n7. Paste workspace directory path or +<number> (or Enter to finish): ';
    const rawSelection = (await ask(promptLabel)).trim();

    if (!rawSelection) {
      break;
    }

    if (rawSelection.toLowerCase() === 'models') {
      for (const ws of cfg.workspaces) {
        const wsLabel = ws.label || ws.id;
        log(`\n--- AI Model Setup for "${wsLabel}" ---`);
        const { wsModel, wsModelLevel, resolvedAgent } = await askWorkspaceGeminiModelAndLevel(ws);
        ws.model = wsModel;
        ws.modelLevel = wsModelLevel;
        log(`  Updated "${wsLabel}" -> ${resolvedAgent.displayLabel}`);
      }
      await activeStore.saveConfig();
      continue;
    }

    const quickModelMatch = rawSelection.match(/^model\s+(\d+)$/i);
    if (quickModelMatch) {
      const idx = Number(quickModelMatch[1]) - 1;
      if (idx >= 0 && idx < cfg.workspaces.length) {
        const ws = cfg.workspaces[idx];
        const wsLabel = ws.label || ws.id;
        log(`\n--- AI Model Setup for "${wsLabel}" ---`);
        const { wsModel, wsModelLevel, resolvedAgent } = await askWorkspaceGeminiModelAndLevel(ws);
        ws.model = wsModel;
        ws.modelLevel = wsModelLevel;
        await activeStore.saveConfig();
        log(`Updated "${wsLabel}" -> ${resolvedAgent.displayLabel}.`);
      } else {
        warn('Invalid workspace number.');
      }
      continue;
    }

    if (rawSelection.toLowerCase() === 'clear') {
      const confirmClear = parseYesNo(
        await ask('Remove ALL configured workspaces from config.json? (y/n) [n]: '),
        false
      );
      if (confirmClear) {
        cfg.workspaces = [];
        await activeStore.saveConfig();
        log('Cleared all workspaces.');
      }
      continue;
    }

    const removeMatch = rawSelection.match(/^remove\s+(\d+)$/i);
    if (removeMatch) {
      const idx = Number(removeMatch[1]) - 1;
      if (idx >= 0 && idx < cfg.workspaces.length) {
        const [removed] = cfg.workspaces.splice(idx, 1);
        await activeStore.saveConfig();
        log(`Removed workspace "${removed.label || removed.id}".`);
      } else {
        warn('Invalid workspace number.');
      }
      continue;
    }

    let targetPath = '';
    let existingWs = null;

    const candMatch = rawSelection.match(/^(?:\+|add\s+|cand\s+)(\d+)$/i);
    if (candMatch) {
      const cIdx = Number(candMatch[1]) - 1;
      if (cIdx < 0 || cIdx >= candidates.length) {
        warn(`Invalid available IDE number: +${candMatch[1]}`);
        continue;
      }
      targetPath = candidates[cIdx].path;
      existingWs =
        cfg.workspaces.find((w) => path.resolve(w.path) === path.resolve(targetPath)) || null;
    } else if (/^\d+$/.test(rawSelection)) {
      const idx = Number(rawSelection) - 1;
      if (idx < 0 || idx >= cfg.workspaces.length) {
        warn(`Invalid workspace number: ${rawSelection}`);
        continue;
      }
      existingWs = cfg.workspaces[idx];
      const pathOverride = (
        await ask(`Workspace directory path [${existingWs.path}]: `)
      ).trim();
      targetPath = pathOverride ? expandUserPath(pathOverride) : existingWs.path;
    } else {
      targetPath = expandUserPath(rawSelection);
      existingWs =
        cfg.workspaces.find((w) => path.resolve(w.path) === path.resolve(targetPath)) || null;
    }

    if (!targetPath || !fs.existsSync(targetPath)) {
      warn(`Directory does not exist: ${targetPath || rawSelection}`);
      continue;
    }

    const stat = await fsp.stat(targetPath);
    if (!stat.isDirectory()) {
      warn(`Path is not a directory: ${targetPath}`);
      continue;
    }

    const defaultId = existingWs?.id || slugifyWorkspaceId(path.basename(targetPath)).slice(0, 20);
    const wsIdAns = (await ask(`Workspace ID [${defaultId}]: `)).trim();
    let wsId =
      existingWs?.id && !wsIdAns
        ? existingWs.id
        : slugifyWorkspaceId(wsIdAns || defaultId).slice(0, 24);

    if (!existingWs || wsId !== existingWs.id) {
      let n = 1;
      const baseSlug = wsId;
      while (cfg.workspaces.some((w) => w !== existingWs && w.id === wsId)) {
        wsId = `${baseSlug.slice(0, 20)}-${n++}`;
      }
    }

    const defaultLabel = existingWs?.label || path.basename(targetPath);
    const wsLabelAns = (await ask(`Workspace display label [${defaultLabel}]: `)).trim();
    const wsLabel = wsLabelAns || defaultLabel;

    // ── AI Model & Model Level Selection ─────────────────────────────────────
    const { wsModel, wsModelLevel, resolvedAgent } =
      await askWorkspaceGeminiModelAndLevel(existingWs);

    const defaultLiveUrl = existingWs?.liveUrl || 'none';
    const liveUrlAns = (
      await ask(`Live URL (optional, "-" for none) [${defaultLiveUrl}]: `)
    ).trim();
    const wsLiveUrl =
      liveUrlAns === '-' || liveUrlAns.toLowerCase() === 'none'
        ? ''
        : liveUrlAns || existingWs?.liveUrl || '';

    const defaultExtraDirs = (existingWs?.extraDirs || []).join(', ') || 'none';
    const extraDirsAns = (
      await ask(`Extra --add-dir paths (comma-separated, "-" for none) [${defaultExtraDirs}]: `)
    ).trim();
    let wsExtraDirs = existingWs?.extraDirs ? [...existingWs.extraDirs] : [];
    if (extraDirsAns === '-' || extraDirsAns.toLowerCase() === 'none') {
      wsExtraDirs = [];
    } else if (extraDirsAns) {
      wsExtraDirs = extraDirsAns
        .split(',')
        .map((p) => expandUserPath(p))
        .filter(Boolean);
    }

    const defaultEnvMode =
      existingWs?.environmentMode === 'multi' || (existingWs?.prodJenkinsJobs?.length || 0) > 0
        ? 'multi'
        : 'single';
    const envModeAns = (
      await ask(
        `Deployment environments ("single" or "multi" for staging + production) [${defaultEnvMode}]: `
      )
    ).trim();
    const wsEnvironmentMode = parseEnvironmentMode(envModeAns, defaultEnvMode);

    log(`\nScanning folders inside ${targetPath} ...`);
    const { gitRepos, nonGitFolders } = await scanWorkspaceDirectoryForSetup(targetPath);

    if (nonGitFolders.length > 0) {
      log(`  (Ignored non-git subfolders: ${nonGitFolders.join(', ')})`);
    }

    if (gitRepos.length === 0) {
      warn(`No Git repositories (.git) found inside ${targetPath}.`);
      continue;
    }

    log(`Found ${gitRepos.length} Git repositor${gitRepos.length === 1 ? 'y' : 'ies'}:`);
    for (const r of gitRepos) {
      log(`  • ${r.name} (${r.path}, branch: ${r.detectedBranch})`);
    }

    const prevRepoMap = Object.fromEntries(
      (existingWs?.repos || []).map((r) => [r.name, r])
    );

    const configuredRepos = [];

    for (let i = 0; i < gitRepos.length; i++) {
      const cand = gitRepos[i];
      const prev = prevRepoMap[cand.name];
      const defaultInclude = existingWs ? Boolean(prev) : true;

      log(`\n  --- Repo [${i + 1}/${gitRepos.length}]: ${cand.name} ---`);
      const includeRepo = parseYesNo(
        await ask(`  Include "${cand.name}" in workspace? (y/n) [${defaultInclude ? 'y' : 'n'}]: `),
        defaultInclude
      );
      if (!includeRepo) {
        continue;
      }

      const defaultRepoPath = prev?.path || cand.path;
      const repoPathAns = (await ask(`  Repo path [${defaultRepoPath}]: `)).trim();
      const finalRepoPath = repoPathAns ? expandUserPath(repoPathAns) : defaultRepoPath;

      const defaultBranch =
        prev?.branch !== undefined && prev.branch !== ''
          ? prev.branch
          : cand.detectedBranch || 'main';
      const branchAns = (
        await ask(
          `  Git branch (or "auto" to always use checked-out branch) [${defaultBranch}]: `
        )
      ).trim();
      const finalBranch =
        branchAns.toLowerCase() === 'auto' ? '' : branchAns || defaultBranch;

      const defaultDeploy =
        prev?.deployEnabled !== undefined
          ? Boolean(prev.deployEnabled)
          : Boolean(prev?.jenkinsJob || cand.detectedJob);
      const deployEnabledChoice = parseYesNo(
        await ask(
          `  Enable Jenkins deploy for "${cand.name}"? (y/n) [${defaultDeploy ? 'y' : 'n'}]: `
        ),
        defaultDeploy
      );

      let finalJenkinsJob = '';
      let finalProdJenkinsJob = '';
      let finalDeployEnabled = false;

      if (deployEnabledChoice) {
        const jobHint = prev?.jenkinsJob || cand.detectedJob || '';
        if (wsEnvironmentMode === 'multi') {
          const stgPrompt = jobHint
            ? `  Staging Jenkins job link/path for "${cand.name}" [${jobHint}]: `
            : `  Staging Jenkins job link/path for "${cand.name}" (required, or "-" to disable): `;
          while (!finalJenkinsJob) {
            const stgAns = (await ask(stgPrompt)).trim();
            if (stgAns === '-' || stgAns.toLowerCase() === 'none') {
              break;
            }
            finalJenkinsJob = cleanJenkinsJobInput(stgAns) || jobHint;
            if (!finalJenkinsJob) {
              warn(
                `  Staging Jenkins job link/path is required in multi-environment mode (or enter "-" to disable deploy for "${cand.name}").`
              );
            }
          }

          finalDeployEnabled = Boolean(finalJenkinsJob);
          if (!finalJenkinsJob) {
            log(`  (No Staging Jenkins job entered — deploy disabled for "${cand.name}".)`);
          } else {
            const prodHint = prev?.prodJenkinsJob || '';
            const prodPrompt = prodHint
              ? `  Production Jenkins job link/path for "${cand.name}" [${prodHint}]: `
              : `  Production Jenkins job link/path for "${cand.name}" (required for multi-env): `;
            while (!finalProdJenkinsJob) {
              const prodAns = (await ask(prodPrompt)).trim();
              if (prodAns === '-' || prodAns.toLowerCase() === 'none') {
                break;
              }
              finalProdJenkinsJob = cleanJenkinsJobInput(prodAns) || prodHint;
              if (!finalProdJenkinsJob) {
                warn('  Production Jenkins job link/path is required in multi-environment mode.');
              }
            }
          }
        } else {
          const jobPrompt = jobHint
            ? `  Jenkins job name/path for "${cand.name}" [${jobHint}]: `
            : `  Jenkins job name/path for "${cand.name}" (e.g. Folder/service-job): `;
          const jobAns = (await ask(jobPrompt)).trim();
          finalJenkinsJob =
            jobAns === '-' || jobAns.toLowerCase() === 'none'
              ? ''
              : cleanJenkinsJobInput(jobAns) || jobHint;
          finalDeployEnabled = Boolean(finalJenkinsJob);
          if (!finalJenkinsJob) {
            log(`  (No Jenkins job entered — deploy disabled for "${cand.name}".)`);
          }
        }
      }

      configuredRepos.push({
        name: cand.name,
        path: finalRepoPath,
        jenkinsJob: finalJenkinsJob,
        prodJenkinsJob: wsEnvironmentMode === 'multi' ? finalProdJenkinsJob : '',
        branch: finalBranch,
        deployEnabled: finalDeployEnabled
      });
    }

    const repoJobSet = new Set(
      configuredRepos.filter((r) => r.deployEnabled && r.jenkinsJob).map((r) => r.jenkinsJob)
    );
    const prevExtraJobs = (existingWs?.jenkinsJobs || []).filter((j) => !repoJobSet.has(j));
    const extraJobsDefault = prevExtraJobs.join(', ') || 'none';
    const extraJobsLabel =
      wsEnvironmentMode === 'multi'
        ? `\nAdditional workspace-level Staging Jenkins jobs (comma-separated, "-" for none) [${extraJobsDefault}]: `
        : `\nAdditional workspace-level Jenkins jobs (comma-separated, "-" for none) [${extraJobsDefault}]: `;
    const extraJobsAns = (await ask(extraJobsLabel)).trim();

    let extraWsJobs = prevExtraJobs;
    if (extraJobsAns === '-' || extraJobsAns.toLowerCase() === 'none') {
      extraWsJobs = [];
    } else if (extraJobsAns) {
      extraWsJobs = extraJobsAns
        .split(',')
        .map((s) => cleanJenkinsJobInput(s))
        .filter(Boolean);
    }

    let combinedJenkinsJobs = [...new Set([...repoJobSet, ...extraWsJobs])];

    let combinedProdJenkinsJobs = [];
    if (wsEnvironmentMode === 'multi') {
      while (combinedJenkinsJobs.length === 0) {
        warn('Multi-environment workspace requires at least one Staging Jenkins job link/path.');
        const reqStgAns = (
          await ask('Staging Jenkins job link(s)/path(s) (comma-separated): ')
        ).trim();
        combinedJenkinsJobs = [
          ...new Set(
            reqStgAns
              .split(',')
              .map((s) => cleanJenkinsJobInput(s))
              .filter(Boolean)
          )
        ];
      }

      const repoProdJobSet = new Set(
        configuredRepos
          .filter((r) => r.deployEnabled && r.prodJenkinsJob)
          .map((r) => r.prodJenkinsJob)
      );
      const prevExtraProdJobs = (existingWs?.prodJenkinsJobs || []).filter(
        (j) => !repoProdJobSet.has(j)
      );
      const extraProdDefault = prevExtraProdJobs.join(', ') || 'none';
      const extraProdAns = (
        await ask(
          `Additional workspace-level Production Jenkins jobs (comma-separated, "-" for none) [${extraProdDefault}]: `
        )
      ).trim();

      let extraProdJobs = prevExtraProdJobs;
      if (extraProdAns === '-' || extraProdAns.toLowerCase() === 'none') {
        extraProdJobs = [];
      } else if (extraProdAns) {
        extraProdJobs = extraProdAns
          .split(',')
          .map((s) => cleanJenkinsJobInput(s))
          .filter(Boolean);
      }

      combinedProdJenkinsJobs = [...new Set([...repoProdJobSet, ...extraProdJobs])];

      while (combinedProdJenkinsJobs.length === 0) {
        warn('Multi-environment workspace requires at least one Production Jenkins job link/path.');
        const reqProdAns = (
          await ask('Production Jenkins job link(s)/path(s) (comma-separated): ')
        ).trim();
        combinedProdJenkinsJobs = [
          ...new Set(
            reqProdAns
              .split(',')
              .map((s) => cleanJenkinsJobInput(s))
              .filter(Boolean)
          )
        ];
      }
    }

    const workspaceRecord = {
      id: wsId,
      label: wsLabel,
      path: targetPath,
      extraDirs: wsExtraDirs,
      liveUrl: wsLiveUrl,
      environmentMode: wsEnvironmentMode,
      jenkinsJobs: combinedJenkinsJobs,
      prodJenkinsJobs: wsEnvironmentMode === 'multi' ? combinedProdJenkinsJobs : [],
      model: wsModel,
      modelLevel: wsModelLevel,
      repos: configuredRepos
    };

    const existingIdx = existingWs
      ? cfg.workspaces.indexOf(existingWs)
      : cfg.workspaces.findIndex((w) => w.id === wsId);
    if (existingIdx !== -1) {
      cfg.workspaces[existingIdx] = workspaceRecord;
    } else {
      cfg.workspaces.push(workspaceRecord);
    }

    await activeStore.saveConfig();
    log(
      `\nSaved workspace "${wsLabel}" (${wsId}) [Model: ${resolvedAgent.displayLabel}, Env: ${wsEnvironmentMode}] (${configuredRepos.length} repo(s), ${combinedJenkinsJobs.length} staging/default job(s)${wsEnvironmentMode === 'multi' ? `, ${combinedProdJenkinsJobs.length} prod job(s)` : ''}).`
    );
  }

  await activeStore.saveConfig();
  return activeStore;
}

/**
 * Standalone console flow for `npm run add-ide` (or `add-ide` inside `npm start`).
 */
export async function runAddIdeWizard(opts = {}) {
  return runWorkspacesWizard({
    ...opts,
    mode: 'add-ide'
  });
}

/**
 * Full interactive setup wizard supporting:
 * - Telegram Bot Token & Allowed User IDs
 * - Fixed Latest X Messages count
 * - Jenkins Base URL, Username, API Token & Console Connection Test
 * - Auto-discovery & registration of available IDEs, Gemini models/levels, and Jenkins jobs
 */
export async function runSetupWizard({
  dataDir = path.join(PROJECT_ROOT, 'data'),
  store = null,
  ask,
  log = console.log,
  warn = console.warn,
  verifyTelegram = true,
  testJenkins = undefined,
  jenkinsFactory = (j) => new JenkinsClient(j)
} = {}) {
  loadProjectDotEnv(PROJECT_ROOT);

  const activeStore = store || new ConfigStore(dataDir);
  if (!store) {
    await activeStore.init();
  }
  const cfg = activeStore.config;

  log('');
  log('============================================================');
  log('  Antigravity IDE — Telegram Bot Setup Wizard');
  log('============================================================');
  log('Press Enter on any prompt to accept the value shown in [brackets].');
  log('(IDE registration & Jenkins auth live strictly in console setup — never in Telegram.)');
  log('(Session password is entered fresh each time you run "npm start".)');
  log('');

  // ── Steps 1–3: Core Bot & History Count ────────────────────────────────────
  const tokenAns = (
    await ask(`1. Telegram Bot Token from @BotFather [${maskSecret(cfg.telegramBotToken)}]: `)
  ).trim();
  if (tokenAns) {
    cfg.telegramBotToken = tokenAns;
  }

  const curAllow = (cfg.allowedUserIds || []).join(', ') || 'anyone with run password';
  const allowAns = (
    await ask(`2. Allowed Telegram User IDs (comma-separated, or "all") [${curAllow}]: `)
  ).trim();
  if (allowAns.toLowerCase() === 'all' || allowAns === '-') {
    cfg.allowedUserIds = [];
  } else if (allowAns) {
    cfg.allowedUserIds = allowAns
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean);
  }

  const histAns = (
    await ask(`3. Latest X Messages count (fixed in bot; defined here in setup) [${cfg.defaultHistoryCount || 6}]: `)
  ).trim();
  if (histAns && Number(histAns) > 0) {
    cfg.defaultHistoryCount = Math.min(50, Math.max(1, Number(histAns)));
  }

  await activeStore.saveConfig();

  // ── Steps 4–6: Jenkins Auth + Console Connection Test ──────────────────────
  const effectiveTestJenkins =
    testJenkins !== undefined ? Boolean(testJenkins) : Boolean(verifyTelegram);

  await runConfigureJenkinsWizard({
    dataDir,
    store: activeStore,
    ask,
    log,
    warn,
    testJenkins: effectiveTestJenkins,
    jenkinsFactory,
    stepOffset: 4,
    showBanner: false
  });

  // ── Step 7+: Register Available IDEs, Gemini Models & Repo Jobs ────────────
  await runWorkspacesWizard({
    dataDir,
    store: activeStore,
    ask,
    log,
    warn,
    queryCliModels: Boolean(verifyTelegram),
    mode: 'setup'
  });

  await activeStore.saveConfig();
  log('');
  log(`Saved configuration to ${activeStore.configFile} (permissions 0600).`);

  if (verifyTelegram && cfg.telegramBotToken) {
    try {
      const tg = new TelegramApi({
        token: cfg.telegramBotToken,
        baseUrl: cfg.telegramApiBaseUrl
      });
      const me = await tg.getMe();
      log(`Verified Telegram Bot: @${me.username} (https://t.me/${me.username})`);
    } catch (err) {
      warn(`Warning: Could not verify Telegram token right now (${err.message}).`);
    }
  }

  log('');
  log('Start the bot anytime with:');
  log('  npm start');
  log('Additional console-only management commands:');
  log('  npm run add-ide        — Register/add or edit an IDE workspace');
  log('  npm run update-jenkins — Update Jenkins URL/auth & test connection');
  log('  npm run test-jenkins   — Test Jenkins connection');
  log('');

  return activeStore;
}

async function main() {
  const subcommand = String(process.argv[2] || 'setup').trim().toLowerCase();

  if (subcommand === 'test-jenkins') {
    const res = await runTestJenkinsConsole();
    if (!res.ok) {
      process.exitCode = 1;
    }
    return;
  }

  const rl = readline.createInterface({ input, output });
  try {
    const ask = (q) => rl.question(q);
    if (subcommand === 'add-ide' || subcommand === 'register-ide' || subcommand === 'workspaces') {
      await runAddIdeWizard({ ask });
      return;
    }
    if (subcommand === 'update-jenkins' || subcommand === 'set-jenkins' || subcommand === 'jenkins') {
      await runConfigureJenkinsWizard({
        ask,
        testJenkins: true,
        showBanner: true
      });
      return;
    }
    await runSetupWizard({ ask });
  } finally {
    rl.close();
  }
}

const isDirectRun =
  process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;

if (isDirectRun) {
  main().catch((err) => {
    console.error(`Setup error: ${err.message || err}`);
    process.exit(1);
  });
}
