import http from 'node:http';
import https from 'node:https';

/**
 * Normalizes a job identifier (`my-service`, `Folder/my-service`, `/job/Folder/job/my-service`,
 * or a full Jenkins job URL) into a relative Jenkins path like `/job/Folder/job/my-service`.
 */
export function normalizeJenkinsJobPath(rawJob, jobPrefix = '') {
  if (!rawJob || !String(rawJob).trim()) return '';
  let input = String(rawJob).trim();

  // Strip full URL origin if pasted
  if (/^https?:\/\//i.test(input)) {
    try {
      const parsed = new URL(input);
      input = parsed.pathname;
    } catch {
      // keep raw
    }
  }

  input = input.replace(/\/+$/, '');
  if (!input) return '';

  // Already in `/job/...` format
  if (input.startsWith('/job/') || input.startsWith('job/')) {
    return input.startsWith('/') ? input : `/${input}`;
  }

  const prefix = String(jobPrefix || '').trim().replace(/^\/+|\/+$/g, '');
  const combined = prefix && !input.includes('/') ? `${prefix}/${input}` : input;

  const segments = combined
    .split('/')
    .map((s) => s.trim())
    .filter(Boolean);

  return `/job/${segments.map((s) => encodeURIComponent(s)).join('/job/')}`;
}

/**
 * Rewrites internal Jenkins URLs (like http://127.0.0.1:8080/...) to use the configured baseUrl origin.
 */
export function rewriteToBaseOrigin(targetUrl, baseUrl) {
  if (!targetUrl) return '';
  try {
    const base = new URL(baseUrl);
    const target = new URL(targetUrl, base);
    target.protocol = base.protocol;
    target.hostname = base.hostname;
    target.port = base.port;
    return target.toString();
  } catch {
    return targetUrl;
  }
}

function rawHttpRequest(urlString, { method = 'GET', headers = {}, body = null, insecureTls = false, timeoutMs = 30_000 } = {}) {
  return new Promise((resolve, reject) => {
    const url = new URL(urlString);
    const isHttps = url.protocol === 'https:';
    const transport = isHttps ? https : http;

    const req = transport.request(
      url,
      {
        method,
        headers,
        rejectUnauthorized: !insecureTls,
        timeout: timeoutMs
      },
      (res) => {
        const chunks = [];
        res.on('data', (chunk) => chunks.push(chunk));
        res.on('end', () => {
          const text = Buffer.concat(chunks).toString('utf8');
          resolve({
            status: res.statusCode || 0,
            headers: res.headers,
            text
          });
        });
      }
    );

    req.on('timeout', () => {
      req.destroy(new Error(`Jenkins request timed out after ${timeoutMs}ms: ${urlString}`));
    });
    req.on('error', reject);

    if (body) {
      req.write(body);
    }
    req.end();
  });
}

function sleep(ms, signal) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(new Error('Aborted'));
      return;
    }
    const timer = setTimeout(() => {
      if (signal) signal.removeEventListener('abort', onAbort);
      resolve();
    }, ms);
    function onAbort() {
      clearTimeout(timer);
      reject(new Error('Aborted'));
    }
    if (signal) signal.addEventListener('abort', onAbort, { once: true });
  });
}

export class JenkinsClient {
  constructor(jenkinsConfig) {
    this.config = jenkinsConfig;
  }

  get baseUrl() {
    return String(this.config?.baseUrl || '').replace(/\/+$/, '');
  }

  ensureBaseUrl() {
    if (!this.baseUrl) {
      throw new Error(
        'Jenkins Base URL is not configured yet. Run "npm run setup" or "npm run update-jenkins" in terminal.'
      );
    }
    return this.baseUrl;
  }

  buildAuthHeaders(extra = {}) {
    const headers = {
      Accept: 'application/json',
      ...extra
    };
    if (this.config.username && this.config.apiToken) {
      const token = Buffer.from(`${this.config.username}:${this.config.apiToken}`, 'utf8').toString('base64');
      headers.Authorization = `Basic ${token}`;
    }
    return headers;
  }

