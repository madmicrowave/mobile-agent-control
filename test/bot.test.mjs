import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import fsp from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';

import {
  ConfigStore,
  expandUserPath,
  parseJenkinsfileJobName,
  resolveDefaultAgyBrainDir,
  resolveLegacyDesktopBrainDir
} from '../src/config.mjs';
import { runGit, validateGitBranchName } from '../src/git-manager.mjs';
import {
  JenkinsClient,
  normalizeJenkinsJobPath,
  rewriteToBaseOrigin
} from '../src/jenkins-client.mjs';
import {
  GitHubClient,
  parseGitHubRepoSlug
} from '../src/github-client.mjs';
import { GoogleCloudClient } from '../src/google-cloud-client.mjs';
import {
  VALID_MODEL_LEVELS,
  GEMINI_MODEL_FAMILIES,
  DEFAULT_AGENT_MODEL_FAMILIES,
  buildAgyArgs,
  isMissingTrajectoryError,
  resolveEffectiveModelAndLevel
} from '../src/agy-runner.mjs';
import {
  executeWorkspaceTool,
  runDirectApiTurn,
  runUnifiedAgentTurn
} from '../src/agent-runner.mjs';
import {
  cleanUserPromptText,
  readTranscriptMessages,
  discoverRecentWorkspaceConversations
} from '../src/transcript-reader.mjs';
import {
  TelegramApi,
  escapeHtml,
  markdownToTelegramHtml,
  splitTelegramText
} from '../src/telegram-api.mjs';
import {
  BotController,
  REPLY_BTN_SETTINGS,
  REPLY_BTN_SWITCH_IDE
} from '../src/bot-controller.mjs';
import { PassThrough } from 'node:stream';
import {
  startBotRunner,
  promptStartupPassword,
  executeConsoleCommand,
  MissingBotTokenError,
  MissingSessionPasswordError
} from '../src/bot.mjs';
import {
  runSetupWizard,
  runAddIdeWizard,
  runConfigureJenkinsWizard,
  runConfigureGithubWizard,
  runConfigureGoogleCloudWizard,
  runConfigureAiEnginesWizard,
  runTestJenkinsConsole,
  runTestGithubConsole,
  runTestGoogleCloudConsole
} from '../src/setup.mjs';
import { buildLaunchdPlistXml } from '../src/service.mjs';

/**
 * Local HTTP Mock Telegram Bot API server supporting:
 * - getMe, setMyCommands, getUpdates, sendMessage, editMessageText,
 *   editMessageReplyMarkup, answerCallbackQuery, deleteMessage, getFile, and /file/bot<token>/...
 */
async function startMockTelegramServer() {
  const sentMessages = [];
  const deletedMessages = [];
  const editedMessages = [];
  const callbackAnswers = [];
  const updateQueue = [];
  const pollErrors = [];
  let lastPollConnectionHeader = '';
  let nextMsgId = 100;

  const server = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://127.0.0.1');

    if (req.method === 'GET' && url.pathname.startsWith('/file/bot')) {
      res.writeHead(200, { 'Content-Type': 'image/jpeg' });
      res.end(Buffer.from('FAKE_JPEG_IMAGE_BYTES_12345', 'utf8'));
      return;
    }

    const chunks = [];
    for await (const c of req) chunks.push(c);
    const bodyText = Buffer.concat(chunks).toString('utf8');
    const payload = bodyText ? JSON.parse(bodyText) : {};

    const method = url.pathname.split('/').pop();

    if (method === 'getMe') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(
        JSON.stringify({
          ok: true,
          result: { id: 999001, is_bot: true, first_name: 'AGY Controller', username: 'agy_ctrl_bot' }
        })
      );
      return;
    }

    if (method === 'setMyCommands') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, result: true }));
      return;
    }

    if (method === 'getUpdates') {
      lastPollConnectionHeader = String(req.headers.connection || '');
      if (pollErrors.length > 0) {
        const nextErr = pollErrors.shift();
        res.writeHead(nextErr.status || 429, { 'Content-Type': nextErr.contentType || 'application/json' });
        res.end(nextErr.rawBody ?? JSON.stringify(nextErr.body));
        return;
      }
      const offset = Number(payload.offset || 0);
      const ready = updateQueue.filter((u) => u.update_id >= offset);
      while (updateQueue.length > 0 && updateQueue[0].update_id < offset) {
        updateQueue.shift();
      }
      const batch = ready.splice(0, 10);
      for (const item of batch) {
        const idx = updateQueue.findIndex((u) => u.update_id === item.update_id);
        if (idx !== -1) updateQueue.splice(idx, 1);
      }
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, result: batch }));
      return;
    }

    if (method === 'sendMessage') {
      const msg = {
        message_id: nextMsgId++,
        chat: { id: payload.chat_id },
        text: payload.text,
        parse_mode: payload.parse_mode || null,
        reply_markup: payload.reply_markup || null
      };
      sentMessages.push(msg);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, result: msg }));
      return;
    }

    if (method === 'editMessageText') {
      editedMessages.push(payload);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, result: payload }));
      return;
    }

    if (method === 'editMessageReplyMarkup') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, result: true }));
      return;
    }

    if (method === 'deleteMessage') {
      deletedMessages.push({ chatId: payload.chat_id, messageId: payload.message_id });
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, result: true }));
      return;
    }

    if (method === 'answerCallbackQuery') {
      callbackAnswers.push(payload);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, result: true }));
      return;
    }

    if (method === 'getFile') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(
        JSON.stringify({
          ok: true,
          result: {
            file_id: payload.file_id,
            file_path: `photos/${payload.file_id}.jpg`
          }
        })
      );
      return;
    }

    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: false, description: `Unknown mock Telegram method: ${method}` }));
  });

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();

  return {
    baseUrl: `http://127.0.0.1:${port}`,
    sentMessages,
    deletedMessages,
    editedMessages,
    callbackAnswers,
    updateQueue,
    pollErrors,
    getLastPollConnectionHeader: () => lastPollConnectionHeader,
    clearSent() {
      sentMessages.length = 0;
    },
    lastSent() {
      return sentMessages[sentMessages.length - 1] || null;
    },
    close: () => new Promise((resolve) => server.close(resolve))
  };
}

/**
 * Local HTTP Mock Jenkins server supporting nested folder paths (`/job/A/job/B/job/C`),
 * parameterized triggers (`VERSION=<branch>`), queue polling, and configurable `SUCCESS` / `FAILURE`.
 */
async function startMockJenkinsServer() {
  const state = {
    nextBuildNum: 1,
    triggeredBuilds: [],
    nextOutcome: {
      result: 'SUCCESS',
      consoleText: 'Deploying container...\nHealthcheck OK\nFinished: SUCCESS\n'
    }
  };

  const builds = new Map();

  const server = http.createServer((req, res) => {
    const url = new URL(req.url, `http://${req.headers.host}`);

    if (url.pathname === '/crumbIssuer/api/json') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ crumbRequestField: 'Jenkins-Crumb', crumb: 'crumb-xyz' }));
      return;
    }

    if (url.pathname === '/api/json') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(
        JSON.stringify({
          jobs: [
            {
              name: 'Prod',
              jobs: [
                {
                  name: 'payments',
                  jobs: [
                    { name: 'payments.example.com-GATE' },
                    { name: 'payments.example.com-BACKOFFICE' }
                  ]
                }
              ]
            },
            { name: 'extra_service', url: `${state.baseUrl}/job/extra_service/` }
          ]
        })
      );
      return;
    }

    function decodeJobSegments(jobPathPart) {
      return jobPathPart
        .split('/job/')
        .filter(Boolean)
        .map((s) => decodeURIComponent(s))
        .join('/');
    }

    const triggerMatch = url.pathname.match(/^((?:\/job\/[^/]+)+)\/buildWithParameters$/);
    if (req.method === 'POST' && triggerMatch) {
      const jobName = decodeJobSegments(triggerMatch[1]);
      const jobUrlSegments = triggerMatch[1];
      const version = url.searchParams.get('VERSION') || 'master';
      const buildNumber = state.nextBuildNum++;
      const record = {
        jobName,
        jobUrlSegments,
        version,
        buildNumber,
        result: state.nextOutcome.result,
        consoleText: state.nextOutcome.consoleText,
        polls: 0
      };
      builds.set(`${jobName}:${buildNumber}`, record);
      state.triggeredBuilds.push(record);

      res.writeHead(201, {
        Location: `http://127.0.0.1:8080/queue/item/${buildNumber}/`
      });
      res.end();
      return;
    }

    const queueMatch = url.pathname.match(/^\/queue\/item\/(\d+)\/api\/json$/);
    if (queueMatch) {
      const num = Number(queueMatch[1]);
      const rec = state.triggeredBuilds.find((b) => b.buildNumber === num);
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(
        JSON.stringify({
          cancelled: false,
          executable: {
            number: num,
            url: `http://127.0.0.1:8080${rec.jobUrlSegments}/${num}/`
          }
        })
      );
      return;
    }

    const buildJsonMatch = url.pathname.match(/^((?:\/job\/[^/]+)+)\/(\d+)\/api\/json$/);
    if (buildJsonMatch) {
      const jobName = decodeJobSegments(buildJsonMatch[1]);
      const num = Number(buildJsonMatch[2]);
      const rec = builds.get(`${jobName}:${num}`);
      rec.polls += 1;
      const stillBuilding = rec.polls < 2;
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(
        JSON.stringify({
          building: stillBuilding,
          result: stillBuilding ? null : rec.result,
          duration: 420
        })
      );
      return;
    }

    const consoleMatch = url.pathname.match(/^((?:\/job\/[^/]+)+)\/(\d+)\/consoleText$/);
    if (consoleMatch) {
      const jobName = decodeJobSegments(consoleMatch[1]);
      const num = Number(consoleMatch[2]);
      const rec = builds.get(`${jobName}:${num}`);
      res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end(rec?.consoleText || '');
      return;
    }

    res.writeHead(404);
    res.end('Not found');
  });

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  state.baseUrl = `http://127.0.0.1:${port}`;

  return {
    baseUrl: state.baseUrl,
    triggeredBuilds: state.triggeredBuilds,
    setNextOutcome(result, consoleText) {
      state.nextOutcome = { result, consoleText };
    },
    close: () => new Promise((resolve) => server.close(resolve))
  };
}

/**
 * Creates a bare origin repo and local clone checked out on `branchName`.
 */
async function createBareAndClonedRepo(
  baseDir,
  repoName,
  jenkinsJobName = '',
  { workRootOverride = '', branchName = 'master' } = {}
) {
  const bareDir = path.join(baseDir, 'remotes', `${repoName}.git`);
  const workRoot = workRootOverride || path.join(baseDir, 'workspaces', `${repoName}-ws`);
  const cloneDir = path.join(workRoot, repoName);

  await fsp.mkdir(bareDir, { recursive: true });
  await fsp.mkdir(workRoot, { recursive: true });

  await runGit(bareDir, ['init', '--bare', `--initial-branch=${branchName}`]);
  await runGit(workRoot, ['clone', bareDir, cloneDir]);
  await runGit(cloneDir, ['config', 'user.name', 'Test User']);
  await runGit(cloneDir, ['config', 'user.email', 'test@example.com']);
  await runGit(cloneDir, ['checkout', '-B', branchName]);

  await fsp.mkdir(path.join(cloneDir, 'src'), { recursive: true });
  await fsp.writeFile(path.join(cloneDir, 'src', 'app.js'), 'export const version = 1;\n', 'utf8');
  if (jenkinsJobName) {
    await fsp.writeFile(
      path.join(cloneDir, 'Jenkinsfile'),
      `def name = '${jenkinsJobName}'\npipeline {}\n`,
      'utf8'
    );
  }

  await runGit(cloneDir, ['add', '-A']);
  await runGit(cloneDir, ['commit', '-m', 'Initial commit']);
  await runGit(cloneDir, ['push', '-u', 'origin', branchName]);

  return { bareDir, workRoot, cloneDir };
}

