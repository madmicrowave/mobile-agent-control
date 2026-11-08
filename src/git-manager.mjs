import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import fsp from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';

const execFileAsync = promisify(execFile);

const GIT_ENV = {
  ...process.env,
  GIT_TERMINAL_PROMPT: '0',
  LC_ALL: 'C'
};

export async function runGit(repoPath, args, { timeoutMs = 120_000, envOverrides = {} } = {}) {
  const { stdout, stderr } = await execFileAsync('git', args, {
    cwd: repoPath,
    env: { ...GIT_ENV, ...envOverrides },
    timeout: timeoutMs,
    maxBuffer: 20 * 1024 * 1024,
    encoding: 'buffer'
  });
  return {
    stdoutBuf: stdout,
    stdout: stdout.toString('utf8'),
    stderr: stderr.toString('utf8')
  };
}

/**
 * Parses `git status --porcelain=v1 -z -uall` output buffer into file records.
 */
export function parsePorcelainZ(buf) {
  const records = [];
  if (!buf || buf.length === 0) return records;

  const parts = [];
  let start = 0;
  for (let i = 0; i < buf.length; i++) {
    if (buf[i] === 0) {
      parts.push(buf.subarray(start, i).toString('utf8'));
      start = i + 1;
    }
  }

  for (let i = 0; i < parts.length; i++) {
    const entry = parts[i];
    if (entry.length < 4) continue;
    const xy = entry.slice(0, 2);
    const filePath = entry.slice(3);
    let origPath = null;
    if (xy[0] === 'R' || xy[0] === 'C' || xy[1] === 'R' || xy[1] === 'C') {
      origPath = parts[++i] || null;
    }
    records.push({ xy, path: filePath, origPath });
  }
  return records;
}

async function hashWorkingFile(repoPath, relPath) {
  const fullPath = path.join(repoPath, relPath);
  try {
    const stat = await fsp.lstat(fullPath);
    if (stat.isSymbolicLink()) {
      const linkTarget = await fsp.readlink(fullPath);
      return `SYMLINK:${linkTarget}`;
    }
    if (!stat.isFile()) {
      return `TYPE:${stat.mode}`;
    }
    const content = await fsp.readFile(fullPath);
    return crypto.createHash('sha256').update(content).digest('hex');
  } catch {
    return 'MISSING';
  }
}

export async function getRepoSnapshot(repo) {
  let branch = repo.branch || '';
  if (!branch) {
    try {
      const { stdout } = await runGit(repo.path, ['branch', '--show-current']);
      branch = stdout.trim();
    } catch {
      branch = '';
    }
  }
  if (!branch) {
    branch = 'master';
  }

  let headSha = null;
  try {
    const { stdout } = await runGit(repo.path, ['rev-parse', 'HEAD']);
    headSha = stdout.trim();
  } catch {
    headSha = null;
  }

  const { stdoutBuf } = await runGit(repo.path, ['status', '--porcelain=v1', '-z', '-uall']);
  const statusRecords = parsePorcelainZ(stdoutBuf);
  const files = {};

  for (const rec of statusRecords) {
    const digest = await hashWorkingFile(repo.path, rec.path);
    files[rec.path] = {
      xy: rec.xy,
      origPath: rec.origPath,
      digest
    };
  }

  return {
    repoName: repo.name,
    repoPath: repo.path,
    branch,
    headSha,
    files
  };
}

export async function snapshotWorkspaceRepos(repos) {
  const snapshots = {};
  for (const repo of repos) {
    try {
      snapshots[repo.name] = await getRepoSnapshot(repo);
    } catch {
      // Ignore inaccessible repo
    }
  }
  return snapshots;
}

function normalizeShortStatus(xy) {
  const code = String(xy || '').trim();
  if (code === '??' || code.includes('A')) return 'A';
  if (code.includes('D')) return 'D';
  if (code.includes('R')) return 'R';
  return 'M';
}

