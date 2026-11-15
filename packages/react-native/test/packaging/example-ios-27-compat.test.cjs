const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { dirname, join } = require('node:path');
const { test } = require('node:test');
const {
  adoptSceneLifeCycle,
  raisePodDeploymentTargets,
} = require('../../example/with-ios-27-compat.js');

// Read the files `expo prebuild` starts from, out of the Expo version the
// example pins, so an Expo upgrade that changes them fails here first.
const example = join(__dirname, '../../example');
const template = join(
  dirname(require.resolve('expo/package.json', { paths: [example] })),
  'template.tgz'
);
function templateFile(path) {
  return execFileSync('tar', ['-xOzf', template, `package/ios/${path}`], {
    encoding: 'utf8',
  });
}

test('the app delegate hands the window and React Native start to a scene delegate', () => {
  const input = templateFile('HelloWorld/AppDelegate.swift');
  const output = adoptSceneLifeCycle(input);

  const [appDelegate, sceneDelegate] = output.split('class SceneDelegate');
  assert.ok(!appDelegate.includes('startReactNative'));
  assert.ok(!appDelegate.includes('UIWindow('));
  assert.match(sceneDelegate, /UIWindow\(windowScene: windowScene\)/);
  assert.match(sceneDelegate, /withModuleName: "main"/);
  // A link that starts the app must still reach the app delegate's subscribers.
  assert.match(sceneDelegate, /open\(connectionOptions\.urlContexts\)/);
  // The template's linking overrides stay, because the scene delegate calls them.
  assert.equal(appDelegate.match(/RCTLinkingManager\.application/g).length, 2);
  assert.equal(adoptSceneLifeCycle(output), output);
});

test('pod targets below the Xcode 27 minimum are raised inside post_install', () => {
  const input = templateFile('Podfile');
  const output = raisePodDeploymentTargets(input);

  const hook = output.indexOf('post_install do |installer|');
  const raise = output.indexOf("Gem::Version.new('15.0')");
  assert.ok(hook !== -1 && raise > hook);
  assert.ok(raise < output.indexOf('react_native_post_install('));
  assert.equal(raisePodDeploymentTargets(output), output);
});

test('an unrecognized template fails instead of generating a broken project', () => {
  assert.throws(
    () => adoptSceneLifeCycle('class AppDelegate {}'),
    /template changed/
  );
  assert.throws(
    () => raisePodDeploymentTargets("target 'Example' do\nend\n"),
    /template changed/
  );
});
