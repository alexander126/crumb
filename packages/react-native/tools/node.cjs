#!/usr/bin/env node
const { spawnSync } = require('node:child_process');
const { readConfig } = require('./config.cjs');
const [manifest, ...args] = process.argv.slice(2);
if (!manifest || !args.length) {
  console.error(
    'Crumb build wrapper requires release metadata and the original Node command.'
  );
  process.exitCode = 1;
} else {
  const result = spawnSync(process.execPath, [...process.execArgv, ...args], {
    stdio: 'inherit',
    env: {
      ...process.env,
      CRUMB_RELEASE_MANIFEST: readConfig(process.cwd()).sourceMaps.enabled
        ? manifest
        : '',
    },
  });
  process.exitCode = result.status === null ? 1 : result.status;
}
