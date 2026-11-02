import assert from 'node:assert/strict';
import { test } from 'node:test';
import { inspectDexDump } from '../../scripts/android-release-retention.mjs';

const descriptor = 'Lfixture/HybridImplementation;';
const definition = (value = descriptor) => `Class #0            -
  Class descriptor  : '${value}'
  Direct methods    -`;
const method = (name = '<init>', type = '()V', access = '10001') => `
    #0              : (in ${descriptor})
      name          : '${name}'
      type          : '${type}'
      access        : 0x${access} (PUBLIC CONSTRUCTOR)`;
const inspect = (text) => inspectDexDump(text.split('\n'), descriptor);

test('finds the declared public zero-argument constructor', async () => {
  assert.deepEqual(await inspect(definition() + method()), {
    classFound: true,
    defaultConstructorFound: true,
  });
});

test('a descriptor reference in another class is not a class definition', async () => {
  assert.deepEqual(await inspect(definition('Lfixture/Other;') + method()), {
    classFound: false,
    defaultConstructorFound: false,
  });
});

test('rejects missing, argument-taking, private, or static constructors', async () => {
  for (const text of [
    definition(),
    definition() + method('<init>', '(I)V'),
    definition() + method('<init>', '()V', '10002'),
    definition() + method('<init>', '()V', '10009'),
  ]) {
    assert.deepEqual(await inspect(text), {
      classFound: true,
      defaultConstructorFound: false,
    });
  }
});

test('does not borrow a constructor from a neighboring class', async () => {
  assert.deepEqual(
    await inspect(
      definition() + '\n' + definition('Lfixture/Other;') + method()
    ),
    { classFound: true, defaultConstructorFound: false }
  );
});

test('does not combine separate methods or inspect virtual methods', async () => {
  for (const text of [
    definition() + method('<init>', '(I)V') + method('other', '()V'),
    definition() + '\n  Virtual methods   -' + method(),
  ]) {
    assert.deepEqual(await inspect(text), {
      classFound: true,
      defaultConstructorFound: false,
    });
  }
});
