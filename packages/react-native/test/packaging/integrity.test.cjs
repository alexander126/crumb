const assert = require('node:assert/strict');
const { test } = require('node:test');
const { execFileSync } = require('node:child_process');
const { mkdtempSync, writeFileSync, rmSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join, resolve } = require('node:path');

test('modified upstream archive is rejected before extraction', () => {
  const temporary = mkdtempSync(join(tmpdir(), 'crumb-bad-archive-'));
  try {
    const archive = join(temporary, 'invalid.zip');
    writeFileSync(archive, 'synthetic invalid dependency');
    assert.throws(
      () =>
        execFileSync(process.execPath, ['scripts/prepare-ios.mjs'], {
          cwd: resolve(__dirname, '../..'),
          env: { ...process.env, CRUMB_PLCRASH_ARCHIVE: archive },
          stdio: 'pipe',
        }),
      (error) => error.stderr.toString().includes('checksum mismatch')
    );
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
});
