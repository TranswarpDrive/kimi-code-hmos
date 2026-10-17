// 从 build-profile.json5 中取出 devecocli 写入的签名配置，保存为 signing/<product>.local.json。
// 用法：node scripts/lib/extract-signing.mjs <build-profile.json5> <product> <out.json> <json5 模块目录>
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';

const [profilePath, product, outPath, json5Dir] = process.argv.slice(2);
const require = createRequire(import.meta.url);
const JSON5 = require(json5Dir);

const profile = JSON5.parse(fs.readFileSync(profilePath, 'utf-8'));
const app = profile.app ?? {};
const configName = (app.products ?? []).find((p) => p.name === product)?.signingConfig ?? product;
const config = (app.signingConfigs ?? []).find((c) => c.name === configName);
if (!config || !config.material) {
  console.error(`build-profile.json5 中没有名为 ${configName} 的签名配置`);
  process.exit(1);
}
for (const key of ['certpath', 'profile', 'storeFile']) {
  if (!fs.existsSync(config.material[key])) {
    console.error(`签名材料不存在：${key} = ${config.material[key]}`);
    process.exit(1);
  }
}
fs.mkdirSync(path.dirname(outPath), { recursive: true });
fs.writeFileSync(outPath, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 });
console.log(`签名配置已写入 ${outPath}`);
console.log(`  证书    ${config.material.certpath}`);
console.log(`  Profile ${config.material.profile}`);
