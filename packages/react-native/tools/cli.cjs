#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');
const { parseArgs } = require('node:util');
const { createInterface } = require('node:readline/promises');
const { setupPlan, applyPlan, doctor } = require('./setup.cjs');
const { prepareRelease } = require('./release.cjs');
const { uploadRelease, retryUpload } = require('./upload.cjs');

async function main() {
  if (Number(process.versions.node.split('.')[0]) < 22)
    throw new Error('Crumb build tooling requires Node.js 22 or newer.');
  const { positionals, values } = parseArgs({
    allowPositionals: true,
    options: {
      help: { type: 'boolean' },
      apply: { type: 'boolean' },
      'source-maps': { type: 'boolean' },
      'upload-url': { type: 'string' },
      root: { type: 'string' },
      directory: { type: 'string' },
      input: { type: 'string' },
      receipt: { type: 'string' },
      output: { type: 'string' },
      targets: { type: 'string' },
      'dry-run': { type: 'boolean' },
    },
  });
  const root = path.resolve(values.root || process.cwd());
  const [command] = positionals;
  if (values.help || !command) {
    console.log(
      'crumb setup [--source-maps --upload-url HTTPS_ORIGIN] [--apply]\ncrumb doctor\ncrumb retry --receipt FILE\ncrumb export --output DIRECTORY --targets FILE [--dry-run]\n\nSetup previews changes; --apply accepts them without prompting. Upload credentials belong only in CRUMB_SOURCE_MAP_TOKEN.'
    );
    return;
  }
  if (command === 'setup') {
    let sourceMaps = values['source-maps'];
    let uploadUrl = values['upload-url'];
    const prompt =
      process.stdin.isTTY && !values.apply
        ? createInterface({ input: process.stdin, output: process.stdout })
        : undefined;
    try {
      if (prompt && sourceMaps === undefined)
        sourceMaps = /^y(es)?$/i.test(
          await prompt.question(
            'Configure source maps for opt-in JavaScript crashes? [y/N] '
          )
        );
      if (prompt && sourceMaps && !uploadUrl)
        uploadUrl = await prompt.question(
          'Upload origin from your Crumb integration page: '
        );
      const plan = setupPlan(root, { sourceMaps, uploadUrl });
      console.log(`Crumb setup: ${plan.framework}`);
      for (const change of plan.changes)
        console.log(
          `- ${change.before === undefined ? 'Create' : 'Update'} ${change.name}`
        );
      console.log(
        'Setup adds Crumb configuration, preserves existing settings, and wraps supported build hooks. Review the resulting diff before committing.'
      );
      if (
        values.apply ||
        (prompt &&
          /^y(es)?$/i.test(
            await prompt.question(
              `Apply ${plan.changes.length} reviewed file changes? [y/N] `
            )
          ))
      ) {
        applyPlan(plan);
        console.log('Setup changes applied.');
      } else
        console.log(
          'Preview only. Run again with --apply to apply these changes.'
        );
      for (const instruction of plan.instructions)
        console.log(`- ${instruction}`);
    } finally {
      prompt?.close();
    }
  } else if (command === 'doctor') {
    const result = doctor(root);
    console.log(JSON.stringify(result, null, 2));
    if (result.checks.some((check) => check.status === 'missing'))
      process.exitCode = 1;
  } else if (command === 'prepare' && values.directory) {
    prepareRelease(path.resolve(values.directory));
  } else if (command === 'upload-build' && values.input) {
    uploadRelease(JSON.parse(fs.readFileSync(values.input, 'utf8')), {
      dryRun: values['dry-run'],
    });
  } else if (command === 'export' && values.output && values.targets) {
    require('./expo-export.cjs').exportRelease(
      root,
      values.output,
      values.targets,
      { dryRun: values['dry-run'] }
    );
  } else if (command === 'retry' && values.receipt) {
    retryUpload(values.receipt);
  } else
    throw new Error('Unknown or incomplete Crumb command. Run crumb --help.');
}

main().catch((error) => {
  const message =
    error instanceof SyntaxError ||
    String(error.code).startsWith('ERR_PARSE_ARGS')
      ? 'Invalid command or JSON input. Run crumb --help; keep credentials only in the build environment.'
      : error.message;
  console.error(`Crumb: ${message}`);
  process.exitCode = 1;
});