describe('Unit Helpers & Interactive Setup Wizard', () => {
  it('parses Jenkinsfile job name, expands paths, and normalizes nested Jenkins URLs cleanly', () => {
    assert.equal(parseJenkinsfileJobName("def name = 'billing_api'\n"), 'billing_api');
    assert.equal(parseJenkinsfileJobName('name = "portal_web"'), 'portal_web');
    assert.equal(parseJenkinsfileJobName('pipeline {}'), null);

    assert.equal(expandUserPath("'~/my-folder'"), path.join(os.homedir(), 'my-folder'));

    assert.equal(normalizeJenkinsJobPath('billing_api'), '/job/billing_api');
    assert.equal(
      normalizeJenkinsJobPath('Prod/payments/payments.example.com-GATE'),
      '/job/Prod/job/payments/job/payments.example.com-GATE'
    );
    assert.equal(
      rewriteToBaseOrigin('http://127.0.0.1:8080/queue/item/99/', 'https://jenkins.example.com'),
      'https://jenkins.example.com/queue/item/99/'
    );
  });

  it('builds agy CLI arguments with attached photos, --add-dir, AI models (Gemini & Claude Opus 5.5), and 3 model levels (low/medium/high)', () => {
    assert.deepEqual(VALID_MODEL_LEVELS, ['low', 'medium', 'high']);
    assert.ok(GEMINI_MODEL_FAMILIES.some((f) => f.family === 'claude-opus-5-5'));
    assert.ok(GEMINI_MODEL_FAMILIES.some((f) => f.family === 'gemini-4-carbon'));

    const resolved = resolveEffectiveModelAndLevel({ model: 'gemeni 3.8', modelLevel: 'high' });
    assert.equal(resolved.modelId, 'gemini-3.8-flash-high');
    assert.equal(resolved.effort, 'high');

    const switchedTier = resolveEffectiveModelAndLevel({
      model: 'gemini-3.8-flash-high',
      modelLevel: 'low'
    });
    assert.equal(switchedTier.modelId, 'gemini-3.8-flash-low');
    assert.equal(switchedTier.effort, 'low');

    const carbonLow = resolveEffectiveModelAndLevel({
      model: 'gemini 4 carbon',
      modelLevel: 'low'
    });
    assert.equal(carbonLow.modelId, 'gemini-4-carbon-low');
    assert.equal(carbonLow.effort, 'low');
    assert.equal(carbonLow.displayLabel, 'Gemini 4 Carbon (low)');

    const carbonMed = resolveEffectiveModelAndLevel({
      model: 'gemini-4-carbon',
      modelLevel: 'medium'
    });
    assert.equal(carbonMed.modelId, 'gemini-4-carbon-medium');
    assert.equal(carbonMed.effort, 'medium');
    assert.equal(carbonMed.displayLabel, 'Gemini 4 Carbon (medium)');

    const carbonHigh = resolveEffectiveModelAndLevel({
      model: 'carbon',
      modelLevel: 'high'
    });
    assert.equal(carbonHigh.modelId, 'gemini-4-carbon-high');
    assert.equal(carbonHigh.effort, 'high');
    assert.equal(carbonHigh.displayLabel, 'Gemini 4 Carbon (high)');

    const opusResolved = resolveEffectiveModelAndLevel({
      model: 'cloud opus 5.5',
      modelLevel: 'medium'
    });
    assert.equal(opusResolved.modelId, 'claude-opus-5-5-medium');
    assert.equal(opusResolved.effort, 'medium');
    assert.equal(opusResolved.displayLabel, 'Claude Opus 5.5 (medium)');

    // Legacy xhigh/max normalizes cleanly to high
    const legacyMax = resolveEffectiveModelAndLevel({
      model: 'gemini-3.8-flash',
      modelLevel: 'max'
    });
    assert.equal(legacyMax.modelId, 'gemini-3.8-flash-high');
    assert.equal(legacyMax.effort, 'high');

    const args = buildAgyArgs({
      prompt: 'Update header',
      imagePaths: ['/tmp/bot-uploads/shot1.jpg'],
      conversationId: 'conv-abc',
      model: 'gemini-3.8-flash',
      modelLevel: 'high',
      skipPermissions: true,
      extraDirs: ['/tmp/shared-lib']
    });
    assert.ok(args.includes('--dangerously-skip-permissions'));
    assert.ok(args.includes('--conversation'));
    assert.ok(args.includes('conv-abc'));
    assert.ok(args.includes('--model'));
    assert.ok(args.includes('gemini-3.8-flash-high'));
    assert.ok(args.includes('--effort'));
    assert.ok(args.includes('high'));
    assert.ok(args.includes('/tmp/bot-uploads'));
    assert.ok(args.includes('/tmp/shared-lib'));
    assert.match(args[1], /Attached User Photo\(s\)/);
    assert.match(args[1], /\/tmp\/bot-uploads\/shot1\.jpg/);

    const plistXml = buildLaunchdPlistXml({
      projectRoot: '/opt/mobile-agent-control',
      homeDir: '/Users/example'
    });
    assert.match(plistXml, /com\.domonk\.mobile-agent-control/);
    assert.match(plistXml, /GIT_TERMINAL_PROMPT/);
  });

  it('executes workspace tools and supports Option 1 (CLI) & Option 2 (Direct API) unified runner', async () => {
    const tmpDir = await fsp.mkdtemp(path.join(os.tmpdir(), 'mac-tools-test-'));
    try {
      // 1. write_file
      const writeRes = await executeWorkspaceTool(tmpDir, 'write_file', {
        path: 'src/main.js',
        content: 'console.log("hello world");\n'
      });
      assert.match(writeRes, /Successfully wrote/);

      // 2. read_file
      const readContent = await executeWorkspaceTool(tmpDir, 'read_file', { path: 'src/main.js' });
      assert.equal(readContent, 'console.log("hello world");\n');

      // 3. edit_file
      const editRes = await executeWorkspaceTool(tmpDir, 'edit_file', {
        path: 'src/main.js',
        target: 'hello world',
        replacement: 'hello agent'
      });
      assert.match(editRes, /Successfully edited/);
      const afterEdit = await executeWorkspaceTool(tmpDir, 'read_file', { path: 'src/main.js' });
      assert.equal(afterEdit, 'console.log("hello agent");\n');

      // 4. list_dir
      const listRes = await executeWorkspaceTool(tmpDir, 'list_dir', { path: 'src' });
      assert.match(listRes, /main\.js/);

      // 5. run_command
      const cmdRes = await executeWorkspaceTool(tmpDir, 'run_command', { command: 'node src/main.js' });
      assert.equal(cmdRes, 'hello agent');

      // 6. Direct API error when key missing
      assert.rejects(
        async () => {
          const { promise } = runDirectApiTurn({
            workspacePath: tmpDir,
            prompt: 'Test prompt',
            provider: 'deepseek',
            apiKey: ''
          });
          await promise;
        },
        /DeepSeek API key is not configured/
      );

      // 7. Model normalization for new providers
      const dskNorm = resolveEffectiveModelAndLevel({ model: 'deepseek-chat' });
      assert.equal(dskNorm.modelId, 'deepseek-chat');
      assert.equal(dskNorm.displayLabel, 'DeepSeek V3');

      const gpt4oNorm = resolveEffectiveModelAndLevel({ model: 'gpt-4o' });
      assert.equal(gpt4oNorm.modelId, 'gpt-4o');
      assert.equal(gpt4oNorm.displayLabel, 'OpenAI GPT-4o');

      const qwenNorm = resolveEffectiveModelAndLevel({ model: 'qwen-2.5-coder' });
      assert.equal(qwenNorm.modelId, 'qwen-2.5-coder-32b');
      assert.equal(qwenNorm.displayLabel, 'Qwen 2.5 Coder 32B');
    } finally {
      await fsp.rm(tmpDir, { recursive: true, force: true });
    }
  });

  it('validates git branch names accurately', async () => {
    assert.equal(await validateGitBranchName('feat/mobile-fix'), true);
    assert.equal(await validateGitBranchName('release-2.0'), true);
    assert.equal(await validateGitBranchName('bad branch name'), false);
    assert.equal(await validateGitBranchName('bad..branch'), false);
    assert.equal(await validateGitBranchName('-flag'), false);
  });

  it('escapes HTML and splits oversized Telegram messages safely', () => {
    assert.equal(escapeHtml('<b>a & b</b>'), '&lt;b&gt;a &amp; b&lt;/b&gt;');
    const longText = Array.from({ length: 120 }, (_, i) => `Line ${i}: ${'x'.repeat(40)}`).join('\n');
    const chunks = splitTelegramText(longText, 1500);
    assert.ok(chunks.length >= 4);
    for (const c of chunks) {
      assert.ok(c.length <= 1500);
    }
  });

  it('cleans Antigravity transcript XML wrappers and discovers workspace conversations', async () => {
    const raw =
      '<ADDITIONAL_METADATA>meta</ADDITIONAL_METADATA>\n<USER_REQUEST>\nFix login button\n[Attached User Photo(s) — read each image file:\n  1. /tmp/a.jpg]\n\n[Telegram Controller Instruction: Modify workspace files only.]\n</USER_REQUEST>';
    assert.equal(cleanUserPromptText(raw), 'Fix login button');

    const tmpBrain = await fsp.mkdtemp(path.join(os.tmpdir(), 'agy-brain-unit-'));
    try {
      const convDir = path.join(tmpBrain, 'conv-111', '.system_generated', 'logs');
      await fsp.mkdir(convDir, { recursive: true });
      const lines = [
        JSON.stringify({
          type: 'USER_INPUT',
          content: 'Active Workspaces:\n- /tmp/ws-alpha\n<USER_REQUEST>First prompt</USER_REQUEST>'
        }),
        JSON.stringify({ type: 'PLANNER_RESPONSE', content: 'First answer' }),
        JSON.stringify({ type: 'USER_INPUT', content: '<USER_REQUEST>Second prompt</USER_REQUEST>' }),
        JSON.stringify({ type: 'PLANNER_RESPONSE', content: 'Second answer' })
      ];
      await fsp.writeFile(path.join(convDir, 'transcript.jsonl'), `${lines.join('\n')}\n`, 'utf8');

      const msgs = await readTranscriptMessages(tmpBrain, 'conv-111');
      assert.equal(msgs.length, 4);
      assert.equal(msgs[0].text, 'First prompt');
      assert.equal(msgs[3].text, 'Second answer');

      const found = await discoverRecentWorkspaceConversations(tmpBrain, '/tmp/ws-alpha');
      assert.equal(found.length, 1);
      assert.equal(found[0].conversationId, 'conv-111');
      assert.equal(found[0].preview, 'Second prompt');

      // When a sibling `conversations/` trajectory store exists (like `~/.gemini/antigravity-cli/conversations`),
      // only conversations with a corresponding `<id>.db` file are treated as resumable.
      const tmpCliRoot = await fsp.mkdtemp(path.join(os.tmpdir(), 'agy-cli-root-'));
      try {
        const cliBrain = path.join(tmpCliRoot, 'brain');
        const cliConvs = path.join(tmpCliRoot, 'conversations');
        await fsp.mkdir(cliConvs, { recursive: true });
        for (const id of ['conv-has-db', 'conv-missing-db']) {
          const logsDir = path.join(cliBrain, id, '.system_generated', 'logs');
          await fsp.mkdir(logsDir, { recursive: true });
          await fsp.writeFile(
            path.join(logsDir, 'transcript.jsonl'),
            `${JSON.stringify({
              type: 'USER_INPUT',
              content: 'Active Workspaces:\n- /tmp/ws-beta\n<USER_REQUEST>Hello</USER_REQUEST>'
            })}\n`,
            'utf8'
          );
        }
        await fsp.writeFile(path.join(cliConvs, 'conv-has-db.db'), 'sqlite', 'utf8');

        const cliFound = await discoverRecentWorkspaceConversations(cliBrain, '/tmp/ws-beta');
        assert.deepEqual(
          cliFound.map((c) => c.conversationId),
          ['conv-has-db']
        );
      } finally {
        await fsp.rm(tmpCliRoot, { recursive: true, force: true });
      }

      // Verify CLI brain dir default & legacy Desktop IDE brain dir auto-migration
      assert.match(resolveDefaultAgyBrainDir('/Users/demo'), /\/Users\/demo\/\.gemini\/antigravity-cli\/brain$/);
      assert.equal(
        isMissingTrajectoryError(
          new Error(
            'Agent finished with status ERROR: error: failed to send message: not_found: trajectory not found: 554658dd-7e8d-41fb-8d30-74c4673458dc: not found'
          )
        ),
        true
      );
      assert.equal(isMissingTrajectoryError(new Error('Agent run stopped by user')), false);

      const tmpMigrateDir = await fsp.mkdtemp(path.join(os.tmpdir(), 'agy-cfg-migrate-'));
      try {
        await fsp.writeFile(
          path.join(tmpMigrateDir, 'config.json'),
          JSON.stringify({
            telegramBotToken: '111:TOK',
            antigravityBrainDir: resolveLegacyDesktopBrainDir()
          }),
          'utf8'
        );
        const migStore = new ConfigStore(tmpMigrateDir);
        await migStore.init({ seedWorkspaces: [] });
        assert.equal(migStore.config.antigravityBrainDir, resolveDefaultAgyBrainDir());
      } finally {
        await fsp.rm(tmpMigrateDir, { recursive: true, force: true });
      }
    } finally {
      await fsp.rm(tmpBrain, { recursive: true, force: true });
    }
  });

  it('throws MissingBotTokenError / MissingSessionPasswordError and prompts startup password on stdin', async () => {
    const tmpDir = await fsp.mkdtemp(path.join(os.tmpdir(), 'agy-missing-token-'));
    const prevToken = process.env.TELEGRAM_BOT_TOKEN;
    delete process.env.TELEGRAM_BOT_TOKEN;
    try {
      await assert.rejects(
        () => startBotRunner({ dataDir: tmpDir, seedWorkspaces: [], sessionPassword: 'abc' }),
        (err) => err instanceof MissingBotTokenError
      );

      process.env.TELEGRAM_BOT_TOKEN = '123456:DUMMY_TOKEN';
      await assert.rejects(
        () => startBotRunner({ dataDir: tmpDir, seedWorkspaces: [], sessionPassword: '   ' }),
        (err) => err instanceof MissingSessionPasswordError
      );

      // Verify promptStartupPassword re-prompts on empty line and returns trimmed password
      const fakeIn = new PassThrough();
      const fakeOut = new PassThrough();
      let outText = '';
      fakeOut.on('data', (c) => {
        outText += c.toString('utf8');
      });
      fakeIn.write('   \n');
      fakeIn.write('run-only-pass-42\n');
      fakeIn.end();

      const entered = await promptStartupPassword({
        inputStream: fakeIn,
        outputStream: fakeOut
      });
      assert.equal(entered, 'run-only-pass-42');
      assert.match(outText, /Password cannot be empty/);
    } finally {
      if (prevToken !== undefined) {
        process.env.TELEGRAM_BOT_TOKEN = prevToken;
      } else {
        delete process.env.TELEGRAM_BOT_TOKEN;
      }
      await fsp.rm(tmpDir, { recursive: true, force: true });
    }
  });

  it('runs interactive setup wizard (Steps 1-7) scanning folders, Gemini models/levels, branches, paths, and Jenkins jobs', async () => {
    const tmpSetupRoot = await fsp.mkdtemp(path.join(os.tmpdir(), 'agy-setup-wiz-'));
    try {
      const wsDir = path.join(tmpSetupRoot, 'my-stack');
      await createBareAndClonedRepo(tmpSetupRoot, 'api-service', 'api_default', {
        workRootOverride: wsDir,
        branchName: 'main'
      });
      await createBareAndClonedRepo(tmpSetupRoot, 'shared-utils', '', {
        workRootOverride: wsDir,
        branchName: 'develop'
      });
      // Non-git docs folder should be ignored gracefully
      await fsp.mkdir(path.join(wsDir, 'docs-notes'), { recursive: true });

      const answers = [
        '999888:BOT_TOK',             // 1. Telegram Bot Token
        '1001, 1002',                 // 2. Allowed User IDs
        '8',                          // 3. Latest X Messages count (fixed in bot)
        'https://jenkins.example.com',// 4. Jenkins Base URL
        'deploy-bot',                 // 5. Jenkins Username
        'jenkins-api-tok-xyz',        // 6. Jenkins API Token
        'ghp_mock_token_12345',       // 7. GitHub Personal Access Token (PAT)
        'acme-org',                   // 8. Default GitHub Owner / Org
        'my-gcp-project',             // 9. Google Cloud Project ID
        '-',                          // 10. Service Account Key JSON
        'us-central1',                // 11. Google Cloud Region
        'gemini-3.8-flash',           // 12. Default AI Model Family
        'high',                       // 13. Default Effort Level
        '1',                          // 14. AI Execution Engine (1: agy)
        '',                           // 15. Antigravity CLI path (keep default)
        '',                           // 16. Aider CLI path (keep default)
        'n',                          // 17. Configure Direct API keys? -> No
        wsDir,                        // 18. Paste workspace directory
        'stack',                      // Workspace short name
        'My Stack',                   // Workspace display label
        'gemini 3.8',                 // Gemini model
        'high',                       // Model level
        'https://app.example.com',    // Live URL
        '-',                          // Extra --add-dir paths
        'multi',                      // Deployment environments: multi (staging + prod)
        // Repo 1: api-service
        'y',                          // Include repo?
        '',                           // Repo path (keep default)
        '',                           // Git branch (keep detected 'main')
        'y',                          // Enable Jenkins deploy?
        'Staging/MyStack/api-service',// Staging Jenkins job path
        'https://jenkins.example.com/job/Prod/job/MyStack/job/api-service/', // Prod Jenkins job URL link!
        // Repo 2: shared-utils
        'y',                          // Include repo?
        '',                           // Repo path (keep default)
        'develop',                    // Git branch
        'n',                          // Enable Jenkins deploy? -> No!
        // Extra workspace-level Staging Jenkins jobs
        'Staging/MyStack/web-frontend',
        // Extra workspace-level Production Jenkins jobs
        'Prod/MyStack/web-frontend',
        // Quick `model 1` shortcut to verify changing Gemini model & level in setup
        'model 1',
        '2',                          // Select 2) gemini-4-argon
        'medium',                     // Level: medium
        // Switch back to Gemini 3.8 Flash high via `model 1`
        'model 1',
        '1',                          // Select 1) gemini-3.8-flash
        'high',                       // Level: high
        // Finish workspace loop
        ''
      ];

      let ansIdx = 0;
      const store = await runSetupWizard({
        dataDir: path.join(tmpSetupRoot, 'data'),
        ask: async () => answers[ansIdx++] ?? '',
        log: () => {},
        warn: () => {},
        verifyTelegram: false
      });

      assert.equal(store.config.telegramBotToken, '999888:BOT_TOK');
      assert.equal(store.config.password, undefined);
      assert.deepEqual(store.config.allowedUserIds, ['1001', '1002']);
      assert.equal(store.config.defaultHistoryCount, 8);
      assert.equal(store.config.jenkins.baseUrl, 'https://jenkins.example.com');
      assert.equal(store.config.jenkins.username, 'deploy-bot');
      assert.equal(store.config.github.token, 'ghp_mock_token_12345');
      assert.equal(store.config.github.owner, 'acme-org');
      assert.equal(store.config.googleCloud.projectId, 'my-gcp-project');
      assert.equal(store.config.googleCloud.region, 'us-central1');

      assert.equal(store.config.workspaces.length, 1);
      const ws = store.config.workspaces[0];
      assert.equal(ws.id, 'stack');
      assert.equal(ws.label, 'My Stack');
      assert.equal(ws.name, undefined);
      assert.equal(ws.model, 'gemini-3.8-flash-high');
      assert.equal(ws.modelLevel, 'high');
      assert.equal(ws.liveUrl, 'https://app.example.com');
      assert.equal(ws.environmentMode, 'multi');
      assert.deepEqual(ws.jenkinsJobs, [
        'Staging/MyStack/api-service',
        'Staging/MyStack/web-frontend'
      ]);
      assert.deepEqual(ws.prodJenkinsJobs, [
        'Prod/MyStack/api-service',
        'Prod/MyStack/web-frontend'
      ]);
      assert.equal(ws.repos.length, 2);

      const apiRepo = ws.repos.find((r) => r.name === 'api-service');
      assert.equal(apiRepo.branch, 'main');
      assert.equal(apiRepo.deployEnabled, true);
      assert.equal(apiRepo.jenkinsJob, 'Staging/MyStack/api-service');
      assert.equal(apiRepo.prodJenkinsJob, 'Prod/MyStack/api-service');

      const sharedRepo = ws.repos.find((r) => r.name === 'shared-utils');
      assert.equal(sharedRepo.branch, 'develop');
      assert.equal(sharedRepo.deployEnabled, false);
      assert.equal(sharedRepo.jenkinsJob, '');
      assert.equal(sharedRepo.prodJenkinsJob, '');
    } finally {
      await fsp.rm(tmpSetupRoot, { recursive: true, force: true });
    }
  });

  it('supports GitHub & Google Cloud CI/CD clients, repo parsing, and console access commands', async () => {
    // 1. Repo slug parsing
    assert.deepEqual(parseGitHubRepoSlug('owner/repo'), { owner: 'owner', repo: 'repo', fullName: 'owner/repo' });
    assert.deepEqual(parseGitHubRepoSlug('repo', 'default-org'), { owner: 'default-org', repo: 'repo', fullName: 'default-org/repo' });
    assert.deepEqual(parseGitHubRepoSlug('https://github.com/my-org/my-project.git'), { owner: 'my-org', repo: 'my-project', fullName: 'my-org/my-project' });

    // 2. Google Cloud client validation & mock trigger
    const gcp = new GoogleCloudClient({ projectId: 'demo-gcp-project', region: 'europe-west1' });
    const gcpConn = await gcp.testConnection();
    assert.equal(gcpConn.ok, true);
    assert.equal(gcpConn.projectId, 'demo-gcp-project');
    assert.equal(gcpConn.region, 'europe-west1');

    const gcpBuild = await gcp.triggerBuild({ triggerId: 'my-trigger', branch: 'master' });
    assert.equal(gcpBuild.ok, true);
    assert.equal(gcpBuild.status, 'SUCCESS');
    assert.equal(gcpBuild.triggerId, 'my-trigger');

    // 3. GitHub client error when token missing
    const ghMissing = new GitHubClient({ token: '' });
    await assert.rejects(async () => ghMissing.testConnection(), /GitHub Personal Access Token is required/);

    // 4. Test console commands routing via executeConsoleCommand
    const tmpDir = await fsp.mkdtemp(path.join(os.tmpdir(), 'ci-cmd-test-'));
    try {
      const store = new ConfigStore(path.join(tmpDir, 'data'));
      await store.init();

      // Test github-test-access when unconfigured
      const logs = [];
      const warns = [];
      const testRes = await runTestGithubConsole({
        store,
        log: (m) => logs.push(m),
        warn: (m) => warns.push(m)
      });
      assert.equal(testRes.ok, false);

      // Test google-cloud-test-access
      store.config.googleCloud.projectId = 'valid-gcp-project';
      const gcpTestRes = await runTestGoogleCloudConsole({
        store,
        log: (m) => logs.push(m),
        warn: (m) => warns.push(m)
      });
      assert.equal(gcpTestRes.ok, true);

      // Verify executeConsoleCommand handles the new commands
      const resGh = await executeConsoleCommand('github-test-access', {
        configStore: store,
        log: () => {},
        warn: () => {}
      });
      assert.equal(resGh.handled, true);
      assert.equal(resGh.command, 'github-test-access');

      const resGcp = await executeConsoleCommand('google-cloud-test-access', {
        configStore: store,
        log: () => {},
        warn: () => {}
      });
      assert.equal(resGcp.handled, true);
      assert.equal(resGcp.command, 'google-cloud-test-access');

      const resJnk = await executeConsoleCommand('jenkins-test-access', {
        configStore: store,
        log: () => {},
        warn: () => {}
      });
      assert.equal(resJnk.handled, true);
      assert.equal(resJnk.command, 'jenkins-test-access');
    } finally {
      await fsp.rm(tmpDir, { recursive: true, force: true });
    }
  });
});

