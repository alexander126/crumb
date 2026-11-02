// Read class definitions and declared direct methods, never string references.
export async function inspectDexDump(lines, descriptor) {
  let classFound = false;
  let defaultConstructorFound = false;
  let inClass = false;
  let inDirectMethods = false;
  let name;
  let type;

  for await (const line of lines) {
    if (/^Class #\d+\s+-/.test(line)) {
      inClass = false;
      inDirectMethods = false;
      name = undefined;
      type = undefined;
    }
    const definition = line.match(/^\s+Class descriptor\s+: '([^']+)'/);
    if (definition) {
      inClass = definition[1] === descriptor;
      if (inClass) classFound = true;
    }
    if (!inClass) continue;
    if (/^\s+Direct methods\s+-/.test(line)) inDirectMethods = true;
    if (/^\s+Virtual methods\s+-/.test(line)) inDirectMethods = false;
    if (!inDirectMethods) continue;
    if (/^ {4}#\d+\s+:/.test(line)) {
      name = undefined;
      type = undefined;
    }
    const methodName = line.match(/^\s+name\s+: '([^']+)'/);
    if (methodName) name = methodName[1];
    const methodType = line.match(/^\s+type\s+: '([^']+)'/);
    if (methodType) type = methodType[1];
    const access = line.match(/^\s+access\s+: 0x([0-9a-f]+)/i);
    if (access && name === '<init>' && type === '()V') {
      const flags = Number.parseInt(access[1], 16);
      if ((flags & 0x0001) !== 0 && (flags & 0x0008) === 0) {
        defaultConstructorFound = true;
      }
    }
  }
  return { classFound, defaultConstructorFound };
}
