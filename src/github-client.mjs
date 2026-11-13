import https from 'node:https';

/**
 * Parses a GitHub repository string (e.g. "owner/repo", "repo", or "https://github.com/owner/repo.git")
 * into normalized `{ owner, repo, fullName }`.
 */
export function parseGitHubRepoSlug(rawInput, defaultOwner = '') {
  let s = String(rawInput || '').trim();
  if (!s) return { owner: '', repo: '', fullName: '' };

  if (/^https?:\/\//i.test(s) || s.startsWith('git@')) {
    try {
      if (s.startsWith('git@')) {
        s = s.replace(/^git@[^:]+:/, 'https://github.com/');
      }
      const parsed = new URL(s);
      s = parsed.pathname.replace(/^\/+/, '').replace(/\.git$/i, '');
    } catch {
      // keep raw
    }
  }

  s = s.replace(/\.git$/i, '').replace(/^\/+|\/+$/g, '');
  if (s.includes('/')) {
    const parts = s.split('/').filter(Boolean);
    const owner = parts[0] || '';
    const repo = parts[1] || '';
    return { owner, repo, fullName: `${owner}/${repo}` };
  }

  const owner = String(defaultOwner || '').trim();
  return {
    owner,
    repo: s,
    fullName: owner ? `${owner}/${s}` : s
  };
}

/**
 * Makes an HTTPS request to the GitHub REST API (v3 / application/vnd.github+json).
 */
export function rawGitHubRequest(
  endpoint,
  { method = 'GET', token = '', body = null, timeoutMs = 25_000 } = {}
) {
  return new Promise((resolve, reject) => {
    const urlString = endpoint.startsWith('https://') ? endpoint : `https://api.github.com${endpoint.startsWith('/') ? '' : '/'}${endpoint}`;
    const url = new URL(urlString);

    const headers = {
      'User-Agent': 'MobileAgentControl',
      'Accept': 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28'
    };

    if (token) {
      headers['Authorization'] = `Bearer ${token.trim()}`;
    }

    let payload = null;
    if (body) {
      payload = typeof body === 'string' ? body : JSON.stringify(body);
      headers['Content-Type'] = 'application/json';
      headers['Content-Length'] = Buffer.byteLength(payload);
    }

    const req = https.request(
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
      req.destroy(new Error(`GitHub request timed out after ${timeoutMs}ms: ${urlString}`));
    });
    req.on('error', reject);

    if (payload) {
      req.write(payload);
    }
    req.end();
  });
}

function sleep(ms, signal) {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      return reject(new Error('Operation cancelled'));
    }
    const timer = setTimeout(resolve, ms);
    if (signal) {
      signal.addEventListener(
        'abort',
        () => {
          clearTimeout(timer);
          reject(new Error('Operation cancelled'));
        },
        { once: true }
      );
    }
  });
}

export class GitHubClient {
  constructor({ token = '', defaultOwner = '', timeoutMs = 25_000 } = {}) {
    this.token = String(token || '').trim();
    this.defaultOwner = String(defaultOwner || '').trim();
    this.timeoutMs = timeoutMs;
  }

  /**
   * Verifies credentials against `GET /user`.
   */
  async testConnection() {
    if (!this.token) {
      throw new Error('GitHub Personal Access Token is required to test access.');
    }
    const res = await rawGitHubRequest('/user', {
      method: 'GET',
      token: this.token,
      timeoutMs: this.timeoutMs
    });

    if (res.status === 200) {
      const data = JSON.parse(res.text);
      const scopes = res.headers['x-oauth-scopes'] || 'verified token';
      return {
        ok: true,
        user: data.login,
        name: data.name || data.login,
        scopes,
        htmlUrl: data.html_url
      };
    }

    let errMsg = `HTTP ${res.status}`;
    try {
      const parsed = JSON.parse(res.text);
      if (parsed.message) errMsg = `${errMsg}: ${parsed.message}`;
    } catch {
      if (res.text) errMsg = `${errMsg}: ${res.text.slice(0, 100)}`;
    }
    throw new Error(`GitHub authentication failed: ${errMsg}`);
  }