describe('Telegram Bot End-to-End Controller & Workflow', () => {
  let tmpRoot;
  let mockTg;
  let mockJenkins;
  let coreRepo;
  let webRepo;
  let brainDir;
  let configStore;
  let telegram;
  let controller;
  let currentNow;
  let nextAgentBehavior;
  let lastAgentCallArgs;

  const CHAT_ID = 7001;
  const USER_ID = 42001;
  let msgSeq = 1;
  let cbSeq = 1;

  function makeUserMsg(text, extra = {}) {
    return {
      update_id: msgSeq,
      message: {
        message_id: msgSeq++,
        chat: { id: CHAT_ID, type: 'private' },
        from: { id: USER_ID, username: 'alice' },
        ...(text !== undefined ? { text } : {}),
        ...extra
      }
    };
  }

  function makeCallback(data, messageId = 101) {
    return {
      update_id: 10000 + cbSeq,
      callback_query: {
        id: `cb-${cbSeq++}`,
        from: { id: USER_ID, username: 'alice' },
        message: {
          message_id: messageId,
          chat: { id: CHAT_ID, type: 'private' }
        },
        data
      }
    };
  }

  before(async () => {
    tmpRoot = await fsp.mkdtemp(path.join(os.tmpdir(), 'agy-tg-e2e-'));
    mockTg = await startMockTelegramServer();
    mockJenkins = await startMockJenkinsServer();

    coreRepo = await createBareAndClonedRepo(tmpRoot, 'payments_gate', 'payments_gate');
    webRepo = await createBareAndClonedRepo(tmpRoot, 'portal_web', '');

    brainDir = path.join(tmpRoot, 'brain');
    const existingConvDir = path.join(brainDir, 'conv-core-existing', '.system_generated', 'logs');
    await fsp.mkdir(existingConvDir, { recursive: true });
    await fsp.writeFile(
      path.join(existingConvDir, 'transcript.jsonl'),
      [
        JSON.stringify({
          type: 'USER_INPUT',
          content: `Active Workspaces:\n- ${coreRepo.workRoot}\n<USER_REQUEST>Earlier desktop question 1</USER_REQUEST>`
        }),
        JSON.stringify({ type: 'PLANNER_RESPONSE', content: 'Earlier desktop answer 1' }),
        JSON.stringify({ type: 'USER_INPUT', content: '<USER_REQUEST>Earlier desktop question 2</USER_REQUEST>' }),
        JSON.stringify({ type: 'PLANNER_RESPONSE', content: 'Earlier desktop answer 2' })
      ].join('\n') + '\n',
      'utf8'
    );

    configStore = new ConfigStore(path.join(tmpRoot, 'data'));
    await configStore.init({
      seedWorkspaces: [
        {
          id: 'payments',
          name: 'payments',
          label: 'Payments Platform',
          path: coreRepo.workRoot,
          liveUrl: 'https://payments.example.com',
          jenkinsJobs: [
            'Prod/payments/payments.example.com-BACKOFFICE',
            'Prod/payments/payments.example.com-GATE'
          ],
          repoJobs: {
            payments_gate: 'Prod/payments/payments.example.com-GATE'
          }
        },
        {
          id: 'portal',
          name: 'portal',
          label: 'Web Portal',
          path: webRepo.workRoot,
          jenkinsJobs: ['Prod/portal/portal.example.com-FRONTEND']
        }
      ]
    });

    configStore.config.telegramBotToken = '123456:TEST_BOT_TOKEN';
    configStore.config.telegramApiBaseUrl = mockTg.baseUrl;
    configStore.config.defaultHistoryCount = 2;
    configStore.config.antigravityBrainDir = brainDir;
    configStore.config.jenkins = {
      baseUrl: mockJenkins.baseUrl,
      username: 'admin',
      apiToken: 'tok-123',
      jobPrefix: '',
      insecureTls: false,
      pollIntervalMs: 25,
      buildTimeoutMs: 10_000
    };
    await configStore.saveConfig();
    configStore.setRuntimePassword('run-secret-1');

    telegram = new TelegramApi({
      token: configStore.config.telegramBotToken,
      baseUrl: mockTg.baseUrl
    });

    currentNow = new Date('2026-11-08T10:00:00');
    nextAgentBehavior = async () => ({
      conversationId: 'conv-new-1',
      response: 'Done.'
    });

    controller = new BotController({
      configStore,
      telegram,
      nowProvider: () => currentNow,
      inputCoalesceMs: 40,
      jenkinsFactory: (cfg) => new JenkinsClient(cfg),
      agentRunner: (opts) => {
        lastAgentCallArgs = opts;
        return {
          promise: Promise.resolve().then(() => nextAgentBehavior(opts)),
          abort: () => {}
        };
      }
    });
  });

  after(async () => {
    await mockTg?.close();
    await mockJenkins?.close();
    if (tmpRoot) {
      await fsp.rm(tmpRoot, { recursive: true, force: true });
    }
  });

  it('enforces per-run startup password, stays unlocked across days, and requires new password on app re-run', async () => {
    mockTg.clearSent();

    // Never persists password into config.json
    const savedCfgRaw = JSON.parse(await fsp.readFile(configStore.configFile, 'utf8'));
    assert.equal(savedCfgRaw.password, undefined);

    await controller.handleUpdate(makeUserMsg('/start'));
    assert.match(mockTg.lastSent().text, /Session requires authentication/);
    assert.match(mockTg.lastSent().text, /Mobile Agent Control \(MAC\)/);

    const wrongUpd = makeUserMsg('wrong-pass');
    await controller.handleUpdate(wrongUpd);
    assert.ok(mockTg.deletedMessages.some((d) => d.messageId === wrongUpd.message.message_id));
    assert.match(mockTg.lastSent().text, /Invalid password/);

    const rightUpd = makeUserMsg('run-secret-1');
    await controller.handleUpdate(rightUpd);
    assert.ok(mockTg.deletedMessages.some((d) => d.messageId === rightUpd.message.message_id));
    assert.ok(mockTg.sentMessages.some((m) => /Session unlocked!/.test(m.text)));
    assert.match(mockTg.lastSent().text, /Select a Workspace/);
    assert.doesNotMatch(mockTg.lastSent().text, /\bIDE\b/);

    // Advance several calendar days WITHOUT restarting app -> stays unlocked (NOT daily!)
    currentNow = new Date('2026-11-12T14:30:00');
    mockTg.clearSent();
    await controller.handleUpdate(makeUserMsg('/workspaces'));
    assert.match(mockTg.lastSent().text, /Select a Workspace/);

    // Simulate restarting the application with a brand-new password (`npm start`)
    configStore.setRuntimePassword('run-secret-2');
    mockTg.clearSent();
    await controller.handleUpdate(makeUserMsg('/ides'));
    assert.match(mockTg.lastSent().text, /Invalid password/);

    // Old run password must fail; new run password unlocks
    await controller.handleUpdate(makeUserMsg('run-secret-1'));
    assert.match(mockTg.lastSent().text, /Invalid password/);

    await controller.handleUpdate(makeUserMsg('run-secret-2'));
    const unlockedMsg = mockTg.sentMessages.find((m) => /Session unlocked!/.test(m.text));
    assert.ok(unlockedMsg);
    assert.deepEqual(unlockedMsg.reply_markup.keyboard, [
      [{ text: REPLY_BTN_SWITCH_IDE }, { text: REPLY_BTN_SETTINGS }]
    ]);
  });

  it('shows workspace labels (without name field), makes ✅ Same Chat default when typing immediately, and supports New Chat & Latest Messages', async () => {
    // Verify `name` property is stripped from config.json workspaces in favor of `id` + `label`
    for (const wsCfg of configStore.config.workspaces) {
      assert.equal(wsCfg.name, undefined);
      assert.ok(wsCfg.id);
      assert.ok(wsCfg.label);
    }

    mockTg.clearSent();
    await controller.handleUpdate(makeUserMsg('/ides'));
    const ideMenuMsg = mockTg.lastSent();
    assert.match(
      ideMenuMsg.text,
      /🗂 <b>Select a Workspace:<\/b>\n\n🟢 <i>Ready<\/i>\n⏳ <i>Running<\/i>\n🟣 <i>Waiting for your Yes\/No<\/i>/
    );
    // 2 workspaces (even) -> Row 1 has 2 workspaces, Row 2 has full-width ⚙️ Settings
    assert.equal(ideMenuMsg.reply_markup.inline_keyboard.length, 2);
    assert.equal(ideMenuMsg.reply_markup.inline_keyboard[0].length, 2);
    assert.deepEqual(ideMenuMsg.reply_markup.inline_keyboard[1], [
      { text: '⚙️ Settings', callback_data: 'cfg:menu' }
    ]);
    const ideMenuBtns = ideMenuMsg.reply_markup.inline_keyboard.flat().map((b) => b.text);
    assert.ok(ideMenuBtns.some((t) => t.includes('Payments Platform')));
    assert.ok(ideMenuBtns.some((t) => t.includes('Web Portal')));
    assert.ok(!ideMenuBtns.some((t) => /\bpayments\b/.test(t)));

    // Settings menu must show AI Model Settings with workspace labels (no X=5 / X=10 buttons)
    mockTg.clearSent();
    await controller.handleUpdate(makeUserMsg('/settings'));
    const settingsMsg = mockTg.lastSent();
    assert.match(settingsMsg.text, /AI Model Settings/);
    assert.match(settingsMsg.text, /Payments Platform/);
    assert.doesNotMatch(settingsMsg.text, /X=5|X=10/);
    const settingsCbs = settingsMsg.reply_markup.inline_keyboard.flat().map((b) => b.callback_data);
    assert.ok(!settingsCbs.some((c) => c.startsWith('cfg:x:')));
    assert.ok(settingsCbs.includes('ide:cfg:payments'));
    assert.ok(settingsCbs.includes('ide:cfg:portal'));

    mockTg.clearSent();
    await controller.handleUpdate(makeCallback('ide:sel:payments'));
    const selectMsg = mockTg.lastSent();
    assert.equal(REPLY_BTN_SWITCH_IDE, '🔀 Workspace');
    assert.match(
      selectMsg.text,
      /🗂 <b>Workspace Selected<\/b>\n<b>Payments Platform<\/b>\n<code>[^<]+<\/code>\n\n🧠 AI Model:/
    );
    assert.doesNotMatch(selectMsg.text, /📁/);
    assert.doesNotMatch(selectMsg.text, /\bIDE\b/);
    assert.doesNotMatch(selectMsg.text, /Show Latest/i);
    assert.doesNotMatch(selectMsg.text, /is active by default/i);
    const selectRows = selectMsg.reply_markup.inline_keyboard;
    assert.equal(selectRows.length, 2);
    assert.deepEqual(
      selectRows[0].map((b) => b.text),
      ['✅ Same Chat •', '🆕 New Chat']
    );
    assert.deepEqual(selectRows[1], [
      { text: '📜 History', callback_data: 'chat:hist:payments' },
      { text: '🧠 AI Model', callback_data: 'ide:cfg:payments' }
    ]);
    const flatButtons = selectRows.flat();
    assert.ok(!flatButtons.some((b) => b.callback_data.startsWith('chat:pick:')));
    assert.ok(!flatButtons.some((b) => /AI Model & Level/i.test(b.text)));

    // Tapping 📜 History on Workspace Selected shows history of the current chat
    mockTg.clearSent();
    await controller.handleUpdate(makeCallback('chat:hist:payments'));
    assert.match(mockTg.lastSent().text, /Latest 2 of 4 message\(s\) in Payments Platform/);

    // Without clicking ✅ Same Chat, typing a prompt immediately must auto-continue Same Chat!
    nextAgentBehavior = async () => ({
      conversationId: 'conv-core-existing',
      response: 'Continued existing desktop chat seamlessly.'
    });
    mockTg.clearSent();
    await controller.handleUpdate(makeUserMsg('Continue what we discussed earlier'));
    await controller.waitForBackgroundTasks();
    assert.equal(lastAgentCallArgs.conversationId, 'conv-core-existing');

    // Passing `/history 10` strictly obeys setup config `defaultHistoryCount = 2`
    mockTg.clearSent();
    await controller.handleUpdate(makeUserMsg('/history 10'));
    assert.match(mockTg.lastSent().text, /Latest 2 of 4 message\(s\) in Payments Platform/);
    assert.match(mockTg.lastSent().text, /Earlier desktop question 2/);
    assert.match(mockTg.lastSent().text, /Earlier desktop answer 2/);
    assert.doesNotMatch(mockTg.lastSent().text, /Earlier desktop question 1/);

    mockTg.clearSent();
    await controller.handleUpdate(makeCallback('chat:new:payments'));
    assert.match(mockTg.lastSent().text, /New Chat Ready in Payments Platform/);
    assert.equal(configStore.getWorkspaceState('payments').conversationId, null);

    // Tapping ✅ Same Chat switches back to continuing Same Chat without dumping history
    mockTg.clearSent();
    await controller.handleUpdate(makeCallback('chat:same:payments'));
    assert.equal(mockTg.sentMessages.length, 1);
    assert.match(mockTg.lastSent().text, /Continuing Same Chat in Payments Platform/);
    const sameChatBtns = mockTg.lastSent().reply_markup.inline_keyboard.flat();
    const newChatBtnInSame = sameChatBtns.find((b) => b.callback_data === 'chat:new:payments');
    assert.equal(newChatBtnInSame.text, '🆕 New Chat');
    assert.ok(!sameChatBtns.some((b) => /Instead/i.test(b.text)));
    assert.ok(!sameChatBtns.some((b) => b.callback_data === 'ide:menu'));

    // Reset back to New Chat for the next test
    await controller.handleUpdate(makeCallback('chat:new:payments'));
  });

  it('handles photo + text prompt, lists changed files, and discards cleanly on Commit -> No', async () => {
    const manualWipFile = path.join(coreRepo.cloneDir, 'manual-wip.txt');
    await fsp.writeFile(manualWipFile, 'keep my manual notes\n', 'utf8');

    mockTg.clearSent();
    await controller.handleUpdate(
      makeUserMsg(undefined, {
        photo: [
          { file_id: 'small_id', width: 100, height: 100 },
          { file_id: 'hires_photo_1', width: 1200, height: 800 }
        ]
      })
    );
    assert.match(mockTg.lastSent().text, /Photo attached \(1\)/);
    assert.equal(configStore.getWorkspaceState('payments').pendingPhotos.length, 1);

    nextAgentBehavior = async () => {
      await fsp.writeFile(
        path.join(coreRepo.cloneDir, 'src', 'app.js'),
        'export const version = 2;\n',
        'utf8'
      );
      await fsp.writeFile(
        path.join(coreRepo.cloneDir, 'src', 'photo-widget.js'),
        'export const widget = true;\n',
        'utf8'
      );
      return {
        conversationId: 'conv-photo-turn',
        response: 'Updated app.js and added photo-widget.js based on your screenshot.'
      };
    };

    mockTg.clearSent();
    await controller.handleUpdate(makeUserMsg('Implement the widget from this photo'));
    await controller.waitForBackgroundTasks();

    assert.equal(lastAgentCallArgs.imagePaths.length, 1);
    const stat = await fsp.stat(lastAgentCallArgs.imagePaths[0]);
    assert.ok(stat.size > 0);

    const commitAsk = mockTg.lastSent();
    assert.match(commitAsk.text, /Changes made in Payments Platform/);
    assert.match(commitAsk.text, /src\/app\.js/);
    assert.match(commitAsk.text, /src\/photo-widget\.js/);
    assert.doesNotMatch(commitAsk.text, /manual-wip\.txt/);

    const commitCbs = commitAsk.reply_markup.inline_keyboard.flat().map((b) => b.callback_data);
    assert.ok(commitCbs.includes('cmt:yes:payments'));
    assert.ok(commitCbs.includes('cmt:br:payments'));
    assert.ok(commitCbs.includes('cmt:fix:payments'));
    assert.ok(commitCbs.includes('cmt:no:payments'));

    mockTg.clearSent();
    await controller.handleUpdate(makeCallback('cmt:no:payments', commitAsk.message_id));
    assert.doesNotMatch(mockTg.lastSent().text, /Last action:/);
    assert.match(
      mockTg.lastSent().text,
      /Discarded uncommitted changes in <b>Payments Platform<\/b>.*Ready for your next message!/s
    );
    assert.equal(configStore.getWorkspaceState('payments').phase, 'IDLE');

    assert.equal(
      await fsp.readFile(path.join(coreRepo.cloneDir, 'src', 'app.js'), 'utf8'),
      'export const version = 1;\n'
    );
    await assert.rejects(() => fsp.access(path.join(coreRepo.cloneDir, 'src', 'photo-widget.js')));
    assert.equal(await fsp.readFile(manualWipFile, 'utf8'), 'keep my manual notes\n');
    await fsp.rm(manualWipFile, { force: true });
  });

  it('supports Add Fix in commit prompt to provide follow-up fix in the same process', async () => {
    // 1) Initial agent turn: creates src/first-fix.js
    nextAgentBehavior = async () => {
      await fsp.writeFile(
        path.join(coreRepo.cloneDir, 'src', 'first-fix.js'),
        'export const step1 = true;\n',
        'utf8'
      );
      return {
        conversationId: 'conv-add-fix-proc',
        response: 'Created first-fix.js'
      };
    };

    mockTg.clearSent();
    await controller.handleUpdate(makeUserMsg('Create step 1'));
    await controller.waitForBackgroundTasks();

    assert.equal(configStore.getWorkspaceState('payments').phase, 'AWAITING_COMMIT_CHOICE');
    const commitAsk = mockTg.lastSent();
    assert.match(commitAsk.text, /Commit &amp; push these changes\?/);
    assert.match(commitAsk.text, /src\/first-fix\.js/);

    const commitButtons = commitAsk.reply_markup.inline_keyboard.flat();
    const fixBtn = commitButtons.find((b) => b.callback_data === 'cmt:fix:payments');
    assert.ok(fixBtn, '➕ Add Fix button must be present in commit prompt');
    assert.match(fixBtn.text, /Add Fix/);

    // 2) User taps ➕ Add Fix -> must ask for fix prompt
    mockTg.clearSent();
    await controller.handleUpdate(makeCallback('cmt:fix:payments', commitAsk.message_id));
    assert.equal(configStore.getWorkspaceState('payments').phase, 'AWAITING_FIX_PROMPT');
    assert.match(mockTg.lastSent().text, /Add Fix in/);
    assert.match(mockTg.lastSent().text, /Reply with what to fix or modify in the current process/);

    // 2b) Test back button works: ↩️ Back to Commit Options returns to AWAITING_COMMIT_CHOICE
    mockTg.clearSent();
    await controller.handleUpdate(makeCallback('cmt:back:payments'));
    assert.equal(configStore.getWorkspaceState('payments').phase, 'AWAITING_COMMIT_CHOICE');
    assert.match(mockTg.lastSent().text, /Commit &amp; push these changes\?/);

    // Click ➕ Add Fix again to proceed
    mockTg.clearSent();
    await controller.handleUpdate(makeCallback('cmt:fix:payments'));
    assert.equal(configStore.getWorkspaceState('payments').phase, 'AWAITING_FIX_PROMPT');

    // 3) User replies with fix message -> agent runs in same process and creates src/second-fix.js
    let fixCalledOpts = null;
    nextAgentBehavior = async (opts) => {
      fixCalledOpts = opts;
      await fsp.writeFile(
        path.join(coreRepo.cloneDir, 'src', 'second-fix.js'),
        'export const step2 = true;\n',
        'utf8'
      );
      return {
        conversationId: 'conv-add-fix-proc',
        response: 'Added second-fix.js in same process'
      };
    };

    mockTg.clearSent();
    await controller.handleUpdate(makeUserMsg('Also create step 2'));
    await controller.waitForBackgroundTasks();

    // Verify same conversation ID and prompt passed
    assert.equal(fixCalledOpts.conversationId, 'conv-add-fix-proc');
    assert.equal(fixCalledOpts.prompt, 'Also create step 2');

    // 4) Verify commit prompt reappears showing BOTH uncommitted changes
    assert.equal(configStore.getWorkspaceState('payments').phase, 'AWAITING_COMMIT_CHOICE');
    const updatedCommitAsk = mockTg.lastSent();
    assert.match(updatedCommitAsk.text, /Commit &amp; push these changes\?/);
    assert.match(updatedCommitAsk.text, /src\/first-fix\.js/);
    assert.match(updatedCommitAsk.text, /src\/second-fix\.js/);

    // 5) Commit both changes together
    mockTg.clearSent();
    await controller.handleUpdate(makeCallback('cmt:yes:payments'));
    assert.equal(configStore.getWorkspaceState('payments').phase, 'AWAITING_JENKINS_CHOICE');

    // Verify both files committed in single git commit
    const { stdout: filesOut } = await runGit(coreRepo.cloneDir, ['show', '--name-only', '--pretty=']);
    assert.match(filesOut, /src\/first-fix\.js/);
    assert.match(filesOut, /src\/second-fix\.js/);

    // Cleanup: skip Jenkins and confirm
    await controller.handleUpdate(makeCallback('jnk:no:payments'));
    await controller.handleUpdate(makeCallback('ok:yes:payments'));
    assert.equal(configStore.getWorkspaceState('payments').phase, 'IDLE');
  });

  it('commits & pushes to a Custom Branch, triggers Jenkins with VERSION=<branch>, and confirms Is it okay -> Yes', async () => {
    nextAgentBehavior = async (opts) => {
      opts.onStepEvent?.({ stepType: 'tool', toolName: 'read_file', state: 'ACTIVE' });
      await new Promise((r) => setTimeout(r, 25));
      await fsp.writeFile(
        path.join(coreRepo.cloneDir, 'src', 'branch-feature.js'),
        'export const feat = "custom";\n',
        'utf8'
      );
      return {
        conversationId: 'conv-photo-turn',
        response: 'Created branch-feature.js.'
      };
    };

    mockTg.clearSent();
    mockTg.editedMessages.length = 0;
    await controller.handleUpdate(makeUserMsg('Add custom branch feature'));
    await controller.waitForBackgroundTasks();

    assert.ok(
      mockTg.sentMessages.some((m) =>
        /🤖 Antigravity working…\n<b>Payments Platform<\/b>\n\n🧠/.test(m.text)
      )
    );
    assert.ok(
      mockTg.editedMessages.some((e) =>
        /🤖 Antigravity working…\n<b>Payments Platform<\/b>\n\n⚙️ <code>tool: read_file \(ACTIVE\)<\/code>/.test(
          e.text
        )
      )
    );

    const commitPrompt = mockTg.lastSent();
    assert.equal(configStore.getWorkspaceState('payments').phase, 'AWAITING_COMMIT_CHOICE');

    mockTg.clearSent();
    await controller.handleUpdate(makeCallback('cmt:br:payments', commitPrompt.message_id));
    assert.equal(configStore.getWorkspaceState('payments').phase, 'AWAITING_CUSTOM_BRANCH');
    assert.match(mockTg.lastSent().text, /Reply with the branch name/);

    mockTg.clearSent();
    await controller.handleUpdate(makeUserMsg('invalid..branch'));
    assert.match(mockTg.lastSent().text, /Invalid git branch name/);

    mockTg.clearSent();
    await controller.handleUpdate(makeUserMsg('feat/tg-branch'));
    assert.equal(configStore.getWorkspaceState('payments').phase, 'AWAITING_JENKINS_CHOICE');

    assert.ok(!mockTg.sentMessages.some((m) => /Last action:/.test(m.text)));
    assert.ok(
      mockTg.sentMessages.some((m) =>
        /Committed &amp; pushed to custom branch "feat\/tg-branch"/.test(m.text)
      )
    );
    assert.match(mockTg.lastSent().text, /Run Jenkins deploy\?/);
    assert.match(mockTg.lastSent().text, /VERSION=<code>feat\/tg-branch<\/code>/);

    const { stdout: remoteBranches } = await runGit(coreRepo.bareDir, ['branch', '--list']);
    assert.match(remoteBranches, /feat\/tg-branch/);

    mockJenkins.setNextOutcome('SUCCESS', 'Built feat/tg-branch\nFinished: SUCCESS\n');
    mockTg.clearSent();
    await controller.handleUpdate(makeCallback('jnk:yes:payments'));
    await controller.waitForBackgroundTasks();

    const lastTriggered = mockJenkins.triggeredBuilds[mockJenkins.triggeredBuilds.length - 1];
    assert.equal(
      lastTriggered.jobName,
      'Prod/payments/payments.example.com-GATE'
    );
    assert.equal(lastTriggered.version, 'feat/tg-branch');

    assert.equal(configStore.getWorkspaceState('payments').phase, 'AWAITING_OK_OR_REVERT');
    assert.match(mockTg.lastSent().text, /Jenkins Deploy Succeeded!/);
    assert.match(mockTg.lastSent().text, /Is it okay\?/);

    mockTg.clearSent();
    await controller.handleUpdate(makeCallback('ok:yes:payments'));
    assert.equal(configStore.getWorkspaceState('payments').phase, 'IDLE');
    assert.doesNotMatch(mockTg.lastSent().text, /Last action:/);
    assert.match(
      mockTg.lastSent().text,
      /^✅ Confirmed changes in <b>Payments Platform<\/b>\.\n\nReady for your next message!/
    );

    await runGit(coreRepo.cloneDir, ['checkout', 'master']);
  });

  it('outputs Jenkins error log on FAILURE, reverts bad commit, and runs rollback Jenkins deploy', async () => {
    nextAgentBehavior = async () => {
      await fsp.writeFile(
        path.join(coreRepo.cloneDir, 'src', 'app.js'),
        'export const broken = ;\n',
        'utf8'
      );
      return {
        conversationId: 'conv-master-bad',
        response: 'Modified src/app.js.'
      };
    };

    mockTg.clearSent();
    await controller.handleUpdate(makeUserMsg('Introduce risky edit'));
    await controller.waitForBackgroundTasks();

    mockTg.clearSent();
    await controller.handleUpdate(makeCallback('cmt:yes:payments'));
    assert.ok(!mockTg.sentMessages.some((m) => /Last action:/.test(m.text)));
    assert.ok(mockTg.sentMessages.some((m) => /Committed &amp; pushed/.test(m.text)));
    assert.equal(configStore.getWorkspaceState('payments').phase, 'AWAITING_JENKINS_CHOICE');

    mockJenkins.setNextOutcome(
      'FAILURE',
      'Compiling bundle...\nERROR in src/app.js:1:23 Unexpected token ;\nBuild step failed!\nFinished: FAILURE'
    );
    mockTg.clearSent();
    await controller.handleUpdate(makeCallback('jnk:yes:payments'));
    await controller.waitForBackgroundTasks();

    const failMsg = mockTg.lastSent();
    assert.match(failMsg.text, /Jenkins Build Failed/);
    assert.match(failMsg.text, /ERROR in src\/app\.js:1:23 Unexpected token ;/);
    assert.equal(configStore.getWorkspaceState('payments').phase, 'AWAITING_OK_OR_REVERT');

    const failButtons = (failMsg.reply_markup?.inline_keyboard || [])
      .flat()
      .map((b) => ({ text: b.text, data: b.callback_data }));
    assert.deepEqual(failButtons, [
      { text: '↩️ Revert', data: 'ok:rev:payments' },
      { text: '🔧 Fix Error', data: 'fix:err:payments' }
    ]);

    mockJenkins.setNextOutcome('SUCCESS', 'Redeployed reverted master cleanly!\nFinished: SUCCESS');
    mockTg.clearSent();
    await controller.handleUpdate(makeCallback('ok:rev:payments', failMsg.message_id));
    await controller.waitForBackgroundTasks();

    assert.ok(!mockTg.sentMessages.some((m) => /Last action:/.test(m.text)));
    assert.ok(
      mockTg.sentMessages.some((m) => /Reverted last commit\(s\) as bad/.test(m.text))
    );

    const { stdout: lastSubject } = await runGit(coreRepo.cloneDir, ['log', '-1', '--pretty=%s']);
    assert.match(lastSubject.trim(), /^Revert ".*" \(bad commit\)$/);
    assert.equal(
      await fsp.readFile(path.join(coreRepo.cloneDir, 'src', 'app.js'), 'utf8'),
      'export const version = 1;\n'
    );

    const { stdout: localHead } = await runGit(coreRepo.cloneDir, ['rev-parse', 'HEAD']);
    const { stdout: remoteHead } = await runGit(coreRepo.bareDir, ['rev-parse', 'master']);
    assert.equal(localHead.trim(), remoteHead.trim());

    assert.equal(configStore.getWorkspaceState('payments').phase, 'IDLE');
    assert.match(mockTg.lastSent().text, /Rollback Jenkins Deploy Succeeded!/);
  });

  it('handles Fix Error flow on Jenkins failure with AI auto-commit and prompt to deploy', async () => {
    // 1) Agent makes a breaking change
    nextAgentBehavior = async () => {
      await fsp.writeFile(
        path.join(coreRepo.cloneDir, 'src', 'app.js'),
        'export const brokenSyntax = ;\n',
        'utf8'
      );
      return {
        conversationId: 'conv-fix-error-test',
        response: 'Introduced syntax error.'
      };
    };

    mockTg.clearSent();
    await controller.handleUpdate(makeUserMsg('Introduce syntax error in payments'));
    await controller.waitForBackgroundTasks();

    mockTg.clearSent();
    await controller.handleUpdate(makeCallback('cmt:yes:payments'));
    assert.equal(configStore.getWorkspaceState('payments').phase, 'AWAITING_JENKINS_CHOICE');

    // 2) Jenkins fails with compilation error
    const buildErrorLog = 'Compiling...\nSyntaxError: Unexpected token ;\nat src/app.js:1:30\nFinished: FAILURE';
    mockJenkins.setNextOutcome('FAILURE', buildErrorLog);
    mockTg.clearSent();
    await controller.handleUpdate(makeCallback('jnk:yes:payments'));
    await controller.waitForBackgroundTasks();

    const failMsg = mockTg.lastSent();
    assert.match(failMsg.text, /Jenkins Build Failed/);
    assert.match(failMsg.text, /SyntaxError: Unexpected token ;/);
    assert.equal(configStore.getWorkspaceState('payments').phase, 'AWAITING_OK_OR_REVERT');

    const failButtons = (failMsg.reply_markup?.inline_keyboard || [])
      .flat()
      .map((b) => ({ text: b.text, data: b.callback_data }));
    assert.deepEqual(failButtons, [
      { text: '↩️ Revert', data: 'ok:rev:payments' },
      { text: '🔧 Fix Error', data: 'fix:err:payments' }
    ]);

    // 3) User clicks "Fix Error" -> Agent receives error log and applies fix
    let receivedPrompt = '';
    nextAgentBehavior = async (args) => {
      receivedPrompt = args.prompt || '';
      await fsp.writeFile(
        path.join(coreRepo.cloneDir, 'src', 'app.js'),
        'export const fixedSyntax = true;\n',
        'utf8'
      );
      return {
        conversationId: 'conv-fix-error-test',
        response: 'Fixed syntax error in src/app.js.'
      };
    };

    mockTg.clearSent();
    await controller.handleUpdate(makeCallback('fix:err:payments', failMsg.message_id));
    await controller.waitForBackgroundTasks();

    // Verify agent received the failure log
    assert.match(receivedPrompt, /SyntaxError: Unexpected token ;/);

    // Verify AI auto-committed and pushed the fix
    assert.ok(mockTg.sentMessages.some((m) => /Auto-committed &amp; pushed fix for Jenkins build failure/.test(m.text)));

    // Verify phase transitioned to AWAITING_JENKINS_CHOICE with "Run Jenkins deploy?" prompt
    assert.equal(configStore.getWorkspaceState('payments').phase, 'AWAITING_JENKINS_CHOICE');
    const deployPrompt = mockTg.lastSent();
    assert.match(deployPrompt.text, /Run Jenkins deploy\?/);
    const deployButtons = (deployPrompt.reply_markup?.inline_keyboard || [])
      .flat()
      .map((b) => b.callback_data);
    assert.ok(deployButtons.includes('jnk:yes:payments'));
    assert.ok(deployButtons.includes('jnk:no:payments'));

    // 4) User clicks Run Jenkins -> Succeeds
    mockJenkins.setNextOutcome('SUCCESS', 'Build succeeded cleanly!\nFinished: SUCCESS');
    mockTg.clearSent();
    await controller.handleUpdate(makeCallback('jnk:yes:payments', deployPrompt.message_id));
    await controller.waitForBackgroundTasks();

    assert.equal(configStore.getWorkspaceState('payments').phase, 'AWAITING_OK_OR_REVERT');
    assert.match(mockTg.lastSent().text, /Is it okay\?/);

    // 5) Confirm changes -> phase becomes IDLE
    mockTg.clearSent();
    await controller.handleUpdate(makeCallback('ok:yes:payments'));
    assert.equal(configStore.getWorkspaceState('payments').phase, 'IDLE');
    assert.match(mockTg.lastSent().text, /Confirmed changes/);
  });

  it('locks down Telegram settings to AI models only, runs add-ide & update-jenkins in console, and preserves pending state across IDE switches', async () => {
    const extraRepo = await createBareAndClonedRepo(tmpRoot, 'extra_service', 'extra_service');

    // 1) Verify Telegram Settings exposes ONLY AI model selection per IDE (no Register IDE, no Jenkins URL/auth/test)
    mockTg.clearSent();
    await controller.handleUpdate(makeUserMsg(REPLY_BTN_SETTINGS));
    const settingsMsg = mockTg.lastSent();
    assert.match(settingsMsg.text, /AI Model Settings/);
    assert.doesNotMatch(settingsMsg.text, /Jenkins/i);
    assert.doesNotMatch(settingsMsg.text, /Register Available IDE/);

    const settingsCallbacks = (settingsMsg.reply_markup?.inline_keyboard || [])
      .flat()
      .map((b) => b.callback_data);
    assert.ok(!settingsCallbacks.includes('ide:reg_menu'));
    assert.ok(!settingsCallbacks.includes('cfg:test_jnk'));
    assert.ok(!settingsCallbacks.includes('cfg:set_jnk'));
    assert.ok(settingsCallbacks.includes('ide:cfg:payments'));
    assert.ok(settingsCallbacks.includes('ide:cfg:portal'));

    // Also verify per-IDE model screen has NO unregister button and NO Jenkins paths
    mockTg.clearSent();
    await controller.handleUpdate(makeCallback('ide:cfg:payments'));
    const ideModelMsg = mockTg.lastSent();
    const ideModelCallbacks = (ideModelMsg.reply_markup?.inline_keyboard || [])
      .flat()
      .map((b) => b.callback_data);
    assert.ok(!ideModelCallbacks.some((cb) => cb.startsWith('ide:del:')));
    assert.doesNotMatch(ideModelMsg.text, /Jenkins/i);

    // 2) Verify /register and /setjenkins cannot mutate config from Telegram
    const wsCountBefore = configStore.config.workspaces.length;
    const prevJenkinsUser = configStore.config.jenkins.username;
    mockTg.clearSent();
    await controller.handleUpdate(makeUserMsg(`/register extra ${extraRepo.workRoot}`));
    assert.equal(configStore.config.workspaces.length, wsCountBefore);
    assert.match(mockTg.lastSent().text, /local-only/);
    assert.match(mockTg.lastSent().text, /MAC → Settings/);

    mockTg.clearSent();
    await controller.handleUpdate(makeUserMsg('/setjenkins https://evil.example.com hacker secret'));
    assert.equal(configStore.config.jenkins.username, prevJenkinsUser);
    assert.match(mockTg.lastSent().text, /local-only/);

    // 3) Update & test Jenkins strictly via console command (`update-jenkins` + `test-jenkins`)
    const jnkLogs = [];
    const jnkAnswers = [
      mockJenkins.baseUrl, // 1. Jenkins Base URL
      'console-ci-user',   // 2. Jenkins Username
      'console-ci-token',  // 3. Jenkins API Token
      'y'                  // Test Jenkins connection now?
    ];
    let jnkIdx = 0;
    await executeConsoleCommand('update-jenkins', {
      configStore,
      dataDir: path.join(tmpRoot, 'data'),
      ask: async () => jnkAnswers[jnkIdx++] ?? '',
      log: (m) => jnkLogs.push(m),
      warn: (m) => jnkLogs.push(m)
    });
    assert.equal(configStore.config.jenkins.username, 'console-ci-user');
    assert.ok(jnkLogs.some((line) => /Jenkins Connected! Found 3 job\(s\)/.test(line)));

    const directTestRes = await runTestJenkinsConsole({
      store: configStore,
      log: () => {},
      warn: () => {}
    });
    assert.equal(directTestRes.ok, true);
    assert.equal(directTestRes.jobs.length, 3);

    // 4) Register `extra` IDE strictly via console command (`add-ide`), then use & switch in Telegram
    const addIdeAnswers = [
      extraRepo.workRoot, // Paste workspace directory path
      'extra',            // Workspace short name
      'Extra Service',    // Workspace display label
      '1',                // 1) gemini-3.8-flash
      'high',             // Model level: high
      '-',                // Live URL
      '-',                // Extra --add-dir
      'single',           // Environment mode: single
      'y',                // Include repo?
      '',                 // Repo path
      '',                 // Git branch
      'y',                // Enable Jenkins deploy?
      'extra_service',    // Jenkins job name
      '-',                // Additional workspace-level Jenkins jobs
      ''                  // Press Enter on empty line to finish
    ];
    let addIdx = 0;
    await executeConsoleCommand('add-ide', {
      configStore,
      dataDir: path.join(tmpRoot, 'data'),
      ask: async () => addIdeAnswers[addIdx++] ?? '',
      log: () => {},
      warn: () => {}
    });

    assert.ok(configStore.config.workspaces.some((w) => w.id === 'extra'));

    await controller.handleUpdate(makeCallback('ide:sel:extra'));
    assert.equal(configStore.getUserSession(USER_ID).selectedWorkspaceId, 'extra');

    nextAgentBehavior = async () => {
      await fsp.writeFile(
        path.join(extraRepo.cloneDir, 'src', 'app.js'),
        'export const extraUpdated = true;\n',
        'utf8'
      );
      return { conversationId: 'conv-extra-1', response: 'Updated extra_service.' };
    };
    await controller.handleUpdate(makeCallback('chat:new:extra'));
    mockTg.clearSent();
    await controller.handleUpdate(makeUserMsg('Update extra service'));
    await controller.waitForBackgroundTasks();
    assert.equal(configStore.getWorkspaceState('extra').phase, 'AWAITING_COMMIT_CHOICE');

    mockTg.clearSent();
    await controller.handleUpdate(makeUserMsg(REPLY_BTN_SWITCH_IDE));
    assert.match(mockTg.lastSent().text, /Select a Workspace/);
    // 3 workspaces (odd) -> Row 1 has 2 workspaces, Row 2 pairs the 3rd workspace with ⚙️ Settings on half width!
    const oddWsRows = mockTg.lastSent().reply_markup.inline_keyboard;
    assert.equal(oddWsRows.length, 2);
    assert.equal(oddWsRows[0].length, 2);
    assert.equal(oddWsRows[1].length, 2);
    assert.equal(oddWsRows[1][0].callback_data, 'ide:sel:extra');
    assert.deepEqual(oddWsRows[1][1], { text: '⚙️ Settings', callback_data: 'cfg:menu' });
    const selectorCallbacks = oddWsRows.flat().map((b) => b.callback_data);
    assert.ok(!selectorCallbacks.includes('ide:reg_menu'));

    await controller.handleUpdate(makeCallback('ide:sel:portal'));
    assert.equal(configStore.getUserSession(USER_ID).selectedWorkspaceId, 'portal');
    assert.equal(configStore.getWorkspaceState('portal').phase, 'SELECT_CHAT');

    mockTg.clearSent();
    await controller.handleUpdate(makeCallback('ide:sel:extra'));
    assert.equal(configStore.getUserSession(USER_ID).selectedWorkspaceId, 'extra');
    assert.ok(mockTg.sentMessages.some((m) => /Switched to Workspace: Extra Service/.test(m.text)));
    assert.match(mockTg.lastSent().text, /Commit &amp; push these changes\?/);

    await controller.handleUpdate(makeCallback('cmt:no:extra'));
    assert.equal(configStore.getWorkspaceState('extra').phase, 'IDLE');
  });

  it('configures & changes AI model (including Claude Opus 5.5) and 3 levels (low/medium/high) per IDE without custom model option', async () => {
    await controller.handleUpdate(makeCallback('ide:sel:payments'));
    await controller.handleUpdate(makeCallback('chat:new:payments'));

    mockTg.clearSent();
    await controller.handleUpdate(makeUserMsg('/model'));
    const cfgMsg = mockTg.lastSent();
    assert.match(cfgMsg.text, /AI Model:/);
    assert.match(cfgMsg.text, /Model Level:/);

    const flatModelBtns = cfgMsg.reply_markup.inline_keyboard.flat();
    const cbs = flatModelBtns.map((b) => b.callback_data);
    // Must include Gemini 3.8 Flash, Gemini 4 Argon, Gemini 4 Carbon, Claude Opus 5.5, DeepSeek, OpenAI, Qwen
    assert.ok(cbs.includes('mdl:f:payments:g38'));
    assert.ok(cbs.includes('mdl:f:payments:g4'));
    assert.ok(cbs.includes('mdl:f:payments:g4c'));
    assert.ok(cbs.includes('mdl:f:payments:co55'));
    assert.ok(cbs.includes('mdl:f:payments:c37s'));
    assert.ok(cbs.includes('mdl:f:payments:dsk'));
    assert.ok(cbs.includes('mdl:f:payments:dsr'));
    assert.ok(cbs.includes('mdl:f:payments:g4o'));
    assert.ok(cbs.includes('mdl:f:payments:q25c'));
    // Must have ONLY 3 levels (low, medium, high) — NO xhigh or max, and NO Custom Model button!
    assert.ok(cbs.includes('mdl:l:payments:low'));
    assert.ok(cbs.includes('mdl:l:payments:medium'));
    assert.ok(cbs.includes('mdl:l:payments:high'));
    assert.ok(!cbs.some((c) => c.endsWith(':xhigh') || c.endsWith(':max')));
    assert.ok(!cbs.some((c) => c.startsWith('mdl:custom:')));
    assert.ok(cbs.includes('chat:hist:payments'));
    assert.ok(!flatModelBtns.some((b) => /All IDEs/i.test(b.text)));

    const rows = cfgMsg.reply_markup.inline_keyboard;
    const actionRow = rows[rows.length - 2];
    assert.equal(actionRow.length, 2);
    assert.match(actionRow[0].text, /Last Messages/);
    assert.equal(actionRow[0].callback_data, 'chat:hist:payments');
    assert.match(actionRow[1].text, /Open "Payments Platform"/);
    const backRow = rows[rows.length - 1];
    assert.deepEqual(backRow, [{ text: '< BACK', callback_data: 'cfg:menu' }]);

    // Configure `payments` IDE -> Gemini 3.8 Flash (high)
    await controller.handleUpdate(makeCallback('mdl:f:payments:g38', cfgMsg.message_id));
    await controller.handleUpdate(makeCallback('mdl:l:payments:high', cfgMsg.message_id));

    const paymentsWs = configStore.config.workspaces.find((w) => w.id === 'payments');

    // Switch `payments` to Gemini 4 Carbon with low, medium, and high levels
    await controller.handleUpdate(makeCallback('mdl:f:payments:g4c', cfgMsg.message_id));
    await controller.handleUpdate(makeCallback('mdl:l:payments:low', cfgMsg.message_id));
    assert.equal(paymentsWs.model, 'gemini-4-carbon-low');
    assert.equal(paymentsWs.modelLevel, 'low');

    await controller.handleUpdate(makeCallback('mdl:l:payments:medium', cfgMsg.message_id));
    assert.equal(paymentsWs.model, 'gemini-4-carbon-medium');
    assert.equal(paymentsWs.modelLevel, 'medium');

    await controller.handleUpdate(makeCallback('mdl:l:payments:high', cfgMsg.message_id));
    assert.equal(paymentsWs.model, 'gemini-4-carbon-high');
    assert.equal(paymentsWs.modelLevel, 'high');

    // Switch back to Gemini 3.8 Flash (high) for following assertions
    await controller.handleUpdate(makeCallback('mdl:f:payments:g38', cfgMsg.message_id));
    await controller.handleUpdate(makeCallback('mdl:l:payments:high', cfgMsg.message_id));

    // Configure `portal` IDE independently -> Claude Opus 5.5 (medium) via Settings -> IDE card
    await controller.handleUpdate(makeCallback('ide:cfg:portal'));
    const portalCfgMsg = mockTg.lastSent();
    await controller.handleUpdate(makeCallback('mdl:f:portal:co55', portalCfgMsg.message_id));
    await controller.handleUpdate(makeCallback('mdl:l:portal:medium', portalCfgMsg.message_id));

    const portalWs = configStore.config.workspaces.find((w) => w.id === 'portal');
    assert.equal(paymentsWs.model, 'gemini-3.8-flash-high');
    assert.equal(paymentsWs.modelLevel, 'high');
    assert.equal(portalWs.model, 'claude-opus-5-5-medium');
    assert.equal(portalWs.modelLevel, 'medium');

    nextAgentBehavior = async () => ({
      conversationId: 'conv-model-check',
      response: 'Ran with Gemini 3.8 high.'
    });
    await controller.handleUpdate(makeUserMsg('Quick check'));
    await controller.waitForBackgroundTasks();
    assert.equal(lastAgentCallArgs.model, 'gemini-3.8-flash-high');
    assert.equal(lastAgentCallArgs.modelLevel, 'high');
    assert.equal(lastAgentCallArgs.agentEngine, 'agy');

    // Simulate external config.json edit on disk (e.g. from `npm run setup`) and verify hot-reload
    await new Promise((r) => setTimeout(r, 15));
    const diskCfg = JSON.parse(await fsp.readFile(configStore.configFile, 'utf8'));
    diskCfg.workspaces.find((w) => w.id === 'payments').model = 'claude-opus-5-5-low';
    diskCfg.workspaces.find((w) => w.id === 'payments').modelLevel = 'low';
    diskCfg.workspaces.find((w) => w.id === 'payments').engine = 'aider';
    await fsp.writeFile(configStore.configFile, JSON.stringify(diskCfg, null, 2), 'utf8');

    await controller.handleUpdate(makeUserMsg('Second check after hot reload'));
    await controller.waitForBackgroundTasks();
    assert.equal(lastAgentCallArgs.model, 'claude-opus-5-5-low');
    assert.equal(lastAgentCallArgs.modelLevel, 'low');
    assert.equal(lastAgentCallArgs.agentEngine, 'aider');
  });

  it('coalesces multi-photo albums + split big messages into a single agent run and caps uploads at 5 files', async () => {
    await controller.handleUpdate(makeCallback('ide:sel:payments'));
    await controller.handleUpdate(makeCallback('chat:new:payments'));

    let agentRunsCount = 0;
    nextAgentBehavior = async () => {
      agentRunsCount += 1;
      return {
        conversationId: 'conv-album-coalesced',
        response: 'Processed album and big prompt in a single run.'
      };
    };

    mockTg.clearSent();

    // Send a 7-file Telegram album (media_group_id) + caption + overflow follow-up text
    for (let i = 1; i <= 7; i++) {
      await controller.handleUpdate(
        makeUserMsg(undefined, {
          media_group_id: 'album-7-photos',
          ...(i === 1 ? { caption: '1. Fix menu wrap\n2. Enable top categories' } : {}),
          photo: [{ file_id: `album_pic_${i}`, width: 1200, height: 800 }]
        })
      );
    }
    await controller.handleUpdate(makeUserMsg('3. Fix inline edit buttons'));

    await controller.waitForBackgroundTasks();

    assert.equal(agentRunsCount, 1);
    assert.equal(lastAgentCallArgs.imagePaths.length, 5);
    assert.match(lastAgentCallArgs.prompt, /1\. Fix menu wrap/);
    assert.match(lastAgentCallArgs.prompt, /3\. Fix inline edit buttons/);
    assert.ok(
      !mockTg.sentMessages.some((m) => /currently in step <code>RUNNING_AGENT<\/code>/.test(m.text))
    );
    assert.ok(mockTg.sentMessages.some((m) => /Attached 5\/5 file\(s\)/.test(m.text)));
    assert.ok(mockTg.sentMessages.some((m) => /Max 5 files allowed at once/.test(m.text)));

    // Also test a split >3800-char pure text message coalescing into 1 single agent run
    agentRunsCount = 0;
    mockTg.clearSent();
    const bigPart1 = `PART_ONE_${'A'.repeat(3900)}`;
    const bigPart2 = 'PART_TWO_FINAL_REQUIREMENT';
    await controller.handleUpdate(makeUserMsg(bigPart1));
    await controller.handleUpdate(makeUserMsg(bigPart2));
    await controller.waitForBackgroundTasks();

    assert.equal(agentRunsCount, 1);
    assert.match(lastAgentCallArgs.prompt, /^PART_ONE_A+/);
    assert.match(lastAgentCallArgs.prompt, /PART_TWO_FINAL_REQUIREMENT$/);
    assert.ok(
      !mockTg.sentMessages.some((m) => /currently in step <code>RUNNING_AGENT<\/code>/.test(m.text))
    );
  });

  it('converts GFM agent responses into valid Telegram HTML and strips local file:// links', async () => {
    const sampleMarkdown = [
      '7. **Icon Edit Actions Anchored Directly Around the Icon**',
      '   - In [HeroTrustStrip.jsx](file:///Users/dev/projects/portal.ch/marketing/src/components/HeroTrustStrip.jsx) and [SecurityComplianceSection.jsx](file:///Users/dev/projects/portal.ch/marketing/src/components/SecurityComplianceSection.jsx#L12-L24), moved the icon edit trigger (`.icon-edit-action-btn`) directly inside `.hero-trust-icon-wrap`.',
      '   - Updated [`AdminRoute`](file:///Users/dev/projects/portal.ch/app/(dashboard)/page.tsx#L40) and snake_case_var `max_files_per_turn`.',
      '',
      '---',
      '',
      '### Verification',
      '- **Automated Tests**: Vitest suite passed (`✓ src/test/AdminInlineCMS.test.jsx (11 tests)`).',
      '- **Responsive & Layout Design**: Used `flex-shrink: 0` on `<button>` inside <section> elements; see [Web Docs](https://developer.mozilla.org/en-US/docs/Web/CSS/:has).',
      '',
      '> [!NOTE]',
      '> Scoped `:has()` selectors avoid parent hover transforms.',
      '',
      '```jsx',
      'const btn = <button className="a & b">{label}</button>;',
      '```'
    ].join('\n');

    const html = markdownToTelegramHtml(sampleMarkdown);

    // Bold, headings, bullets, horizontal rules, inline code, blockquotes, external links, code blocks
    assert.match(html, /7\. <b>Icon Edit Actions Anchored Directly Around the Icon<\/b>/);
    assert.match(html, /• In <code>HeroTrustStrip\.jsx<\/code> and <code>SecurityComplianceSection\.jsx#L12-L24<\/code>/);
    assert.match(html, /<code>\.icon-edit-action-btn<\/code>/);
    assert.match(html, /<code>AdminRoute<\/code>/);
    assert.match(html, /snake_case_var <code>max_files_per_turn<\/code>/);
    assert.match(html, /──────────────/);
    assert.match(html, /<b>Verification<\/b>/);
    assert.match(
      html,
      /• <b>Responsive &amp; Layout Design<\/b>: Used <code>flex-shrink: 0<\/code> on <code>&lt;button&gt;<\/code> inside &lt;section&gt; elements/
    );
    assert.match(
      html,
      /<a href="https:\/\/developer\.mozilla\.org\/en-US\/docs\/Web\/CSS\/:has">Web Docs<\/a>/
    );
    assert.match(html, /<blockquote>ℹ️ <b>Note<\/b>\nScoped <code>:has\(\)<\/code> selectors/);
    assert.match(
      html,
      /<pre><code class="language-jsx">const btn = &lt;button className="a &amp; b"&gt;\{label\}&lt;\/button&gt;;<\/code><\/pre>/
    );

    // Must NOT leak raw markdown markers or local file:/// paths
    assert.doesNotMatch(html, /file:\/\/\//);
    assert.doesNotMatch(html, /portal\.ch\/marketing/);
    assert.doesNotMatch(html, /### Verification/);
    assert.doesNotMatch(html, /\*\*Automated Tests\*\*/);

    // Splitting multi-chunk HTML across <pre><code>...</code></pre> keeps every chunk balanced & <= maxLen
    const longCodeLines = Array.from({ length: 30 }, (_, idx) => `const item_${idx} = a < b && c > ${idx};`).join('\n');
    const longHtml = markdownToTelegramHtml(`### Code Output\n\n\`\`\`js\n${longCodeLines}\n\`\`\`\n\n**Done!**`);
    const splitChunks = splitTelegramText(longHtml, 320);
    assert.ok(splitChunks.length >= 3);

    for (const chunk of splitChunks) {
      assert.ok(chunk.length <= 320, `chunk exceeded maxLen: ${chunk.length}`);
      // Verify balanced HTML tags in each chunk independently
      const stack = [];
      for (const m of chunk.matchAll(/<\/?([a-zA-Z0-9-]+)(?:\s[^>]*)?>/g)) {
        const name = m[1].toLowerCase();
        if (m[0].startsWith('</')) {
          assert.equal(stack.pop(), name, `mismatched closing </${name}> in chunk: ${chunk}`);
        } else {
          stack.push(name);
        }
      }
      assert.deepEqual(stack, [], `unclosed HTML tags in chunk: ${chunk}`);
    }

    // E2E check through BotController: agent response renders formatted HTML in Telegram
    await controller.handleUpdate(makeCallback('ide:sel:payments'));
    await controller.handleUpdate(makeCallback('chat:new:payments'));
    nextAgentBehavior = async () => ({
      conversationId: 'conv-markdown-e2e',
      response:
        '### Summary\n- Updated [HeroCard.jsx](file:///Users/dev/projects/portal.ch/src/HeroCard.jsx) with **dark theme** and `.card-btn`.'
    });
    mockTg.clearSent();
    await controller.handleUpdate(makeUserMsg('Polish hero card markup'));
    await controller.waitForBackgroundTasks();

    const agentMsg = mockTg.sentMessages.find((m) => /Agent Response:/.test(m.text));
    assert.ok(agentMsg, 'expected Agent Response message');
    assert.equal(agentMsg.parse_mode, 'HTML');
    assert.match(agentMsg.text, /<b>Summary<\/b>/);
    assert.match(agentMsg.text, /• Updated <code>HeroCard\.jsx<\/code> with <b>dark theme<\/b> and <code>\.card-btn<\/code>\./);
    assert.doesNotMatch(agentMsg.text, /file:\/\/\//);
  });

  it('supports multi-environment (Staging -> Production) Jenkins deploy and skip-prod confirmation', async () => {
    // Configure `payments` workspace as multi-environment (Staging + Production)
    const paymentsWs = configStore.config.workspaces.find((w) => w.id === 'payments');
    paymentsWs.environmentMode = 'multi';
    paymentsWs.prodJenkinsJobs = ['HOSTEGATOR/PAYMENT-BOOK/payment-book.com-GATE'];
    const coreRepoEntry = paymentsWs.repos.find((r) => r.name === 'payments_gate');
    coreRepoEntry.prodJenkinsJob = 'HOSTEGATOR/PAYMENT-BOOK/payment-book.com-GATE';
    await configStore.saveConfig();

    try {
      await controller.handleUpdate(makeCallback('ide:sel:payments'));
      assert.match(mockTg.lastSent().text, /Staging \(/);
      assert.match(mockTg.lastSent().text, /Prod \(1\):/);
      await controller.handleUpdate(makeCallback('chat:new:payments'));

      // Turn 1: Staging deploy -> Yes, deploy on prod!
      nextAgentBehavior = async () => {
        await fsp.writeFile(
          path.join(coreRepo.cloneDir, 'src-gate.js'),
          'export const gateVersion = 2;\n',
          'utf8'
        );
        return {
          conversationId: 'conv-multi-env-1',
          response: 'Updated payment gate.'
        };
      };

      mockJenkins.triggeredBuilds.length = 0;
      mockTg.clearSent();
      await controller.handleUpdate(makeUserMsg('Deploy gate update to staging then prod'));
      await controller.waitForBackgroundTasks();

      assert.equal(configStore.getWorkspaceState('payments').phase, 'AWAITING_COMMIT_CHOICE');
      await controller.handleUpdate(makeCallback('cmt:yes:payments'));
      assert.equal(configStore.getWorkspaceState('payments').phase, 'AWAITING_JENKINS_CHOICE');
      assert.match(mockTg.lastSent().text, /Run Staging Jenkins deploy\?/);

      mockJenkins.triggeredBuilds.length = 0;
      mockTg.clearSent();
      await controller.handleUpdate(makeCallback('jnk:yes:payments'));
      await controller.waitForBackgroundTasks();

      // Staging build finished -> must show 3 choices: Yes, deploy on prod / Yes (skip prod deploy) / Revert (Bad Commit)
      assert.equal(mockJenkins.triggeredBuilds.length, 1);
      assert.equal(mockJenkins.triggeredBuilds[0].jobName, 'Prod/payments/payments.example.com-GATE');
      assert.equal(configStore.getWorkspaceState('payments').phase, 'AWAITING_OK_OR_REVERT');

      const isOkMsg = mockTg.lastSent();
      assert.match(isOkMsg.text, /Staging Jenkins Deploy Succeeded!/);
      assert.match(isOkMsg.text, /Is it okay\?/);
      const okBtns = isOkMsg.reply_markup.inline_keyboard.flat();
      assert.ok(
        okBtns.some(
          (b) => b.callback_data === 'ok:prod:payments' && /Yes, deploy on prod/i.test(b.text)
        )
      );
      assert.ok(
        okBtns.some(
          (b) => b.callback_data === 'ok:yes:payments' && /Yes \(skip prod deploy\)/i.test(b.text)
        )
      );
      assert.ok(
        okBtns.some(
          (b) => b.callback_data === 'ok:rev:payments' && /Revert/i.test(b.text)
        )
      );

      // Click `🚀 Yes, deploy on prod` -> must run Production Jenkins job!
      mockTg.clearSent();
      await controller.handleUpdate(makeCallback('ok:prod:payments'));
      await controller.waitForBackgroundTasks();

      assert.equal(mockJenkins.triggeredBuilds.length, 2);
      assert.equal(
        mockJenkins.triggeredBuilds[1].jobName,
        'HOSTEGATOR/PAYMENT-BOOK/payment-book.com-GATE'
      );
      assert.equal(mockJenkins.triggeredBuilds[1].version, mockJenkins.triggeredBuilds[0].version);
      assert.equal(configStore.getWorkspaceState('payments').phase, 'IDLE');
      assert.match(mockTg.lastSent().text, /Production Jenkins Deploy Succeeded!/);

      // Turn 2: Staging deploy -> `✅ Yes (skip prod deploy)` must confirm WITHOUT triggering Prod Jenkins!
      nextAgentBehavior = async () => {
        await fsp.writeFile(
          path.join(coreRepo.cloneDir, 'src-gate.js'),
          'export const gateVersion = 3;\n',
          'utf8'
        );
        return {
          conversationId: 'conv-multi-env-1',
          response: 'Staging-only tweak.'
        };
      };

      await controller.handleUpdate(makeUserMsg('Make staging-only tweak'));
      await controller.waitForBackgroundTasks();
      await controller.handleUpdate(makeCallback('cmt:yes:payments'));
      mockJenkins.triggeredBuilds.length = 0;
      await controller.handleUpdate(makeCallback('jnk:yes:payments'));
      await controller.waitForBackgroundTasks();
      assert.equal(mockJenkins.triggeredBuilds.length, 1);

      mockTg.clearSent();
      await controller.handleUpdate(makeCallback('ok:yes:payments'));
      assert.equal(mockJenkins.triggeredBuilds.length, 1);
      assert.equal(configStore.getWorkspaceState('payments').phase, 'IDLE');
      assert.match(mockTg.lastSent().text, /skipped production deploy/);
    } finally {
      paymentsWs.environmentMode = 'single';
      paymentsWs.prodJenkinsJobs = [];
      coreRepoEntry.prodJenkinsJob = '';
      await configStore.saveConfig();
    }
  });

  it('auto-recovers transparently when Same Chat holds a Desktop IDE or missing trajectory ID (trajectory not found)', async () => {
    // Select Web Portal (which has no conversation in brainDir -> starts clean without global --continue)
    mockTg.clearSent();
    await controller.handleUpdate(makeCallback('ide:sel:portal'));
    const portalState = configStore.getWorkspaceState('portal');

    // Simulate a stale Desktop IDE trajectory ID (exact error seen in MAC OS workspace)
    portalState.conversationId = '554658dd-7e8d-41fb-8d30-74c4673458dc';
    portalState.phase = 'IDLE';
    await configStore.saveState();

    const callHistory = [];
    nextAgentBehavior = async (opts) => {
      callHistory.push({
        conversationId: opts.conversationId,
        continueLatest: opts.continueLatest
      });
      if (opts.conversationId === '554658dd-7e8d-41fb-8d30-74c4673458dc') {
        throw new Error(
          'Agent finished with status ERROR: error: failed to send message: not_found: trajectory not found: 554658dd-7e8d-41fb-8d30-74c4673458dc: not found'
        );
      }
      opts.onConversationId?.('cli-conv-recovered-999');
      return {
        conversationId: 'cli-conv-recovered-999',
        response: 'Recovered seamlessly on a fresh CLI trajectory!'
      };
    };

    mockTg.clearSent();
    await controller.handleUpdate(makeUserMsg('Update Telegram UI in MAC OS'));
    await controller.waitForBackgroundTasks();

    // Must have attempted the old ID once, detected trajectory-not-found, cleared it, and retried cleanly with conversationId: null!
    assert.deepEqual(callHistory, [
      { conversationId: '554658dd-7e8d-41fb-8d30-74c4673458dc', continueLatest: false },
      { conversationId: null, continueLatest: false }
    ]);
    assert.ok(!mockTg.sentMessages.some((m) => /Agent stopped\/failed/.test(m.text)));
    assert.ok(
      mockTg.sentMessages.some((m) => /Recovered seamlessly on a fresh CLI trajectory!/.test(m.text))
    );
    assert.equal(portalState.conversationId, 'cli-conv-recovered-999');

    // Subsequent message in Same Chat uses the valid CLI trajectory ID
    callHistory.length = 0;
    await controller.handleUpdate(makeUserMsg('Follow-up message in Same Chat'));
    await controller.waitForBackgroundTasks();
    assert.deepEqual(callHistory, [
      { conversationId: 'cli-conv-recovered-999', continueLatest: false }
    ]);
  });

  it('polls getUpdates, honors 429 retry_after + fresh socket recovery, requires new startup password on fresh run, and persists telegramOffset via startBotRunner', async () => {
    mockTg.clearSent();
    mockTg.pollErrors.push({
      status: 429,
      body: {
        ok: false,
        error_code: 429,
        description: 'Too Many Requests: retry after 1',
        parameters: { retry_after: 1 }
      }
    });
    mockTg.updateQueue.push(
      {
        update_id: 500,
        message: {
          message_id: 900,
          chat: { id: CHAT_ID, type: 'private' },
          from: { id: USER_ID, username: 'alice' },
          text: '/start'
        }
      },
      {
        update_id: 501,
        message: {
          message_id: 901,
          chat: { id: CHAT_ID, type: 'private' },
          from: { id: USER_ID, username: 'alice' },
          text: 'fresh-runner-pass-999'
        }
      }
    );

    const logs = [];
    const warns = [];
    const runner = await startBotRunner({
      dataDir: path.join(tmpRoot, 'data'),
      sessionPassword: 'fresh-runner-pass-999',
      nowProvider: () => currentNow,
      pollTimeoutSec: 1,
      logger: {
        log: (m) => logs.push(String(m)),
        warn: (m) => warns.push(String(m)),
        error: () => {}
      }
    });

    const deadline = Date.now() + 5000;
    while (runner.configStore.state.telegramOffset < 502 && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 40));
    }

    await runner.stop();
    assert.equal(runner.configStore.state.telegramOffset, 502);
    assert.ok(warns.some((w) => /Too Many Requests: retry after 1.*Waiting 2s/i.test(w)));
    assert.ok(logs.some((l) => /Telegram connection restored/i.test(l)));
    assert.ok(mockTg.sentMessages.some((m) => /Session requires authentication/.test(m.text)));
    assert.ok(mockTg.sentMessages.some((m) => /Select a Workspace/.test(m.text)));
  });
});