/**
 * Compares a repo's current working tree against its pre-agent snapshot and returns
 * the exact relative file paths touched during the agent turn.
 */
export async function detectRepoChangesSinceSnapshot(repo, prevSnapshot) {
  const current = await getRepoSnapshot(repo);
  const baselineFiles = prevSnapshot?.files || {};
  const touchedSet = new Set();
  const statusByPath = new Map();

  for (const [relPath, info] of Object.entries(current.files)) {
    const prev = baselineFiles[relPath];
    if (!prev || prev.xy !== info.xy || prev.digest !== info.digest) {
      touchedSet.add(relPath);
      statusByPath.set(relPath, normalizeShortStatus(info.xy));
      if (info.origPath) {
        touchedSet.add(info.origPath);
        if (!statusByPath.has(info.origPath)) {
          statusByPath.set(info.origPath, 'D');
        }
      }
    }
  }

  const changedFiles = [...touchedSet].sort();
  const fileStatuses = changedFiles.map((filePath) => ({
    status: statusByPath.get(filePath) || 'M',
    path: filePath
  }));

  return {
    repoName: repo.name,
    repoPath: repo.path,
    branch: repo.branch || current.branch || 'master',
    preHeadSha: prevSnapshot?.headSha || current.headSha,
    currentHeadSha: current.headSha,
    headAdvanced: Boolean(
      prevSnapshot?.headSha && current.headSha && prevSnapshot.headSha !== current.headSha
    ),
    changedFiles,
    fileStatuses
  };
}

/**
 * Validates whether `branchName` is a legal Git branch name.
 */
export async function validateGitBranchName(branchName) {
  const trimmed = String(branchName || '').trim();
  if (!trimmed || trimmed.startsWith('-')) return false;
  try {
    await execFileAsync('git', ['check-ref-format', '--branch', trimmed], {
      env: GIT_ENV,
      timeout: 5_000
    });
    return true;
  } catch {
    return false;
  }
}

export function buildAutoCommitMessage(promptText) {
  const oneLine = String(promptText || '')
    .replace(/\s+/g, ' ')
    .trim();
  const summary = oneLine.length > 68 ? `${oneLine.slice(0, 65)}...` : (oneLine || 'workspace update');
  return `feat(mobile-agent): ${summary}`;
}

async function ensureGitAuthorArgs(repoPath) {
  try {
    const { stdout: nameOut } = await runGit(repoPath, ['config', 'user.name']);
    const { stdout: emailOut } = await runGit(repoPath, ['config', 'user.email']);
    if (nameOut.trim() && emailOut.trim()) {
      return [];
    }
  } catch {
    // Fallback author when repo has no git user configured (e.g. test containers)
  }
  return ['-c', 'user.name=Antigravity Mobile', '-c', 'user.email=mobile@antigravity.local'];
}

/**
 * Pushes an existing local commit to `origin <branch>`, rebasing once automatically
 * if `origin/<branch>` advanced ahead cleanly (non-fast-forward).
 */
export async function pushRepoCommit(commitRecord) {
  const destRef = commitRecord.branch.startsWith('refs/')
    ? commitRecord.branch
    : `refs/heads/${commitRecord.branch}`;

  try {
    await runGit(
      commitRecord.repoPath,
      ['push', '-u', 'origin', `${commitRecord.commitSha}:${destRef}`],
      { timeoutMs: 180_000 }
    );
  } catch (firstPushErr) {
    const msg = `${firstPushErr.stderr || ''} ${firstPushErr.message || ''}`;
    if (/non-fast-forward|fetch first|rejected/i.test(msg)) {
      await runGit(
        commitRecord.repoPath,
        ['pull', '--rebase', '--autostash', 'origin', commitRecord.branch],
        { timeoutMs: 120_000 }
      );
      const { stdout: newShaOut } = await runGit(commitRecord.repoPath, ['rev-parse', 'HEAD']);
      commitRecord.commitSha = newShaOut.trim();
      commitRecord.shortSha = commitRecord.commitSha.slice(0, 7);
      await runGit(
        commitRecord.repoPath,
        ['push', '-u', 'origin', `HEAD:${destRef}`],
        { timeoutMs: 180_000 }
      );
    } else {
      throw firstPushErr;
    }
  }

  commitRecord.pushed = true;
  return commitRecord;
}

