import { spawn, exec } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { promisify } from 'node:util';
import {
  runAgyTurn,
  resolveEffectiveModelAndLevel,
  DEFAULT_AGENT_MODEL_FAMILIES,
  BOT_CONTROLLER_PROMPT_SUFFIX
} from './agy-runner.mjs';

const execAsync = promisify(exec);

// In-memory conversation state cache for Direct API multi-turn chats
const DIRECT_API_CONVERSATIONS = new Map();

export const AGENT_TOOLS_SPEC = [
  {
    type: 'function',
    function: {
      name: 'read_file',
      description: 'Reads the contents of a file in the workspace.',
      parameters: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Relative path to the file' },
          start_line: { type: 'number', description: 'Optional 1-based start line' },
          end_line: { type: 'number', description: 'Optional 1-based end line' }
        },
        required: ['path']
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'edit_file',
      description: 'Replaces exact text in a workspace file.',
      parameters: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Relative path to the file' },
          target: { type: 'string', description: 'Exact string to find and replace' },
          replacement: { type: 'string', description: 'String to replace target with' }
        },
        required: ['path', 'target', 'replacement']
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'write_file',
      description: 'Creates or replaces a file with complete content in the workspace.',
      parameters: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Relative path to the file' },
          content: { type: 'string', description: 'Full content to write to the file' }
        },
        required: ['path', 'content']
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'list_dir',
      description: 'Lists files and directories in a workspace directory.',
      parameters: {
        type: 'object',
        properties: {
          path: { type: 'string', description: 'Relative directory path (defaults to root)' }
        }
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'run_command',
      description: 'Runs a shell command in the workspace directory.',
      parameters: {
        type: 'object',
        properties: {
          command: { type: 'string', description: 'Shell command line to execute' }
        },
        required: ['command']
      }
    }
  }
];

function resolveWorkspaceFilePath(workspacePath, relPath) {
  const cleanRel = String(relPath || '').trim();
  const target = path.isAbsolute(cleanRel) ? cleanRel : path.resolve(workspacePath, cleanRel);
  // Ensure path is inside workspace
  const resolvedWs = path.resolve(workspacePath);
  if (!target.startsWith(resolvedWs)) {
    throw new Error(`Path "${cleanRel}" escapes workspace directory`);
  }
  return target;
}

export async function executeWorkspaceTool(workspacePath, name, args = {}) {
  switch (name) {
    case 'read_file': {
      const fullPath = resolveWorkspaceFilePath(workspacePath, args.path);
      const content = await fsp.readFile(fullPath, 'utf8');
      if (args.start_line || args.end_line) {
        const lines = content.split('\n');
        const start = Math.max(0, (args.start_line || 1) - 1);
        const end = args.end_line ? Math.min(lines.length, args.end_line) : lines.length;
        return lines.slice(start, end).join('\n');
      }
      return content;
    }
    case 'write_file': {
      const fullPath = resolveWorkspaceFilePath(workspacePath, args.path);
      await fsp.mkdir(path.dirname(fullPath), { recursive: true });
      await fsp.writeFile(fullPath, args.content ?? '', 'utf8');
      return `Successfully wrote ${Buffer.byteLength(args.content ?? '', 'utf8')} bytes to ${args.path}`;
    }
    case 'edit_file': {
      const fullPath = resolveWorkspaceFilePath(workspacePath, args.path);
      const content = await fsp.readFile(fullPath, 'utf8');
      if (!content.includes(args.target)) {
        throw new Error(`Target text to replace not found in ${args.path}`);
      }
      const updated = content.replaceAll(args.target, args.replacement ?? '');
      await fsp.writeFile(fullPath, updated, 'utf8');
      return `Successfully edited ${args.path}`;
    }
    case 'list_dir': {
      const dirPath = resolveWorkspaceFilePath(workspacePath, args.path || '.');
      const entries = await fsp.readdir(dirPath, { withFileTypes: true });
      return entries
        .map((e) => `${e.isDirectory() ? '[DIR] ' : '[FILE]'} ${e.name}`)
        .join('\n') || '(empty directory)';
    }
    case 'run_command': {
      const cmd = String(args.command || '').trim();
      if (!cmd) throw new Error('Command cannot be empty');
      try {
        const { stdout, stderr } = await execAsync(cmd, {
          cwd: workspacePath,
          timeout: 60_000,
          maxBuffer: 1024 * 1024 * 5
        });
        const out = stdout.trim();
        const err = stderr.trim();
        return out ? (err ? `${out}\n[stderr]: ${err}` : out) : (err ? `[stderr]: ${err}` : '(command finished with no output)');
      } catch (err) {
        return `[command failed with code ${err.code ?? 1}]:\n${err.stdout || ''}\n${err.stderr || err.message}`;
      }
    }
    default:
      throw new Error(`Unknown tool: ${name}`);
  }
}