  async fetchCrumb() {
    try {
      const res = await rawHttpRequest(`${this.baseUrl}/crumbIssuer/api/json`, {
        method: 'GET',
        headers: this.buildAuthHeaders(),
        insecureTls: Boolean(this.config.insecureTls),
        timeoutMs: 10_000
      });
      if (res.status >= 200 && res.status < 300) {
        const data = JSON.parse(res.text);
        const setCookie = res.headers['set-cookie'];
        const cookieHeader = Array.isArray(setCookie)
          ? setCookie.map((c) => c.split(';')[0]).join('; ')
          : '';
        return {
          crumbField: data.crumbRequestField,
          crumbValue: data.crumb,
          cookieHeader
        };
      }
    } catch {
      // Crumb issuer disabled or using API token directly
    }
    return null;
  }

  async testConnection() {
    const base = this.ensureBaseUrl();
    const res = await rawHttpRequest(
      `${base}/api/json?tree=jobs[name,url,jobs[name,url,jobs[name,url,jobs[name,url]]]]`,
      {
        method: 'GET',
        headers: this.buildAuthHeaders(),
        insecureTls: Boolean(this.config.insecureTls),
        timeoutMs: 12_000
      }
    );

    if (res.status === 401 || res.status === 403) {
      const isProxyIpBlock = res.status === 403 && /nginx/i.test(res.text || '');
      throw new Error(
        isProxyIpBlock
          ? 'Jenkins returned HTTP 403 from reverse proxy (IP allowlist / VPN check). Ensure your host VPN/IP is permitted or tunnel Jenkins over SSH.'
          : `Jenkins authentication failed (HTTP ${res.status}). Run "npm run update-jenkins" or "npm run setup" in terminal.`
      );
    }
    if (res.status < 200 || res.status >= 300) {
      throw new Error(`Jenkins returned HTTP ${res.status}`);
    }

    const parsed = JSON.parse(res.text);
    const jobs = [];
    function collectJobs(items, prefix = '') {
      for (const item of items || []) {
        const fullName = prefix ? `${prefix}/${item.name}` : item.name;
        if (Array.isArray(item.jobs) && item.jobs.length > 0) {
          collectJobs(item.jobs, fullName);
        } else {
          jobs.push(fullName);
        }
      }
    }
    collectJobs(parsed.jobs || []);

    return { ok: true, jobs };
  }

