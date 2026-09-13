const marker = 'crumb-release-build';

function shellQuote(value) {
  return `'${value.replaceAll("'", "'\\''")}'`;
}

function configureXcodeProject(project) {
  let found = false;
  for (const phase of Object.values(
    project.hash.project.objects.PBXShellScriptBuildPhase || {}
  )) {
    if (!phase || typeof phase.shellScript !== 'string') continue;
    // Expo mods can supply literal control characters inside the quoted PBX value.
    const original = phase.shellScript.startsWith('"')
      ? JSON.parse(
          phase.shellScript
            .replaceAll('\n', '\\n')
            .replaceAll('\r', '\\r')
            .replaceAll('\t', '\\t')
        )
      : phase.shellScript;
    if (original.includes(marker)) {
      found = true;
      continue;
    }
    if (!original.includes('react-native-xcode.sh')) continue;
    const wrapper = `# ${marker}
set -e
if [ -f "$PODS_ROOT/../.xcode.env" ]; then . "$PODS_ROOT/../.xcode.env"; fi
if [ -f "$PODS_ROOT/../.xcode.env.local" ]; then . "$PODS_ROOT/../.xcode.env.local"; fi
NODE_BINARY="\${NODE_BINARY:-node}"
CRUMB_PACKAGE_DIR="$("$NODE_BINARY" --print "require('path').dirname(require.resolve('@crumbsdk/react-native/package.json'))")"
"$NODE_BINARY" "$CRUMB_PACKAGE_DIR/tools/ios.cjs" /bin/bash -c ${shellQuote(original)}
`;
    phase.shellScript = JSON.stringify(wrapper);
    // The original native script and the wrapper own their incremental outputs.
    phase.alwaysOutOfDate = 1;
    found = true;
  }
  if (!found)
    throw new Error(
      'Crumb could not locate the React Native Xcode bundle phase. See the manual build-hook instructions.'
    );
  return project;
}

function configureGradle(contents) {
  if (contents.includes(marker)) return contents;
  return `${contents}\n// ${marker}\napply from: new File(["node", "--print", "require.resolve('@crumbsdk/react-native/package.json')"].execute(null, rootDir).text.trim()).parentFile.toPath().resolve("tools/crumb.gradle").toFile()\n`;
}

module.exports = { configureXcodeProject, configureGradle };