/**
 * Executes a turn via direct API call with tool-calling loop (OpenAI, DeepSeek, Anthropic, Qwen, Custom).
 */
export function runDirectApiTurn({
  workspacePath,
  prompt,
  imagePaths = [],
  conversationId = null,
  model = '',
  modelLevel = '',
  apiKey = '',
  apiBaseUrl = '',
  provider = 'openai', // 'openai', 'deepseek', 'anthropic', 'qwen', 'custom'
  onConversationId = () => {},
  onTextDelta = () => {},
  onStepEvent = () => {}
}) {
  const activeConvId = conversationId || crypto.randomUUID();
  onConversationId(activeConvId);

  const controller = new AbortController();
  const startTime = Date.now();

  const promise = (async () => {
    // Resolve endpoint and key
    let endpoint = apiBaseUrl;
    let effectiveKey = apiKey;

    if (provider === 'deepseek') {
      endpoint = endpoint || 'https://api.deepseek.com/chat/completions';
      if (!effectiveKey) {
        throw new Error('DeepSeek API key is not configured. Please set your DeepSeek API Key in MAC App -> General tab or set DEEPSEEK_API_KEY environment variable.');
      }
    } else if (provider === 'openai') {
      endpoint = endpoint || 'https://api.openai.com/v1/chat/completions';
      if (!effectiveKey) {
        throw new Error('OpenAI API key is not configured. Please set your OpenAI API Key in MAC App -> General tab or set OPENAI_API_KEY environment variable.');
      }
    } else if (provider === 'anthropic') {
      endpoint = endpoint || 'https://api.anthropic.com/v1/messages';
      if (!effectiveKey) {
        throw new Error('Anthropic API key is not configured. Please set your Anthropic API Key in MAC App -> General tab or set ANTHROPIC_API_KEY environment variable.');
      }
    } else if (provider === 'qwen') {
      endpoint = endpoint || 'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions';
      if (!effectiveKey) {
        throw new Error('Qwen/DashScope API key is not configured. Please set your Qwen API Key in MAC App -> General tab or set QWEN_API_KEY environment variable.');
      }
    } else if (provider === 'custom') {
      endpoint = endpoint || 'http://localhost:11434/v1/chat/completions';
    }

    // Retrieve or initialize conversation messages
    let history = DIRECT_API_CONVERSATIONS.get(activeConvId);
    if (!history) {
      history = [];
      DIRECT_API_CONVERSATIONS.set(activeConvId, history);
    }

    const systemPrompt =
      'You are a senior software engineer assistant operating headlessly on a local repository. ' +
      'Inspect files, edit code, run commands, and solve the requested tasks accurately. ' +
      'Do NOT run git commit or push — the system will review changes and commit them automatically.\n\n' +
      BOT_CONTROLLER_PROMPT_SUFFIX;

    // Build user message content
    let userText = String(prompt || '').trim();
    if (imagePaths && imagePaths.length > 0) {
      const imgLines = imagePaths.map((p, i) => `  ${i + 1}. ${p}`).join('\n');
      userText = `${userText}\n\n[Attached Photo(s) - read each file if needed:\n${imgLines}]`.trim();
    }
    history.push({ role: 'user', content: userText });

    const isAnthropic = provider === 'anthropic';

    let maxSteps = 15;
    let stepCount = 0;
    let accumulatedResponse = '';

    while (stepCount < maxSteps) {
      stepCount++;
      if (controller.signal.aborted) {
        throw new Error('Agent run stopped by user');
      }

      onStepEvent({
        stepIndex: stepCount,
        stepType: 'model_call',
        state: 'RUNNING',
        toolName: ''
      });

      let reqBody;
      let headers;

      if (isAnthropic) {
        headers = {
          'Content-Type': 'application/json',
          'x-api-key': effectiveKey,
          'anthropic-version': '2023-06-01'
        };
        const anthropicTools = AGENT_TOOLS_SPEC.map((t) => ({
          name: t.function.name,
          description: t.function.description,
          input_schema: t.function.parameters
        }));
        reqBody = JSON.stringify({
          model: model || 'claude-3-7-sonnet-20250219',
          max_tokens: 4096,
          system: systemPrompt,
          messages: history.map((m) => ({
            role: m.role === 'assistant' ? 'assistant' : 'user',
            content: m.content
          })),
          tools: anthropicTools
        });
      } else {
        // OpenAI-compatible format (OpenAI, DeepSeek, Qwen, Custom)
        headers = {
          'Content-Type': 'application/json',
          Authorization: effectiveKey ? `Bearer ${effectiveKey}` : undefined
        };
        const apiMessages = [
          { role: 'system', content: systemPrompt },
          ...history
        ];
        reqBody = JSON.stringify({
          model: model || (provider === 'deepseek' ? 'deepseek-chat' : 'gpt-4o'),
          messages: apiMessages,
          tools: AGENT_TOOLS_SPEC
        });
      }

      const res = await fetch(endpoint, {
        method: 'POST',
        headers,
        body: reqBody,
        signal: controller.signal
      });

      if (!res.ok) {
        const errText = await res.text().catch(() => '');
        throw new Error(`API error (${res.status} ${res.statusText}): ${errText}`);
      }

      const json = await res.json();

      if (isAnthropic) {
        const contentList = json.content || [];
        const textParts = contentList.filter((c) => c.type === 'text').map((c) => c.text);
        if (textParts.length > 0) {
          const delta = textParts.join('\n');
          accumulatedResponse += delta;
          onTextDelta(delta, accumulatedResponse);
        }

        const toolCalls = contentList.filter((c) => c.type === 'tool_use');
        if (toolCalls.length === 0) {
          history.push({ role: 'assistant', content: accumulatedResponse });
          break;
        }

        // Execute Anthropic tools
        history.push({ role: 'assistant', content: contentList });
        const toolResults = [];
        for (const tc of toolCalls) {
          onStepEvent({
            stepIndex: stepCount,
            stepType: 'tool_call',
            state: 'RUNNING',
            toolName: tc.name
          });
          let resultText = '';
          let isError = false;
          try {
            resultText = await executeWorkspaceTool(workspacePath, tc.name, tc.input || {});
          } catch (tErr) {
            resultText = `Error: ${tErr.message}`;
            isError = true;
          }
          onStepEvent({
            stepIndex: stepCount,
            stepType: 'tool_call',
            state: isError ? 'ERROR' : 'SUCCESS',
            toolName: tc.name
          });
          toolResults.push({
            type: 'tool_result',
            tool_use_id: tc.id,
            content: String(resultText),
            is_error: isError
          });
        }
        history.push({ role: 'user', content: toolResults });
      } else {
        // OpenAI-compatible response parsing
        const choice = json.choices && json.choices[0];
        const msg = choice?.message;
        if (!msg) {
          throw new Error('Invalid response structure from LLM endpoint');
        }

        if (msg.content) {
          accumulatedResponse += msg.content;
          onTextDelta(msg.content, accumulatedResponse);
        }

        if (!msg.tool_calls || msg.tool_calls.length === 0) {
          history.push({ role: 'assistant', content: msg.content || '' });
          break;
        }

        // Record assistant tool calls in history
        history.push(msg);

        // Execute each tool call
        for (const tc of msg.tool_calls) {
          const fnName = tc.function.name;
          let parsedArgs = {};
          try {
            parsedArgs = JSON.parse(tc.function.arguments || '{}');
          } catch {
            parsedArgs = {};
          }

          onStepEvent({
            stepIndex: stepCount,
            stepType: 'tool_call',
            state: 'RUNNING',
            toolName: fnName
          });

          let resultText = '';
          try {
            resultText = await executeWorkspaceTool(workspacePath, fnName, parsedArgs);
          } catch (tErr) {
            resultText = `Error executing tool: ${tErr.message}`;
          }

          onStepEvent({
            stepIndex: stepCount,
            stepType: 'tool_call',
            state: 'SUCCESS',
            toolName: fnName
          });

          history.push({
            role: 'tool',
            tool_call_id: tc.id,
            name: fnName,
            content: String(resultText)
          });
        }
      }
    }

    const durationSeconds = Math.round((Date.now() - startTime) / 1000);
    return {
      conversationId: activeConvId,
      response: accumulatedResponse.trim() || 'Task completed.',
      durationSeconds,
      usage: null
    };
  })();

  function abort() {
    controller.abort();
  }

  return { promise, abort };
}