  /**
   * Triggers a Jenkins build for `jobName` with `VERSION=<branch>` and polls until completion.
   */
  async triggerAndWaitForBuild({ jobName, branch = 'master', onUpdate = () => {}, signal } = {}) {
    const base = this.ensureBaseUrl();
    const jobPath = normalizeJenkinsJobPath(jobName, this.config.jobPrefix);
    if (!jobPath) {
      throw new Error('Empty Jenkins job name');
    }

    const jobUrl = `${base}${jobPath}`;
    const crumb = await this.fetchCrumb();
    const postHeaders = this.buildAuthHeaders();
    if (crumb?.crumbField && crumb?.crumbValue) {
      postHeaders[crumb.crumbField] = crumb.crumbValue;
    }
    if (crumb?.cookieHeader) {
      postHeaders.Cookie = crumb.cookieHeader;
    }

    const paramUrl = `${jobUrl}/buildWithParameters?VERSION=${encodeURIComponent(branch)}`;
    onUpdate({
      jobName,
      jobUrl,
      status: 'TRIGGERING',
      message: `Triggering ${jobName} (VERSION=${branch})...`
    });

    let triggerRes = await rawHttpRequest(paramUrl, {
      method: 'POST',
      headers: postHeaders,
      insecureTls: Boolean(this.config.insecureTls),
      timeoutMs: 20_000
    });

    // Fallback if job does not accept parameters
    if (triggerRes.status === 400) {
      triggerRes = await rawHttpRequest(`${jobUrl}/build`, {
        method: 'POST',
        headers: postHeaders,
        insecureTls: Boolean(this.config.insecureTls),
        timeoutMs: 20_000
      });
    }

    if (triggerRes.status === 401 || triggerRes.status === 403) {
      const isProxyIpBlock = triggerRes.status === 403 && /nginx/i.test(triggerRes.text || '');
      throw new Error(
        isProxyIpBlock
          ? `Jenkins rejected "${jobName}" with reverse-proxy HTTP 403 (IP allowlist / VPN check). Ensure your host VPN/IP is permitted or tunnel Jenkins over SSH.`
          : `Jenkins rejected trigger for "${jobName}" (HTTP ${triggerRes.status}). Run "npm run update-jenkins" or "npm run setup" in terminal.`
      );
    }
    if (triggerRes.status === 404) {
      throw new Error(
        `Jenkins job not found at ${jobPath} (HTTP 404). Check the job path via "npm run setup" or "npm run add-ide" in terminal.`
      );
    }
    if (triggerRes.status < 200 || triggerRes.status >= 400) {
      throw new Error(`Jenkins trigger failed for "${jobName}" (HTTP ${triggerRes.status})`);
    }

    const rawLocation = triggerRes.headers.location;
    if (!rawLocation) {
      return {
        jobName,
        jobUrl,
        buildNumber: null,
        buildUrl: jobUrl,
        result: 'TRIGGERED',
        consoleTail: ''
      };
    }

    const queueUrl = rewriteToBaseOrigin(rawLocation, this.baseUrl).replace(/\/+$/, '');
    const pollIntervalMs = Number(this.config.pollIntervalMs) || 3000;
    const timeoutMs = Number(this.config.buildTimeoutMs) || 25 * 60 * 1000;
    const deadline = Date.now() + timeoutMs;

    onUpdate({
      jobName,
      jobUrl,
      queueUrl,
      status: 'QUEUED',
      message: `Queued in Jenkins (${jobName})...`
    });

    let buildNumber = null;
    let buildUrl = null;

    while (Date.now() < deadline) {
      await sleep(pollIntervalMs, signal);

      const qRes = await rawHttpRequest(`${queueUrl}/api/json`, {
        method: 'GET',
        headers: this.buildAuthHeaders(),
        insecureTls: Boolean(this.config.insecureTls),
        timeoutMs: 15_000
      });

      if (qRes.status >= 200 && qRes.status < 300) {
        const qData = JSON.parse(qRes.text);
        if (qData.cancelled) {
          throw new Error(`Jenkins queue item for "${jobName}" was cancelled`);
        }
        if (qData.executable && qData.executable.number) {
          buildNumber = qData.executable.number;
          buildUrl = qData.executable.url
            ? rewriteToBaseOrigin(qData.executable.url, this.baseUrl).replace(/\/+$/, '')
            : `${jobUrl}/${buildNumber}`;
          break;
        }
        if (qData.why) {
          onUpdate({
            jobName,
            jobUrl,
            queueUrl,
            status: 'QUEUED',
            message: `Queued: ${qData.why}`
          });
        }
      }
    }

    if (!buildNumber || !buildUrl) {
      throw new Error(`Timed out waiting for Jenkins queue to start build for "${jobName}"`);
    }

    onUpdate({
      jobName,
      jobUrl,
      buildNumber,
      buildUrl,
      status: 'BUILDING',
      message: `Building ${jobName} #${buildNumber}...`
    });

    while (Date.now() < deadline) {
      const bRes = await rawHttpRequest(`${buildUrl}/api/json`, {
        method: 'GET',
        headers: this.buildAuthHeaders(),
        insecureTls: Boolean(this.config.insecureTls),
        timeoutMs: 15_000
      });

      if (bRes.status >= 200 && bRes.status < 300) {
        const bData = JSON.parse(bRes.text);
        const consoleTail = await this.fetchConsoleTail(buildUrl);

        if (!bData.building && bData.result) {
          const finalStatus = bData.result;
          onUpdate({
            jobName,
            jobUrl,
            buildNumber,
            buildUrl,
            status: finalStatus,
            consoleTail,
            message: `${jobName} #${buildNumber}: ${finalStatus}`
          });
          return {
            jobName,
            jobUrl,
            buildNumber,
            buildUrl: `${buildUrl}/`,
            result: finalStatus,
            durationMs: bData.duration || 0,
            consoleTail
          };
        }

        onUpdate({
          jobName,
          jobUrl,
          buildNumber,
          buildUrl,
          status: 'BUILDING',
          consoleTail,
          message: `Building ${jobName} #${buildNumber}...`
        });
      }

      await sleep(pollIntervalMs, signal);
    }

    throw new Error(`Timed out waiting for Jenkins build ${jobName} #${buildNumber} to complete`);
  }

  async fetchConsoleTail(buildUrl, maxChars = 2400) {
    try {
      const res = await rawHttpRequest(`${buildUrl}/consoleText`, {
        method: 'GET',
        headers: this.buildAuthHeaders({ Accept: 'text/plain' }),
        insecureTls: Boolean(this.config.insecureTls),
        timeoutMs: 8_000
      });
      if (res.status >= 200 && res.status < 300 && res.text) {
        return res.text.length > maxChars ? `…${res.text.slice(-maxChars)}` : res.text;
      }
    } catch {
      // Optional log preview
    }
    return '';
  }
}
