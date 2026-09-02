#!/usr/bin/env node
/**
 * dsh-recover — wrapper around the dsh CLI that auto-disables failing
 * third-party plugins by patching cordis.patch.yml and retrying.
 *
 * When dsh exits with a non-zero code during plugin loading, this wrapper
 * parses the error for `failed to import loader entry <id> (<name>)`
 * patterns, writes a `disabled: true` patch row for each third-party
 * plugin (skipping @deepseek-ai/* and cordis:* builtins) into the
 * profile's cordis.patch.yml, and retries up to DSH_RECOVER_MAX times.
 *
 * Environment:
 *   DSH_BIN          — path to the dsh bin.js (default /app/apps/cli/lib/bin.js)
 *   DSH_RECOVER_MAX  — max retry attempts (default 5)
 *   DSH_HOME         — dsh home for profile discovery
 *
 * Usage: node dsh-recover.js [dsh args...]
 */

import { spawn } from 'node:child_process';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { createRequire } from 'node:module';

// Resolve js-yaml: try the script's own node_modules tree first (container),
// then fall back to the app's node_modules (dev/test from workspace).
function loadYaml() {
  try { return createRequire(import.meta.url)('js-yaml'); } catch {}
  try { return createRequire('/app/package.json')('js-yaml'); } catch (e) {
    throw new Error('dsh-recover: js-yaml not found: ' + e.message);
  }
}
const yaml = loadYaml();

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const DSH_BIN = process.env.DSH_BIN || '/app/apps/cli/lib/bin.js';
const MAX_RETRIES = parseInt(process.env.DSH_RECOVER_MAX, 10) || 5;

// ---------------------------------------------------------------------------
// YAML schema — matches the entry-list dialect used by cordis-plugin-include
// so !!js expression nodes round-trip correctly when reading existing patches.
// ---------------------------------------------------------------------------

const JsExpr = new yaml.Type('tag:yaml.org,2002:js', {
  kind: 'scalar',
  resolve: (data) => typeof data === 'string',
  construct: (data) => ({ __jsExpr: data }),
  predicate: (data) => data instanceof Object && '__jsExpr' in data,
  represent: (data) => data['__jsExpr'],
});

const entryListSchema = yaml.JSON_SCHEMA.extend(JsExpr);

// ---------------------------------------------------------------------------
// Error parsing
// ---------------------------------------------------------------------------

/**
 * Scan stderr for `failed to import loader entry <id> (<name>)` patterns.
 * Returns an array of { id, name } for third-party plugins only (skips
 * @deepseek-ai/* and cordis:* builtins).
 */
function parseFailingPlugins(stderr) {
  const plugins = [];
  const re = /failed to import loader entry (\S+) \(([^)]+)\)/g;
  let match;
  while ((match = re.exec(stderr)) !== null) {
    const id = match[1];
    const name = match[2];
    // Skip official DSH plugins and cordis builtins
    if (name.startsWith('@deepseek-ai/') || name.startsWith('cordis:')) continue;
    // Skip entries that look like file paths (relative imports)
    if (name.startsWith('./') || name.startsWith('../')) continue;
    plugins.push({ id, name });
  }
  return plugins;
}

// ---------------------------------------------------------------------------
// Profile / patch-path resolution
// ---------------------------------------------------------------------------

/** Extract the profile name from dsh CLI args. */
function extractProfileName(args) {
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--profile' && i + 1 < args.length) return args[i + 1];
    if (['web', 'headless', 'tui'].includes(args[i])) return args[i];
  }
  return 'web';
}

/** Resolve cordis.patch.yml path for a profile. */
function getPatchPath(profileName) {
  const home = process.env.DSH_HOME || '/home/dsh/.dsh';
  return join(home, 'profiles', profileName, 'cordis.patch.yml');
}

// ---------------------------------------------------------------------------
// Patch file manipulation
// ---------------------------------------------------------------------------

/** Read the existing patch list from cordis.patch.yml. */
function readPatches(patchPath) {
  if (!existsSync(patchPath)) return [];
  try {
    const content = readFileSync(patchPath, 'utf8');
    const data = yaml.load(content, { schema: entryListSchema });
    return Array.isArray(data) ? data : [];
  } catch {
    // If the file is unreadable or invalid, treat as empty — we will
    // create a fresh one on write.
    return [];
  }
}

/** Write the patch list back to cordis.patch.yml. */
function writePatches(patchPath, patches) {
  const content = yaml.dump(patches, {
    schema: entryListSchema,
    lineWidth: -1,
    sortKeys: false,
  });
  writeFileSync(patchPath, content.endsWith('\n') ? content : content + '\n', 'utf8');
}

/**
 * Ensure a plugin is disabled in the patch file.
 * Returns true if the file was modified.
 */
function disablePluginInPatch(patchPath, pluginId) {
  const patches = readPatches(patchPath);

  // Check if already present
  const existing = patches.find((p) => p.id === pluginId);
  if (existing) {
    if (existing.disabled) return false; // already disabled, no change
    existing.disabled = true;
    writePatches(patchPath, patches);
    return true;
  }

  // Add a new entry — append to the end, matching the user-layer convention
  // where commented-out entries above act as a template.
  patches.push({ id: pluginId, disabled: true });
  writePatches(patchPath, patches);
  return true;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const args = process.argv.slice(2);
  const profileName = extractProfileName(args);
  const patchPath = getPatchPath(profileName);

  // The current child process, updated each attempt so signal handlers
  // always forward to the right target.
  let child = null;
  let settled = false;

  // Forward SIGTERM/SIGINT to the child dsh process, then exit.
  const forwardSignal = (sig, exitCode) => {
    if (!settled && child) child.kill(sig);
    process.exit(exitCode);
  };
  process.on('SIGTERM', () => forwardSignal('SIGTERM', 0));
  process.on('SIGINT', () => forwardSignal('SIGINT', 130));

  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    let stderr = '';

    const exitCode = await new Promise((resolve) => {
      child = spawn('node', [DSH_BIN, ...args], {
        stdio: ['inherit', 'inherit', 'pipe'], // pipe stderr only
        env: { ...process.env },
      });

      child.stderr.on('data', (data) => {
        process.stderr.write(data); // forward to parent stderr in real-time
        stderr += data.toString();
      });

      child.on('close', (code) => { settled = true; resolve(code ?? 1); });
      child.on('error', () => { settled = true; resolve(1); });
    });

    // ── Success ──
    if (exitCode === 0) process.exit(0);

    // ── Failure — try to recover ──
    if (attempt >= MAX_RETRIES) {
      process.stderr.write(`\ndsh-recover: giving up after ${MAX_RETRIES} retries\n`);
      process.exit(exitCode);
    }

    const failing = parseFailingPlugins(stderr);
    if (failing.length === 0) {
      process.stderr.write(`\ndsh-recover: no recoverable plugin import error found, exiting\n`);
      process.exit(exitCode);
    }

    process.stderr.write(`\ndsh-recover: attempt ${attempt + 1}/${MAX_RETRIES} —\n`);
    for (const { id, name } of failing) {
      const changed = disablePluginInPatch(patchPath, id);
      process.stderr.write(
        changed
          ? `  disabled plugin "${id}" (${name}) in ${patchPath}\n`
          : `  plugin "${id}" (${name}) already disabled, no change\n`,
      );
    }
    process.stderr.write(`dsh-recover: patched ${patchPath}, retrying...\n`);
  }
}

main().catch((err) => {
  process.stderr.write(`dsh-recover: fatal: ${err}\n`);
  process.exit(1);
});
