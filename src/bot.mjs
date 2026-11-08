import { execFile } from 'node:child_process';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import readline from 'node:readline';
import readlinePromises from 'node:readline/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { promisify } from 'node:util';
import { loadProjectDotEnv } from './env-loader.mjs';
import { ConfigStore } from './config.mjs';
import { discoverGeminiModelFamilies } from './agy-runner.mjs';
import { SERVICE_LABEL } from './service.mjs';
import { TelegramApi } from './telegram-api.mjs';
import { BotController } from './bot-controller.mjs';
import {
  runAddIdeWizard,
  runConfigureJenkinsWizard,
  runSetupWizard,
  runTestJenkinsConsole
} from './setup.mjs';

const execFileAsync = promisify(execFile);

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
export const PROJECT_ROOT = path.resolve(__dirname, '..');

export const BOT_COMMANDS = [
  { command: 'start', description: 'Authenticate session & select IDE' },
  { command: 'ides', description: 'Switch active IDE workspace' },
  { command: 'model', description: 'Change Gemini model & level for active IDE' },
  { command: 'history', description: 'Show latest X messages (setup count)' },
  { command: 'newchat', description: 'Start a fresh chat in active IDE' },
  { command: 'settings', description: 'Change AI model & level per IDE' },
  { command: 'lock', description: 'Lock session immediately' }
];

function sleepWithAbort(ms, signal) {
  return new Promise((resolve) => {
    if (signal?.aborted) {
      resolve();
      return;
    }
    const timer = setTimeout(() => {
      if (signal) signal.removeEventListener('abort', onAbort);
      resolve();
    }, ms);
    function onAbort() {
      clearTimeout(timer);
      resolve();
    }
    if (signal) signal.addEventListener('abort', onAbort, { once: true });
  });
}

export class MissingBotTokenError extends Error {
  constructor() {
    super('TELEGRAM_BOT_TOKEN is not configured');
    this.name = 'MissingBotTokenError';
  }
}

export class MissingSessionPasswordError extends Error {
  constructor() {
    super('Session password is required to start the bot');
    this.name = 'MissingSessionPasswordError';
  }
}

/**
 * Prompts the operator in the terminal to enter a fresh session password on every `npm start` run.
 * Masks keystrokes with `*` on interactive TTYs and supports piped streams for automated testing.
 */
export async function promptStartupPassword({
  inputStream = process.stdin,
  outputStream = process.stdout,
  promptText = '  🔐 Enter session password for this bot run: '
} = {}) {
  if (inputStream.isTTY && typeof inputStream.setRawMode === 'function') {
    while (true) {
      outputStream.write(promptText);
      const entered = await new Promise((resolve, reject) => {
        const chars = [];
        const wasRaw = Boolean(inputStream.isRaw);
        inputStream.setRawMode(true);
        inputStream.resume();

        function cleanup() {
          inputStream.removeListener('data', onData);
          inputStream.removeListener('error', onErr);
          try {
            inputStream.setRawMode(wasRaw);
          } catch {
            // ignore
          }
          inputStream.pause();
        }

        function onErr(err) {
          cleanup();
          reject(err);
        }

        function onData(chunk) {
          const str = typeof chunk === 'string' ? chunk : chunk.toString('utf8');
          for (let i = 0; i < str.length; i++) {
            const ch = str[i];
            const code = ch.charCodeAt(0);

            if (ch === '\x03') {
              outputStream.write('\n');
              cleanup();
              const cancelErr = new Error('Startup password entry canceled');
              cancelErr.cancelled = true;
              reject(cancelErr);
              return;
            }

            if (ch === '\r' || ch === '\n') {
              outputStream.write('\n');
              cleanup();
              resolve(chars.join(''));
              return;
            }

            if (ch === '\x7f' || ch === '\b') {
              if (chars.length > 0) {
                chars.pop();
                outputStream.write('\b \b');
              }
              continue;
            }

            if (ch === '\x15') {
              while (chars.length > 0) {
                chars.pop();
                outputStream.write('\b \b');
              }
              continue;
            }

            if (code >= 32) {
              chars.push(ch);
              outputStream.write('*');
            }
          }
        }

        inputStream.on('data', onData);
        inputStream.on('error', onErr);
      });

      const trimmed = entered.trim();
      if (trimmed.length > 0) {
        return trimmed;
      }
      outputStream.write('  ⚠️  Password cannot be empty. Please enter a password.\n');
    }
  }

  const rl = readline.createInterface({
    input: inputStream,
    crlfDelay: Infinity
  });

  try {
    outputStream.write(promptText);
    for await (const line of rl) {
      const trimmed = String(line || '').trim();
      if (trimmed.length > 0) {
        outputStream.write('\n');
        return trimmed;
      }
      outputStream.write(`  ⚠️  Password cannot be empty.\n${promptText}`);
    }
  } finally {
    rl.close();
  }

  throw new MissingSessionPasswordError();
}