  /**
   * Triggers a workflow dispatch event and polls until completion.
   */
  async triggerWorkflow({
    owner = '',
    repo = '',
    workflow = 'deploy.yml',
    branch = 'main',
    inputs = {},
    signal = null,
    pollIntervalMs = 3000,
    maxWaitMs = 15 * 60 * 1000,
    onProgress = null
  } = {}) {
    if (!this.token) {
      throw new Error('GitHub Personal Access Token is required to trigger workflows.');
    }

    const repoSlug = parseGitHubRepoSlug(repo, owner || this.defaultOwner);
    if (!repoSlug.owner || !repoSlug.repo) {
      throw new Error(`Invalid GitHub repository: "${repo || owner}". Expected "owner/repo".`);
    }

    const cleanWorkflow = String(workflow || 'deploy.yml').trim();
    const cleanBranch = String(branch || 'main').trim();
    const startTime = new Date();

    if (onProgress) {
      onProgress(`🚀 Dispatching GitHub Actions workflow "${cleanWorkflow}" on ${repoSlug.fullName} (${cleanBranch})…`);
    }

    // Trigger workflow dispatch
    const dispatchEndpoint = `/repos/${encodeURIComponent(repoSlug.owner)}/${encodeURIComponent(repoSlug.repo)}/actions/workflows/${encodeURIComponent(cleanWorkflow)}/dispatches`;
    const dispatchRes = await rawGitHubRequest(dispatchEndpoint, {
      method: 'POST',
      token: this.token,
      body: {
        ref: cleanBranch,
        inputs: inputs || {}
      },
      timeoutMs: this.timeoutMs
    });

    if (dispatchRes.status !== 204 && dispatchRes.status !== 200 && dispatchRes.status !== 201 && dispatchRes.status !== 202) {
      let errMsg = `HTTP ${dispatchRes.status}`;
      try {
        const parsed = JSON.parse(dispatchRes.text);
        if (parsed.message) errMsg = `${errMsg}: ${parsed.message}`;
      } catch {
        if (dispatchRes.text) errMsg = `${errMsg}: ${dispatchRes.text.slice(0, 150)}`;
      }
      throw new Error(`Failed to dispatch GitHub workflow "${cleanWorkflow}": ${errMsg}`);
    }

    if (onProgress) {
      onProgress(`⏳ Workflow dispatched. Finding run on ${cleanBranch}…`);
    }

    // Poll for the created run
    let targetRun = null;
    const runsEndpoint = `/repos/${encodeURIComponent(repoSlug.owner)}/${encodeURIComponent(repoSlug.repo)}/actions/runs?branch=${encodeURIComponent(cleanBranch)}&per_page=5`;
    const deadline = Date.now() + maxWaitMs;

    // Give GitHub a few seconds to enqueue the run
    await sleep(2500, signal);

    while (Date.now() < deadline) {
      if (signal?.aborted) throw new Error('GitHub deployment cancelled');

      const listRes = await rawGitHubRequest(runsEndpoint, {
        method: 'GET',
        token: this.token,
        timeoutMs: this.timeoutMs
      });

      if (listRes.status === 200) {
        try {
          const data = JSON.parse(listRes.text);
          const runs = data.workflow_runs || [];
          // Find run created right around startTime
          for (const r of runs) {
            const runCreated = new Date(r.created_at || r.run_started_at || 0).getTime();
            if (runCreated >= startTime.getTime() - 30_000) {
              targetRun = r;
              break;
            }
          }
          if (!targetRun && runs.length > 0) {
            targetRun = runs[0];
          }
        } catch {
          // keep polling
        }
      }

      if (targetRun) {
        if (targetRun.status === 'completed') {
          break;
        }
        if (onProgress) {
          onProgress(`⏳ Workflow run #${targetRun.run_number} is ${targetRun.status}… (${targetRun.html_url})`);
        }
      }

      await sleep(pollIntervalMs, signal);

      if (targetRun?.id) {
        // Fetch specific run status
        const singleRunRes = await rawGitHubRequest(
          `/repos/${encodeURIComponent(repoSlug.owner)}/${encodeURIComponent(repoSlug.repo)}/actions/runs/${targetRun.id}`,
          { method: 'GET', token: this.token, timeoutMs: this.timeoutMs }
        );
        if (singleRunRes.status === 200) {
          try {
            targetRun = JSON.parse(singleRunRes.text);
            if (targetRun.status === 'completed') break;
          } catch {
            // continue
          }
        }
      }
    }

    if (!targetRun) {
      throw new Error(`Workflow run could not be found after dispatching "${cleanWorkflow}".`);
    }

    const isSuccess = targetRun.conclusion === 'success';
    let errorLog = '';

    if (!isSuccess) {
      // Fetch failed step logs
      try {
        const jobsRes = await rawGitHubRequest(
          `/repos/${encodeURIComponent(repoSlug.owner)}/${encodeURIComponent(repoSlug.repo)}/actions/runs/${targetRun.id}/jobs`,
          { method: 'GET', token: this.token, timeoutMs: this.timeoutMs }
        );
        if (jobsRes.status === 200) {
          const jobData = JSON.parse(jobsRes.text);
          const failedJob = (jobData.jobs || []).find((j) => j.conclusion === 'failure') || jobData.jobs?.[0];
          if (failedJob) {
            const failedStep = (failedJob.steps || []).find((s) => s.conclusion === 'failure');
            errorLog = `Job "${failedJob.name}" failed${failedStep ? ` on step "${failedStep.name}"` : ''}.\nURL: ${failedJob.html_url || targetRun.html_url}`;
          }
        }
      } catch {
        errorLog = `Workflow run #${targetRun.run_number} failed with conclusion: ${targetRun.conclusion}.`;
      }
    }

    return {
      ok: isSuccess,
      runId: targetRun.id,
      runNumber: targetRun.run_number,
      runUrl: targetRun.html_url,
      status: targetRun.status,
      conclusion: targetRun.conclusion,
      errorLog: errorLog || (isSuccess ? '' : `Workflow failed: ${targetRun.conclusion}`),
      durationMs: Date.now() - startTime.getTime()
    };
  }
}

