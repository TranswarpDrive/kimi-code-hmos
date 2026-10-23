const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const ts = require('typescript');

// 只替换平台 API；测试执行项目中的实际 ArkTS 业务代码。完整类型检查由 hvigor 构建承担。
module.exports = function loadEts(name, modules = {}, globals = {}) {
  const file = path.resolve(__dirname, '../entry/src/main/ets', name);
  const source = fs.readFileSync(file, 'utf8');
  const js = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 }
  }).outputText;
  const exported = {};
  vm.runInNewContext(js, {
    exports: exported,
    require: id => {
      if (!(id in modules)) throw new Error(`Missing test platform adapter: ${id}`);
      return modules[id];
    },
    setTimeout, clearTimeout, setInterval, clearInterval, console,
    ArrayBuffer, Uint8Array, Date, ...globals
  }, { filename: file });
  return exported;
};