/**
 * Executes a local terminal console command (`add-ide`, `update-jenkins`, `test-jenkins`, `setup`, `ides`, `help`)
 * while `npm start` is running, immediately updating `configStore` in-memory without exposing settings in Telegram.
 */
export async function executeConsoleCommand(
  rawCmd,
  {
    configStore,
    dataDir = path.join(PROJECT_ROOT, 'data'),
    ask,
    log = console.log,
    warn = console.warn,
    jenkinsFactory = undefined
  } = {}
) {
  const cmd = String(rawCmd || '')
    .trim()
    .toLowerCase()
    .replace(/^--/, '')
    .replace(/\s+/g, '-');

  if (!cmd) {
    return { handled: false };
  }

  if (cmd === 'add-ide' || cmd === 'register-ide' || cmd === 'workspaces') {
    await runAddIdeWizard({
      dataDir,
      store: configStore,
      ask,
      log,
      warn
    });
    return { handled: true, command: 'add-ide' };
  }

  if (cmd === 'update-jenkins' || cmd === 'set-jenkins' || cmd === 'jenkins') {
    await runConfigureJenkinsWizard({
      dataDir,
      store: configStore,
      ask,
      log,
      warn,
      testJenkins: true,
      ...(jenkinsFactory ? { jenkinsFactory } : {}),
      showBanner: true
    });
    return { handled: true, command: 'update-jenkins' };
  }

  if (cmd === 'test-jenkins') {
    await runTestJenkinsConsole({
      dataDir,
      store: configStore,
      ...(jenkinsFactory ? { jenkinsFactory } : {}),
      log,
      warn
    });
    return { handled: true, command: 'test-jenkins' };
  }

  if (cmd === 'setup') {
    await runSetupWizard({
      dataDir,
      store: configStore,
      ask,
      log,
      warn,
      ...(jenkinsFactory ? { jenkinsFactory } : {})
    });
    return { handled: true, command: 'setup' };
  }

  if (cmd === 'ides' || cmd === 'status') {
    const cfg = configStore.config;
    const ideLines =
      (cfg.workspaces || [])
        .map(
          (w, idx) =>
            `    ${idx + 1}) ${w.name} — ${w.path} [${w.model || 'gemini-3.8-flash-high'}:${w.modelLevel || 'high'}]`
        )
        .join('\n') || '    (none configured)';
    const jenkinsOk = Boolean(cfg.jenkins?.username && cfg.jenkins?.apiToken);
    log('');
    log(`  Registered IDEs (${(cfg.workspaces || []).length}):`);
    log(ideLines);
    log(
      `  Jenkins: ${cfg.jenkins?.baseUrl || '(not configured)'}${cfg.jenkins?.baseUrl ? ` (${jenkinsOk ? `configured as ${cfg.jenkins.username}` : 'credentials not set'})` : ''}`
    );
    log('');
    return { handled: true, command: 'status' };
  }

  if (cmd === 'help' || cmd === '?') {
    log('');
    log('  Available Console Commands:');
    log('    add-ide         Scan & register an available IDE workspace (or edit existing)');
    log('    update-jenkins  Update Jenkins URL, username & API token, and test connection');
    log('    test-jenkins    Test Jenkins connection right now');
    log('    setup           Run full setup wizard');
    log('    status          Show configured IDEs, Gemini models & Jenkins status');
    log('');
    return { handled: true, command: 'help' };
  }

  warn(
    `  Unknown console command "${rawCmd}". Type "add-ide", "update-jenkins", "test-jenkins", "setup", "status", or "help".`
  );
  return { handled: false };
}

