import * as fs from 'fs';
import * as path from 'path';
import { appTasks, OhosAppContext, OhosPluginId } from '@ohos/hvigor-ohos-plugin';
import { HvigorNode, HvigorPlugin } from '@ohos/hvigor';

/**
 * 把本机签名配置（signing/<product>.local.json，不入库）注入 build-profile 的 signingConfigs。
 * 文件由 scripts/setup-signing.sh 从 `devecocli signature generate` 的结果中提取，内容与
 * build-profile.json5 里的 signingConfigs 元素同构：{ name, type, material: {...} }。
 * 找不到文件时保持为空，hvigor 只产出未签名 HAP。
 */
function localSigningPlugin(): HvigorPlugin {
  return {
    pluginId: 'kimiLocalSigning',
    apply(node: HvigorNode) {
      const appContext = node.getContext(OhosPluginId.OHOS_APP_PLUGIN) as OhosAppContext;
      const signingDir = path.join(node.getNodePath(), 'signing');
      if (!fs.existsSync(signingDir)) {
        return;
      }
      const configs = fs.readdirSync(signingDir)
        .filter((file) => file.endsWith('.local.json'))
        .map((file) => JSON.parse(fs.readFileSync(path.join(signingDir, file), 'utf-8')));
      if (configs.length === 0) {
        return;
      }
      const buildProfileOpt = appContext.getBuildProfileOpt();
      buildProfileOpt.app.signingConfigs = configs;
      appContext.setBuildProfileOpt(buildProfileOpt);
    }
  };
}

export default {
  system: appTasks, /* Built-in plugin of Hvigor. It cannot be modified. */
  plugins: [localSigningPlugin()]
};