/**
 * Stages only the files modified during this turn, commits them, and pushes to `origin <branch>`.
 * If `git commit` succeeds locally before `git push` fails, attaches `err.commitRecord` so the
 * orchestrator can still allow retrying the push or reverting the local commit cleanly.
 */
export async function commitAndPushRepoChanges(
  repo,
  delta,
  commitMessage,
  { push = true, customBranch = '' } = {}
) {
  if (!delta.changedFiles || delta.changedFiles.length === 0) {
    return null;
  }

  const targetBranch = String(customBranch || '').trim() || delta.branch || 'master';
  if (customBranch && String(customBranch).trim()) {
    await runGit(repo.path, ['checkout', '-B', targetBranch]);
  }

  // Stage modified/added/deleted paths from this turn in chunks to avoid argv limits
  const chunkSize = 100;
  for (let i = 0; i < delta.changedFiles.length; i += chunkSize) {
    const slice = delta.changedFiles.slice(i, i + chunkSize);
    await runGit(repo.path, ['add', '-A', '--', ...slice]);
  }

  const { stdout: stagedOut } = await runGit(repo.path, ['diff', '--cached', '--name-only']);
  const stagedFiles = stagedOut
    .split('\n')
    .map((s) => s.trim())
    .filter(Boolean);

  if (stagedFiles.length === 0) {
    return null;
  }

  const authorArgs = await ensureGitAuthorArgs(repo.path);
  await runGit(repo.path, [...authorArgs, 'commit', '-m', commitMessage]);

  const { stdout: shaOut } = await runGit(repo.path, ['rev-parse', 'HEAD']);
  const commitSha = shaOut.trim();
  const shortSha = commitSha.slice(0, 7);

  const { stdout: statOut } = await runGit(repo.path, ['show', '--stat', '--format=', commitSha]);

  const commitRecord = {
    repoName: repo.name,
    repoPath: repo.path,
    branch: targetBranch,
    previousBranch: delta.branch || 'master',
    preHeadSha: delta.preHeadSha,
    commitSha,
    shortSha,
    commitMessage,
    changedFiles: stagedFiles,
    statSummary: statOut.trim(),
    pushed: false,
    jenkinsJob: repo.jenkinsJob || '',
    deployEnabled: Boolean(repo.deployEnabled && repo.jenkinsJob)
  };

  if (push) {
    try {
      await pushRepoCommit(commitRecord);
    } catch (pushErr) {
      pushErr.commitRecord = commitRecord;
      throw pushErr;
    }
  }

  return commitRecord;
}

/**
 * Fallback collector if the agent itself created local git commit(s) during the turn.
 */
export async function collectAgentCommitsAndPush(repo, delta, { push = true } = {}) {
  if (!delta.headAdvanced || !delta.preHeadSha || !delta.currentHeadSha) {
    return [];
  }
  const { stdout } = await runGit(repo.path, [
    'rev-list',
    '--reverse',
    `${delta.preHeadSha}..${delta.currentHeadSha}`
  ]);
  const shas = stdout
    .split('\n')
    .map((s) => s.trim())
    .filter(Boolean);

  const records = [];
  for (const sha of shas) {
    const { stdout: filesOut } = await runGit(repo.path, [
      'diff-tree',
      '--no-commit-id',
      '--name-only',
      '-r',
      sha
    ]);
    const { stdout: statOut } = await runGit(repo.path, ['show', '--stat', '--format=', sha]);
    records.push({
      repoName: repo.name,
      repoPath: repo.path,
      branch: delta.branch,
      preHeadSha: delta.preHeadSha,
      commitSha: sha,
      shortSha: sha.slice(0, 7),
      changedFiles: filesOut.split('\n').map((s) => s.trim()).filter(Boolean),
      statSummary: statOut.trim(),
      pushed: false,
      jenkinsJob: repo.jenkinsJob || '',
      deployEnabled: Boolean(repo.deployEnabled && repo.jenkinsJob)
    });
  }

  if (push && records.length > 0) {
    const lastRecord = records[records.length - 1];
    try {
      await pushRepoCommit(lastRecord);
      for (const r of records) r.pushed = true;
    } catch (pushErr) {
      pushErr.commitRecords = records;
      throw pushErr;
    }
  }

  return records;
}