/**
 * Runs a turn using the Aider CLI (`aider`) in non-interactive headless mode.
 */
export function runAiderTurn({
  aiderBin = 'aider',
  workspacePath,
  prompt,
  model = '',
  openaiApiKey = '',
  anthropicApiKey = '',
  deepseekApiKey = '',
  qwenApiKey = '',
  onTextDelta = () => {},
  onStepEvent = () => {}
}) {
  const env = {
    ...process.env,
    OPENAI_API_KEY: openaiApiKey || process.env.OPENAI_API_KEY || '',
    ANTHROPIC_API_KEY: anthropicApiKey || process.env.ANTHROPIC_API_KEY || '',
    DEEPSEEK_API_KEY: deepseekApiKey || process.env.DEEPSEEK_API_KEY || '',
    QWEN_API_KEY: qwenApiKey || process.env.QWEN_API_KEY || ''
  };

  const args = [
    '--no-git',
    '--yes-always',
    '--no-auto-commits',
    '-m',
    `${prompt}\n\n${BOT_CONTROLLER_PROMPT_SUFFIX}`
  ];

  if (model) {
    args.push('--model', model);
  }

  let child = null;
  let aborted = false;

  const promise = new Promise((resolve, reject) => {
    onStepEvent({
      stepIndex: 1,
      stepType: 'aider_run',
      state: 'RUNNING',
      toolName: ''
    });

    child = spawn(aiderBin, args, {
      cwd: workspacePath,
      env,
      stdio: ['pipe', 'pipe', 'pipe']
    });

    child.stdin.end();

    let output = '';
    let stderrText = '';

    child.stdout.on('data', (chunk) => {
      const text = chunk.toString('utf8');
      output += text;
      onTextDelta(text, output);
    });

    child.stderr.on('data', (chunk) => {
      stderrText += chunk.toString('utf8');
    });

    child.on('error', (err) => {
      reject(new Error(`Failed to spawn aider (${aiderBin}): ${err.message}`));
    });

    child.on('close', (code) => {
      if (aborted) {
        reject(new Error('Agent run stopped by user'));
        return;
      }
      if (code !== 0) {
        reject(new Error(`aider exited with error code ${code}: ${stderrText.trim() || output.trim()}`));
        return;
      }
      onStepEvent({
        stepIndex: 1,
        stepType: 'aider_run',
        state: 'SUCCESS',
        toolName: ''
      });
      resolve({
        conversationId: null,
        response: output.trim(),
        durationSeconds: null,
        usage: null
      });
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
        } catch {}
      }, 2000).unref();
    } catch {}
  }

  return { promise, abort };
}

