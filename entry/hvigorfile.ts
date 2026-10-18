import * as fs from 'fs';
import * as path from 'path';
import { execFileSync } from 'child_process';
import { hapTasks, OhosHapContext, OhosPluginId, Target } from '@ohos/hvigor-ohos-plugin';
import { HvigorNode, HvigorPlugin } from '@ohos/hvigor';

// 由 scripts/stage-runtime.sh 生成；hvigor 自己不会把它们打进 HAP
const EXECUTABLES: string[] = ['libs/arm64-v8a/node'];

function listHnp(moduleDir: string): string[] {
  const hnpDir = path.join(moduleDir, 'hnp');
  if (!fs.existsSync(hnpDir)) {
    return [];
  }
  return fs.readdirSync(hnpDir, { recursive: true }).map(String).filter((f) => f.endsWith('.hnp'));
}

/**
 * 在 PackageHap 之后、PackingCheck/SignHap 之前，把 hvigor 不处理的运行时文件补进未签名 HAP：
 *  - libs/arm64-v8a/node：module.json5 的 executableBinaryPaths 声明的可执行文件。hvigor 只收 libs 下的 .so，
 *    所以单独注入（compressNativeLibs=true，用 deflate 压缩）。
 *  - hnp/arm64-v8a/*.hnp：module.json5 的 hnpPackages（app_packing_tool 支持 --hnp-path，但 hvigor 不传），原样存储。
 * 之后的 SignHap 会用 hap-sign-tool 对 libs/ 下所有条目和 HNP 内的 ELF 一并做代码签名。
 */
function runtimeInjectPlugin(): HvigorPlugin {
  return {
    pluginId: 'kimiRuntimeInject',
    apply(node: HvigorNode) {
      const hapContext = node.getContext(OhosPluginId.OHOS_HAP_PLUGIN) as OhosHapContext;
      const moduleDir = node.getNodePath();
      hapContext?.targets((target: Target) => {
        const targetName = target.getTargetName();
        node.registerTask({
          name: `${targetName}@InjectRuntime`,
          dependencies: [`${targetName}@PackageHap`],
          postDependencies: [`${targetName}@PackingCheck`, `${targetName}@SignHap`],
          run: () => {
            const missing = EXECUTABLES.filter((f) => !fs.existsSync(path.join(moduleDir, f)));
            const packages = listHnp(moduleDir);
            if (missing.length > 0 || packages.length === 0) {
              throw new Error(`运行时文件缺失（${missing.join(', ') || 'hnp/*.hnp'}），` +
                '请先运行 scripts/fetch-deps.sh && scripts/stage-runtime.sh');
            }
            const outDir = target.getBuildTargetOutputPath();
            const unsigned = fs.readdirSync(outDir).filter((f) => f.endsWith('-unsigned.hap'));
            if (unsigned.length !== 1) {
              throw new Error(`在 ${outDir} 找不到唯一的未签名 HAP（${unsigned.join(', ')}）`);
            }
            const hapPath = path.join(outDir, unsigned[0]);
            execFileSync('zip', ['-6', '-q', '-X', hapPath, ...EXECUTABLES], { cwd: moduleDir });
            execFileSync('zip', ['-0', '-r', '-q', '-X', '-D', hapPath, 'hnp', '-x', '*.DS_Store'], { cwd: moduleDir });
            console.log(`InjectRuntime: ${[...EXECUTABLES, ...packages.map((p) => `hnp/${p}`)].join(', ')}` +
              ` -> ${path.relative(moduleDir, hapPath)}`);
          }
        });
      });
    }
  };
}

export default {
  system: hapTasks, /* Built-in plugin of Hvigor. It cannot be modified. */
  plugins: [runtimeInjectPlugin()]
};