/**
 * Discards uncommitted working-tree edits created since `prevSnapshot` (used when aborting an in-flight agent run).
 */
export async function discardUncommittedTurnChanges(repo, prevSnapshot) {
  const delta = await detectRepoChangesSinceSnapshot(repo, prevSnapshot);
  if (delta.changedFiles.length === 0) return;

  const baselineFiles = prevSnapshot?.files || {};
  const trackedToCheckout = [];
  const newlyUntrackedToDelete = [];

  for (const relPath of delta.changedFiles) {
    if (baselineFiles[relPath]) {
      // Pre-existing dirty file: leave alone to avoid losing user's manual work
      continue;
    }
    try {
      await runGit(repo.path, ['ls-files', '--error-unmatch', '--', relPath]);
      trackedToCheckout.push(relPath);
    } catch {
      newlyUntrackedToDelete.push(relPath);
    }
  }

  if (trackedToCheckout.length > 0) {
    await runGit(repo.path, ['checkout', 'HEAD', '--', ...trackedToCheckout]).catch(() => {});
  }
  for (const relPath of newlyUntrackedToDelete) {
    const target = path.join(repo.path, relPath);
    await fsp.rm(target, { recursive: true, force: true }).catch(() => {});
  }
}

/**
 * Reverts each commit created in a turn (`git revert --no-edit <sha>`) and pushes to `origin <branch>`.
 */
export async function revertAndPushTurnCommits(commits, { push = true, onLog = () => {} } = {}) {
  const reverted = [];

  // Revert in LIFO (reverse) order so multiple commits in the same repo unwind cleanly
  for (const commit of [...commits].reverse()) {
    onLog(`Reverting bad commit ${commit.repoName}@${commit.shortSha}...`);
    const authorArgs = await ensureGitAuthorArgs(commit.repoPath);

    const { stdout: origSubjOut } = await runGit(commit.repoPath, [
      'log',
      '-1',
      '--pretty=%s',
      commit.commitSha
    ]);
    const origSubject = origSubjOut.trim();

    await runGit(commit.repoPath, [...authorArgs, 'revert', '--no-edit', commit.commitSha]);
    await runGit(commit.repoPath, [
      ...authorArgs,
      'commit',
      '--amend',
      '-m',
      `Revert "${origSubject}" (bad commit)`,
      '-m',
      `This reverts bad commit ${commit.commitSha}.`
    ]);

    const { stdout: shaOut } = await runGit(commit.repoPath, ['rev-parse', 'HEAD']);
    const revertCommitSha = shaOut.trim();
    const revertShortSha = revertCommitSha.slice(0, 7);

    const revertRecord = {
      repoName: commit.repoName,
      repoPath: commit.repoPath,
      branch: commit.branch,
      originalCommitSha: commit.commitSha,
      commitSha: revertCommitSha,
      shortSha: revertShortSha,
      revertCommitSha,
      revertShortSha,
      pushed: false,
      jenkinsJob: commit.jenkinsJob || '',
      deployEnabled: Boolean(commit.deployEnabled && commit.jenkinsJob)
    };

    if (push && commit.pushed) {
      onLog(`Pushing revert ${revertShortSha} for ${commit.repoName} to origin/${commit.branch}...`);
      await pushRepoCommit(revertRecord);
    }

    reverted.push(revertRecord);
  }

  return reverted;
}

