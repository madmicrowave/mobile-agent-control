import { execFile } from 'node:child_process';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
export const PROJECT_ROOT = path.resolve(__dirname, '..');

export const SERVICE_LABEL = 'com.domonk.mobile-agent-control';

function escapeXml(str) {
  return String(str || '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

export function buildLaunchdPlistXml({
  label = SERVICE_LABEL,
  nodeBin = process.execPath,
  projectRoot = PROJECT_ROOT,
  homeDir = os.homedir()
} = {}) {
  const botScript = path.join(projectRoot, 'src', 'bot.mjs');
  const outLog = path.join(projectRoot, 'data', 'bot.out.log');
  const errLog = path.join(projectRoot, 'data', 'bot.err.log');
  const envPath = [
    path.join(homeDir, '.local', 'bin'),
    path.join(homeDir, '.gemini', 'bin'),
    path.dirname(nodeBin),
    '/opt/homebrew/bin',
    '/usr/local/bin',
    '/usr/bin',
    '/bin',
    '/usr/sbin',
    '/sbin'
  ]
    .filter(Boolean)
    .filter((v, idx, arr) => arr.indexOf(v) === idx)
    .join(':');

  const programArgs =
    process.platform === 'darwin' && fs.existsSync('/usr/bin/caffeinate')
      ? ['/usr/bin/caffeinate', '-ims', nodeBin, botScript]
      : [nodeBin, botScript];

  const argsXml = programArgs.map((a) => `    <string>${escapeXml(a)}</string>`).join('\n');

  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${escapeXml(label)}</string>
  <key>ProgramArguments</key>
  <array>
${argsXml}
  </array>
  <key>WorkingDirectory</key>
  <string>${escapeXml(projectRoot)}</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HOME</key>
    <string>${escapeXml(homeDir)}</string>
    <key>PATH</key>
    <string>${escapeXml(envPath)}</string>
    <key>CI</key>
    <string>1</string>
    <key>GIT_TERMINAL_PROMPT</key>
    <string>0</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>5</integer>
  <key>StandardOutPath</key>
  <string>${escapeXml(outLog)}</string>
  <key>StandardErrorPath</key>
  <string>${escapeXml(errLog)}</string>
</dict>
</plist>
`;
}

async function stopOrphanBotProcesses(projectRoot = PROJECT_ROOT) {
  const resolvedRoot = path.resolve(projectRoot);
  const botAbsPath = path.join(resolvedRoot, 'src', 'bot.mjs');
  const stoppedPids = [];

  try {
    const { stdout } = await execFileAsync('ps', ['-eo', 'pid=,args='], { timeout: 5_000 });
    const lines = stdout.split('\n');

    for (const rawLine of lines) {
      const m = rawLine.trim().match(/^(\d+)\s+(.+)$/);
      if (!m) continue;
      const pid = Number(m[1]);
      const cmd = m[2].trim();
      if (!pid || pid === process.pid || pid === process.ppid) continue;
      if (!/(?:^|\/)(?:node|caffeinate)\b/.test(cmd)) continue;
      if (!/(?:^|\s|\/)src\/bot\.mjs(?:\s|$)/.test(cmd)) continue;

      let matchesProject = cmd.includes(botAbsPath);
      if (!matchesProject) {
        try {
          const { stdout: lsofOut } = await execFileAsync(
            'lsof',
            ['-a', '-p', String(pid), '-d', 'cwd', '-Fn'],
            { timeout: 3_000 }
          );
          const cwdLine = lsofOut
            .split('\n')
            .find((l) => l.startsWith('n'));
          if (cwdLine && path.resolve(cwdLine.slice(1)) === resolvedRoot) {
            matchesProject = true;
          }
        } catch {
          // ignore
        }
      }

      if (matchesProject) {
        try {
          process.kill(pid, 'SIGTERM');
          stoppedPids.push(pid);
        } catch {
          // already exited
        }
      }
    }
  } catch {
    // ignore ps errors
  }

  if (stoppedPids.length > 0) {
    await new Promise((r) => setTimeout(r, 800));
  }
  return stoppedPids;
}

export async function manageLaunchdService(action = 'reload', { log = console.log } = {}) {
  if (process.platform !== 'darwin') {
    throw new Error('launchd service management is only supported on macOS.');
  }

  const uid = process.getuid();
  const domainTarget = `gui/${uid}`;
  const serviceTarget = `${domainTarget}/${SERVICE_LABEL}`;
  const launchAgentsDir = path.join(os.homedir(), 'Library', 'LaunchAgents');
  const plistPath = path.join(launchAgentsDir, `${SERVICE_LABEL}.plist`);
  const dataDir = path.join(PROJECT_ROOT, 'data');

  await fsp.mkdir(dataDir, { recursive: true, mode: 0o700 });
  await fsp.mkdir(launchAgentsDir, { recursive: true });

  if (action === 'stop' || action === 'uninstall') {
    await execFileAsync('launchctl', ['bootout', serviceTarget]).catch(() => {});
    const orphans = await stopOrphanBotProcesses(PROJECT_ROOT);
    if (action === 'uninstall') {
      await fsp.rm(plistPath, { force: true });
      log(`Uninstalled ${SERVICE_LABEL} and removed ${plistPath}.`);
    } else {
      log(
        `Stopped ${SERVICE_LABEL}${orphans.length > 0 ? ` (and terminated foreground PID(s): ${orphans.join(', ')})` : ''}.`
      );
    }
    return;
  }

  if (action === 'status') {
    try {
      const { stdout } = await execFileAsync('launchctl', ['print', serviceTarget], {
        timeout: 5_000
      });
      const stateMatch = stdout.match(/state\s*=\s*([^\n]+)/);
      const pidMatch = stdout.match(/pid\s*=\s*(\d+)/);
      log(`Service : ${SERVICE_LABEL}`);
      log(`State   : ${stateMatch ? stateMatch[1].trim() : 'loaded'}`);
      log(`PID     : ${pidMatch ? pidMatch[1].trim() : 'n/a'}`);
      log(`Plist   : ${plistPath}`);
      log(`Logs    : ${path.join(dataDir, 'bot.out.log')}`);
    } catch {
      log(`Service ${SERVICE_LABEL} is not currently loaded in ${domainTarget}.`);
    }
    return;
  }

  if (action === 'install' || action === 'reload' || action === 'restart') {
    // Unload existing launchd job (if any) and stop any duplicate foreground bot instances
    await execFileAsync('launchctl', ['bootout', serviceTarget]).catch(() => {});
    const orphans = await stopOrphanBotProcesses(PROJECT_ROOT);
    if (orphans.length > 0) {
      log(`Stopped standalone foreground bot process(es): ${orphans.join(', ')}`);
    }

    // Truncate log files with restricted permissions (0600) so each reload starts clean
    for (const logName of ['bot.out.log', 'bot.err.log']) {
      const p = path.join(dataDir, logName);
      await fsp.writeFile(p, '', { mode: 0o600 });
    }

    const xml = buildLaunchdPlistXml();
    await fsp.writeFile(plistPath, xml, { mode: 0o644 });

    await execFileAsync('launchctl', ['bootstrap', domainTarget, plistPath]);
    await execFileAsync('launchctl', ['enable', serviceTarget]).catch(() => {});
    await execFileAsync('launchctl', ['kickstart', '-k', serviceTarget]);

    await new Promise((r) => setTimeout(r, 1200));
    await manageLaunchdService('status', { log });
    return;
  }

  throw new Error(`Unknown service action "${action}". Expected: install | reload | status | stop | uninstall`);
}

const isDirectRun =
  process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href;

if (isDirectRun) {
  const cmd = (process.argv[2] || 'reload').toLowerCase();
  manageLaunchdService(cmd).catch((err) => {
    console.error(`[service] Error: ${err.message || err}`);
    process.exit(1);
  });
}