/**
 * Initializes ConfigStore, binds the in-memory session password for this run, verifies the
 * Telegram bot token, registers slash commands, and starts the long-polling `getUpdates` loop.
 */
export async function startBotRunner({
  dataDir = path.join(PROJECT_ROOT, 'data'),
  sessionPassword = '',
  seedWorkspaces = undefined,
  agentRunner = undefined,
  jenkinsFactory = undefined,
  gitPush = true,
  nowProvider = undefined,
  pollTimeoutSec = 25,
  logger = console
} = {}) {
  loadProjectDotEnv(PROJECT_ROOT);

  const configStore = new ConfigStore(dataDir);
  await configStore.init(seedWorkspaces ? { seedWorkspaces } : undefined);

  const token = String(configStore.config.telegramBotToken || '').trim();
  if (!token) {
    throw new MissingBotTokenError();
  }

  const cleanSessionPassword = String(sessionPassword || '').trim();
  if (!cleanSessionPassword) {
    throw new MissingSessionPasswordError();
  }
  configStore.setRuntimePassword(cleanSessionPassword);

  // Best-effort refresh of available Gemini model families from `agy models`
  discoverGeminiModelFamilies(configStore.config.agyBin, { queryCli: true }).catch(() => {});

  const telegram = new TelegramApi({
    token,
    baseUrl: configStore.config.telegramApiBaseUrl
  });

  const controller = new BotController({
    configStore,
    telegram,
    ...(agentRunner ? { agentRunner } : {}),
    ...(jenkinsFactory ? { jenkinsFactory } : {}),
    gitPush,
    ...(nowProvider ? { nowProvider } : {})
  });

  const botInfo = await telegram.getMe();
  await telegram.setMyCommands(BOT_COMMANDS).catch(() => {});

  const abortController = new AbortController();
  let stopped = false;

  const loopPromise = (async () => {
    let backoffMs = 2000;

    while (!abortController.signal.aborted) {
      try {
        const updates = await telegram.getUpdates({
          offset: configStore.state.telegramOffset || 0,
          timeout: pollTimeoutSec,
          signal: abortController.signal
        });

        backoffMs = 2000;

        if (Array.isArray(updates) && updates.length > 0) {
          for (const upd of updates) {
            if (abortController.signal.aborted) break;
            try {
              await controller.handleUpdate(upd);
            } catch (updErr) {
              logger.error?.(
                `[bot] Error handling update ${upd?.update_id}: ${updErr.message || updErr}`
              );
            }
            if (typeof upd?.update_id === 'number') {
              configStore.state.telegramOffset = upd.update_id + 1;
              await configStore.saveState();
            }
          }
        }
      } catch (err) {
        if (abortController.signal.aborted || err?.name === 'AbortError') {
          break;
        }
        if (err?.errorCode === 409) {
          logger.warn?.(
            '[bot] Telegram 409 Conflict: another bot instance is polling with the same token. Retrying in 5s...'
          );
          await sleepWithAbort(5000, abortController.signal);
          continue;
        }
        logger.warn?.(
          `[bot] Polling error (${err.message || err}). Retrying in ${Math.round(backoffMs / 1000)}s...`
        );
        await sleepWithAbort(backoffMs, abortController.signal);
        backoffMs = Math.min(15_000, Math.round(backoffMs * 1.5));
      }
    }
  })();

  async function stop() {
    if (stopped) return;
    stopped = true;
    abortController.abort();
    await loopPromise;
  }

  return {
    botInfo,
    configStore,
    telegram,
    controller,
    loopPromise,
    stop
  };
}

function isProcessAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

export async function acquireSingleInstanceLock(
  dataDir = path.join(PROJECT_ROOT, 'data'),
  { replaceExisting = true } = {}
) {
  await fsp.mkdir(dataDir, { recursive: true, mode: 0o700 });
  const pidFile = path.join(dataDir, 'bot.pid');

  let existing = null;
  try {
    existing = JSON.parse(await fsp.readFile(pidFile, 'utf8'));
  } catch {
    existing = null;
  }

  if (existing?.pid && existing.pid !== process.pid && isProcessAlive(existing.pid)) {
    if (!replaceExisting) {
      return {
        acquired: false,
        existingPid: existing.pid,
        existingMode: existing.mode || 'foreground'
      };
    }
    try {
      process.kill(existing.pid, 'SIGTERM');
      await new Promise((r) => setTimeout(r, 800));
    } catch {
      // ignore
    }
  }

  const record = {
    pid: process.pid,
    mode: process.stdout.isTTY ? 'foreground' : 'background',
    startedAt: new Date().toISOString()
  };
  await fsp.writeFile(pidFile, JSON.stringify(record, null, 2), { mode: 0o600 });

  return {
    acquired: true,
    release: () => {
      try {
        const cur = JSON.parse(fs.readFileSync(pidFile, 'utf8'));
        if (cur?.pid === process.pid) {
          fs.unlinkSync(pidFile);
        }
      } catch {
        // ignore
      }
    }
  };
}

