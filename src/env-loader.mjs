import fs from 'node:fs';
import path from 'node:path';

/**
 * Loads key=value pairs from a `.env` file into `process.env` without overriding
 * already-set environment variables.
 */
export function loadDotEnv(envFilePath) {
  let raw;
  try {
    raw = fs.readFileSync(envFilePath, 'utf8');
  } catch {
    return;
  }

  for (const line of raw.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eqIdx = trimmed.indexOf('=');
    if (eqIdx === -1) continue;
    const key = trimmed.slice(0, eqIdx).trim();
    let val = trimmed.slice(eqIdx + 1).trim();
    if (
      (val.startsWith('"') && val.endsWith('"')) ||
      (val.startsWith("'") && val.endsWith("'"))
    ) {
      val = val.slice(1, -1);
    }
    if (key && process.env[key] === undefined) {
      process.env[key] = val;
    }
  }
}

export function loadProjectDotEnv(projectRoot) {
  loadDotEnv(path.join(projectRoot, '.env'));
}