/**
 * Unified Agent Runner supporting:
 * - Option 1: Terminal CLI Runners (`agy`, `aider`)
 * - Option 2: Direct API Execution (DeepSeek, OpenAI, Anthropic Claude, Qwen, Custom)
 */
export function runUnifiedAgentTurn({
  agyBin,
  aiderBin,
  agentEngine = 'auto',
  openaiApiKey = '',
  anthropicApiKey = '',
  deepseekApiKey = '',
  qwenApiKey = '',
  customApiBaseUrl = '',
  customApiKey = '',
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
  const normModel = String(model || '').trim().toLowerCase();

  // Determine provider by model identifier
  const isDeepSeek = normModel.includes('deepseek');
  const isOpenAI = normModel.includes('gpt-') || normModel.includes('o3-mini') || normModel === 'o1';
  const isAnthropicClaude = normModel.includes('claude-3-') || normModel.includes('claude-3.');
  const isQwen = normModel.includes('qwen');
  const isNativeAgyClaude = normModel.includes('claude-opus-5-5') || normModel.includes('claude-sonnet-5-5');
  const isGemini = normModel.includes('gemini') || (!isDeepSeek && !isOpenAI && !isAnthropicClaude && !isQwen && !normModel.includes('claude'));

  // 1. Explicit Engine Selection
  if (agentEngine === 'aider') {
    return runAiderTurn({
      aiderBin: aiderBin || 'aider',
      workspacePath,
      prompt,
      model,
      openaiApiKey,
      anthropicApiKey,
      deepseekApiKey,
      qwenApiKey,
      onTextDelta,
      onStepEvent
    });
  }

  if (agentEngine === 'direct-api') {
    let provider = 'openai';
    let apiKey = openaiApiKey;
    let apiBaseUrl = '';

    if (customApiBaseUrl) {
      provider = 'custom';
      apiBaseUrl = customApiBaseUrl;
      apiKey = customApiKey;
    } else if (isDeepSeek) {
      provider = 'deepseek';
      apiKey = deepseekApiKey;
    } else if (isAnthropicClaude || isNativeAgyClaude) {
      provider = 'anthropic';
      apiKey = anthropicApiKey;
    } else if (isQwen) {
      provider = 'qwen';
      apiKey = qwenApiKey;
    }

    return runDirectApiTurn({
      workspacePath,
      prompt,
      imagePaths,
      conversationId,
      model,
      modelLevel,
      apiKey,
      apiBaseUrl,
      provider,
      onConversationId,
      onTextDelta,
      onStepEvent
    });
  }

  if (agentEngine === 'agy') {
    return runAgyTurn({
      agyBin,
      workspacePath,
      prompt,
      imagePaths,
      conversationId,
      continueLatest,
      model,
      modelLevel,
      skipPermissions,
      extraDirs,
      onConversationId,
      onTextDelta,
      onStepEvent
    });
  }

  // 2. Auto Engine Selection (Recommended)
  // If model is Gemini or Native AGY Claude, prefer `agy` CLI
  if ((isGemini || isNativeAgyClaude) && agyBin) {
    return runAgyTurn({
      agyBin,
      workspacePath,
      prompt,
      imagePaths,
      conversationId,
      continueLatest,
      model,
      modelLevel,
      skipPermissions,
      extraDirs,
      onConversationId,
      onTextDelta,
      onStepEvent
    });
  }

  // If custom API URL provided, run direct API
  if (customApiBaseUrl) {
    return runDirectApiTurn({
      workspacePath,
      prompt,
      imagePaths,
      conversationId,
      model,
      modelLevel,
      apiKey: customApiKey,
      apiBaseUrl: customApiBaseUrl,
      provider: 'custom',
      onConversationId,
      onTextDelta,
      onStepEvent
    });
  }

  // If DeepSeek model
  if (isDeepSeek) {
    return runDirectApiTurn({
      workspacePath,
      prompt,
      imagePaths,
      conversationId,
      model,
      modelLevel,
      apiKey: deepseekApiKey,
      provider: 'deepseek',
      onConversationId,
      onTextDelta,
      onStepEvent
    });
  }

  // If OpenAI model
  if (isOpenAI) {
    return runDirectApiTurn({
      workspacePath,
      prompt,
      imagePaths,
      conversationId,
      model,
      modelLevel,
      apiKey: openaiApiKey,
      provider: 'openai',
      onConversationId,
      onTextDelta,
      onStepEvent
    });
  }

  // If Anthropic Claude model (e.g. Claude 3.7 / 3.5)
  if (isAnthropicClaude) {
    return runDirectApiTurn({
      workspacePath,
      prompt,
      imagePaths,
      conversationId,
      model,
      modelLevel,
      apiKey: anthropicApiKey,
      provider: 'anthropic',
      onConversationId,
      onTextDelta,
      onStepEvent
    });
  }

  // If Qwen model
  if (isQwen) {
    return runDirectApiTurn({
      workspacePath,
      prompt,
      imagePaths,
      conversationId,
      model,
      modelLevel,
      apiKey: qwenApiKey,
      provider: 'qwen',
      onConversationId,
      onTextDelta,
      onStepEvent
    });
  }

  // Fallback to agy CLI
  return runAgyTurn({
    agyBin,
    workspacePath,
    prompt,
    imagePaths,
    conversationId,
    continueLatest,
    model,
    modelLevel,
    skipPermissions,
    extraDirs,
    onConversationId,
    onTextDelta,
    onStepEvent
  });
}