async function main() {
  let releaseLock = null;
  let consoleRl = null;
  const consoleAbort = new AbortController();

  try {
    const dataDir = path.join(PROJECT_ROOT, 'data');
    loadProjectDotEnv(PROJECT_ROOT);

    const startupArgs = process.argv.slice(2);
    if (startupArgs.length > 0 && process.stdin.isTTY) {
      const preStore = new ConfigStore(dataDir);
      await preStore.init();
      const preRl = readlinePromises.createInterface({
        input: process.stdin,
        output: process.stdout
      });
      try {
        for (const arg of startupArgs) {
          await executeConsoleCommand(arg, {
            configStore: preStore,
            dataDir,
            ask: (q) => preRl.question(q)
          });
        }
      } finally {
        preRl.close();
      }
    }

    // Check token before prompting so first-time setup errors show immediately
    const preflightStore = new ConfigStore(dataDir);
    await preflightStore.init();
    if (!String(preflightStore.config.telegramBotToken || '').trim()) {
      throw new MissingBotTokenError();
    }

    // Ensure any old background launchd job is stopped so `npm start` owns polling cleanly
    if (process.platform === 'darwin' && typeof process.getuid === 'function') {
      await execFileAsync('launchctl', [
        'bootout',
        `gui/${process.getuid()}/${SERVICE_LABEL}`
      ]).catch(() => {});
    }

    const lock = await acquireSingleInstanceLock(dataDir, { replaceExisting: true });
    releaseLock = lock.release;

    console.log('');
    console.log('============================================================');
    console.log('  Antigravity IDE — Bot Session Password');
    console.log('============================================================');
    console.log('  Set a new password for this run (valid until app restart).');
    const sessionPassword = await promptStartupPassword();

    const runner = await startBotRunner({ dataDir, sessionPassword });
    const { botInfo, configStore } = runner;
    const cfg = configStore.config;
    const ideNames =
      (cfg.workspaces || [])
        .map(
          (w) =>
            `${w.name}${w.model ? ` [${w.model}${w.modelLevel ? `:${w.modelLevel}` : ''}]` : ''}`
        )
        .join(', ') || '(none yet)';
    const jenkinsOk = Boolean(cfg.jenkins?.username && cfg.jenkins?.apiToken);
    const allowlistDesc =
      cfg.allowedUserIds && cfg.allowedUserIds.length > 0
        ? cfg.allowedUserIds.join(', ')
        : 'Any user who enters this run password';

    console.log('');
    console.log('============================================================');
    console.log('  Antigravity IDE — Telegram Bot Controller');
    console.log('============================================================');
    console.log(`  Telegram Bot    : @${botInfo.username} (https://t.me/${botInfo.username})`);
    console.log('  Session Auth    : ******** (active until app restart)');
    console.log(`  Allowed Users   : ${allowlistDesc}`);
    console.log(`  Latest X Msgs   : ${cfg.defaultHistoryCount || 6} (configured via npm run setup)`);
    console.log(`  Registered IDEs : ${(cfg.workspaces || []).length} (${ideNames})`);
    console.log(
      `  Jenkins         : ${cfg.jenkins?.baseUrl || '(not configured)'}${cfg.jenkins?.baseUrl ? ` (${jenkinsOk ? `configured as ${cfg.jenkins.username}` : 'credentials not set yet'})` : ''}`
    );
    console.log('------------------------------------------------------------');
    console.log('  Console Commands (type here anytime while running):');
    console.log('    add-ide         Register/add an available IDE workspace');
    console.log('    update-jenkins  Update Jenkins URL/auth & test connection');
    console.log('    test-jenkins    Test Jenkins connection');
    console.log('    setup           Run full setup wizard');
    console.log('------------------------------------------------------------');
    console.log('  Long-polling active. Open your bot in Telegram and send /start');
    console.log('  Press Ctrl+C to stop (next npm start will ask for a new password).');
    console.log('============================================================');
    console.log('');

    let shuttingDown = false;
    const shutdown = async (sig) => {
      if (shuttingDown) return;
      shuttingDown = true;
      console.log(`\n[bot] Received ${sig}, shutting down cleanly...`);
      consoleAbort.abort();
      try {
        consoleRl?.close();
      } catch {
        // ignore
      }
      await runner.stop();
      releaseLock?.();
      process.exit(0);
    };

    process.once('SIGINT', () => shutdown('SIGINT'));
    process.once('SIGTERM', () => shutdown('SIGTERM'));
    process.once('exit', () => releaseLock?.());

    if (process.stdin.isTTY) {
      consoleRl = readlinePromises.createInterface({
        input: process.stdin,
        output: process.stdout
      });
      consoleRl.on('SIGINT', () => shutdown('SIGINT'));

      (async () => {
        while (!consoleAbort.signal.aborted) {
          try {
            const line = await consoleRl.question('', { signal: consoleAbort.signal });
            if (consoleAbort.signal.aborted) break;
            if (line.trim()) {
              await executeConsoleCommand(line, {
                configStore,
                dataDir,
                ask: (q) => consoleRl.question(q, { signal: consoleAbort.signal })
              });
            }
          } catch (err) {
            if (consoleAbort.signal.aborted || err?.name === 'AbortError') {
              break;
            }
          }
        }
      })();
    }

    await runner.loopPromise;
  } catch (err) {
    consoleAbort.abort();
    try {
      consoleRl?.close();
    } catch {
      // ignore
    }
    releaseLock?.();
    if (err?.cancelled) {
      process.exit(130);
    }
    if (err instanceof MissingBotTokenError) {
      console.error('');
      console.error('============================================================');
      console.error('  Telegram Bot Token Not Configured Yet');
      console.error('============================================================');
      console.error('  1. Open Telegram and message @BotFather -> send /newbot');
      console.error('  2. Copy the HTTP API token and run:');
      console.error('       npm run setup');
      console.error('     (or copy .env.example to .env and set TELEGRAM_BOT_TOKEN)');
      console.error('  3. Start the bot (prompts for session password on each run):');
      console.error('       npm start');
      console.error('============================================================');
      console.error('');
      process.exit(1);
    }

    console.error(`[bot] Fatal startup error: ${err.message || err}`);
    process.exit(1);
  }
}

const isDirectRun =
  process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;

if (isDirectRun) {
  main();
}
