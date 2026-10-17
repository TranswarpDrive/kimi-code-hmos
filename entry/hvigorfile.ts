import * as fs from 'fs';
import * as path from 'path';
import { execFileSync } from 'child_process';
import { hapTasks, OhosHapContext, OhosPluginId, Target } from '@ohos/hvigor-ohos-plugin';
import { HvigorNode, HvigorPlugin } from '@ohos/hvigor';

/**
 * hvigor 不处理 module.json5 里的 hnpPackages（app_packing_tool 支持 --hnp-path，但 hvigor 不传），
 * 所以在 PackageHap 之后、PackingCheck/SignHap 之前，把 entry/hnp/<abi>/*.hnp 以原样（store）加进未签名 HAP。
 * 之后的 SignHap 会用 hap-sign-tool 对 HNP 内的 ELF 一并做代码签名。
 * entry/hnp/ 由 scripts/build-hnp.sh 生成。
 */
function hnpInjectPlugin(): HvigorPlugin {
  return {
    pluginId: 'kimiHnpInject',
    apply(node: HvigorNode) {
      const hapContext = node.getContext(OhosPluginId.OHOS_HAP_PLUGIN) as OhosHapContext;
      const moduleDir = node.getNodePath();
      hapContext?.targets((target: Target) => {
        const targetName = target.getTargetName();
        node.registerTask({
          name: `${targetName}@InjectHnp`,
          dependencies: [`${targetName}@PackageHap`],
          postDependencies: [`${targetName}@PackingCheck`, `${targetName}@SignHap`],
          run: () => {
            const hnpDir = path.join(moduleDir, 'hnp');
            const packages = fs.existsSync(hnpDir)
              ? fs.readdirSync(hnpDir, { recursive: true }).map(String).filter((f) => f.endsWith('.hnp'))
              : [];
            if (packages.length === 0) {
              throw new Error(`${hnpDir} 下没有 .hnp，请先运行 scripts/fetch-deps.sh && scripts/build-hnp.sh`);
            }
            const outDir = target.getBuildTargetOutputPath();
            const unsigned = fs.readdirSync(outDir).filter((f) => f.endsWith('-unsigned.hap'));
            if (unsigned.length !== 1) {
              throw new Error(`在 ${outDir} 找不到唯一的未签名 HAP（${unsigned.join(', ')}）`);
            }
            const hapPath = path.join(outDir, unsigned[0]);
            execFileSync('zip', ['-0', '-r', '-q', '-X', '-D', hapPath, 'hnp', '-x', '*.DS_Store'], { cwd: moduleDir });
            console.log(`InjectHnp: ${packages.join(', ')} -> ${path.relative(moduleDir, hapPath)}`);
          }
        });
      });
    }
  };
}

export default {
  system: hapTasks, /* Built-in plugin of Hvigor. It cannot be modified. */
  plugins: [hnpInjectPlugin()]
};
