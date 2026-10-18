import * as fs from 'fs';
import * as path from 'path';
import { execFileSync } from 'child_process';
import { hapTasks, OhosHapContext, OhosPluginId, Target } from '@ohos/hvigor-ohos-plugin';
import { HvigorNode, HvigorPlugin } from '@ohos/hvigor';

// 由 scripts/stage-runtime.sh 生成；hvigor 自己不会把它们打进 HAP
const EXECUTABLES: string[] = ['libs/arm64-v8a/node'];
// 由 scripts/stage-runtime.sh 生成的 kimi-code 包，路径同时也是它在 HAP 中的条目前缀
const RESFILE_DIR: string = 'resources/resfile/kimicode';

/**
 * 在 PackageHap 之后、PackingCheck/SignHap 之前，把 module.json5 的 executableBinaryPaths 声明的可执行文件
 * （libs/arm64-v8a/node）补进未签名 HAP：hvigor 只收 libs 下的 .so，官方的 collectAllLibs 方案又会 strip 掉
 * node 的 .permission 节，所以原样注入（compressNativeLibs=true，用 deflate 压缩）。
 * 之后的 SignHap（或接收方的重签工具）会用 hap-sign-tool 对 libs/ 下所有条目做代码签名。
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
            if (missing.length > 0) {
              throw new Error(`运行时文件缺失（${missing.join(', ')}），请先运行 scripts/fetch-deps.sh && scripts/stage-runtime.sh`);
            }
            const outDir = target.getBuildTargetOutputPath();
            const unsigned = fs.readdirSync(outDir).filter((f) => f.endsWith('-unsigned.hap'));
            if (unsigned.length !== 1) {
              throw new Error(`在 ${outDir} 找不到唯一的未签名 HAP（${unsigned.join(', ')}）`);
            }
            const hapPath = path.join(outDir, unsigned[0]);
            execFileSync('zip', ['-6', '-q', '-X', hapPath, ...EXECUTABLES], { cwd: moduleDir });
            // 打包工具把 resources 下的文件一律不压缩存储；resfile 是安装时整体解压的，改用 deflate 重写这些条目，
            // 让内置的 kimi-code 包（约 53MB JS）在 HAP 里只占约三分之一
            const mainDir = path.join(moduleDir, 'src', 'main');
            if (fs.existsSync(path.join(mainDir, RESFILE_DIR))) {
              execFileSync('zip', ['-q', '-d', hapPath, `${RESFILE_DIR}/*`]);
              execFileSync('zip', ['-6', '-r', '-q', '-X', '-D', hapPath, RESFILE_DIR, '-x', '*.DS_Store'], { cwd: mainDir });
            }
            console.log(`InjectRuntime: ${EXECUTABLES.join(', ')}, ${RESFILE_DIR} (deflate) -> ${path.relative(moduleDir, hapPath)}`);
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
