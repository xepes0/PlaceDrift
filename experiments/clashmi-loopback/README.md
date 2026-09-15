# Clash Mi 1.0.28.1406：10.7.0.1 loopback PoC

先验证 **Clash Mi 单独开启时，现有本机客户端能否通过 10.7.0.1 完成原先依赖 LocalDevVPN 的操作**。本目录提供可导入的配置；尚未完成真机验证。只涉及 `xepes0/WLOC-CoreDevice-Lab`。

## 下载与选择

| 文件 | 导入位置 | 用途 |
| --- | --- | --- |
| [loopback.js](loopback.js) | 核心设置 → 覆写；类型 `js` | 推荐用于现有订阅。只改 TUN 的四个开关/栈字段，追加 10.7.0.1，保留其他字段和已有 loopback 地址 |
| [loopback.patch.yaml](loopback.patch.yaml) | 核心设置 → 覆写；类型 `yaml` | 最小原生 YAML 覆写，loopback 列表仅指定 10.7.0.1 |
| [system.yaml](system.yaml) | 配置 → 添加配置 → 从文件导入/URL | 独立、全直连基线，无机场订阅依赖；首次排障推荐 |
| [gvisor.yaml](gvisor.yaml)、[mixed.yaml](mixed.yaml) | 普通配置 | 保留的替代栈实验；先完成 system 基线再逐项比较 |

在 GitHub 打开文件后点 **Raw**，复制原始内容 URL；也可以下载到 iPhone“文件”后导入。不要复制 GitHub `blob` 网页地址。覆写片段不等于完整订阅，不能放到普通“添加配置”入口；`.clash` 备份也不是本实验的导入格式。

本 PoC 的分支直链（无需合并即可测试）：

- [JS 覆写原始文件](https://raw.githubusercontent.com/xepes0/WLOC-CoreDevice-Lab/codex/clashmi-loopback-poc/experiments/clashmi-loopback/loopback.js)
- [YAML 覆写原始文件](https://raw.githubusercontent.com/xepes0/WLOC-CoreDevice-Lab/codex/clashmi-loopback-poc/experiments/clashmi-loopback/loopback.patch.yaml)
- [独立 system 配置原始文件](https://raw.githubusercontent.com/xepes0/WLOC-CoreDevice-Lab/codex/clashmi-loopback-poc/experiments/clashmi-loopback/system.yaml)

长期复现实验可把 URL 中分支名替换为测试时的 commit SHA，避免后续更新影响结果。

## 最小配置内容

```yaml
tun:
  enable: true
  stack: system
  auto-route: true
  auto-detect-interface: true
  loopback-address:
    - 10.7.0.1
```

不额外加入 DNS 劫持、DIRECT 规则、监听端口、证书或描述文件。JS 会保留原订阅的 DNS、节点、规则、TUN 路由及其他字段；因此原有排除路由仍可能影响实验。YAML 路径交给 Libclash 合并，不承诺数组追加或所有嵌套字段的保留语义，现有复杂订阅优先用 JS。

## 1. 导入和启用

先记下当前配置、当前覆写和 TUN 设置，方便恢复。保留原配置，使用测试副本。

### A. 在现有订阅上使用 JS（推荐的覆写路径）

1. 打开 **核心设置 → 覆写 → 添加**，通过文件或 URL 导入 `loopback.js`，命名为 `WLOC Loopback system`。
2. **明确将类型设成 `js`**。1.0.28.1406 的 URL 添加界面默认类型是 `yaml`，不要依赖扩展名自动识别。
3. 覆写条目右侧菜单 → 编辑配置：确认类型，并把 **追加覆写** 设为 **内置-不覆写**，保存。
4. **配置 → 目标订阅右侧菜单 → 编辑配置 → 核心覆写**，选择这个自定义覆写，保存。仅导入文件不代表当前订阅已使用它。
5. **核心设置 → TUN → 关闭“开启覆写”**，让本文件提供 TUN 配置。这里只关闭 App 对 TUN 的覆写，不是关闭文件里的 `tun.enable`。记录修改前设置。
6. 断开再连接 Clash Mi，检查启动日志是否有脚本/YAML/TUN 错误。

YAML 覆写路径相同，只需选 `loopback.patch.yaml`、类型 `yaml`，不要同时叠加两个版本。若原订阅已有自定义覆写，选择本 PoC 会替换该覆写的绑定；在副本上实验，结束后恢复原绑定。

### B. 独立配置（隔离订阅影响）

1. 从普通“配置 → 添加配置”导入 `system.yaml`，命名为 `WLOC Loopback standalone`。
2. 此配置的 **核心覆写** 选择 **内置-不覆写**；同时按 A 第 5 步关闭 TUN 的“开启覆写”。
3. 把 App 模式设为 **规则 / Rule**，连接此配置。所有流量按 `MATCH,DIRECT` 直连，测试期间不提供机场代理。

“内置-不覆写”不是跳过 App 的所有处理：源码仍保留模式、端口、TUN 等必要设置。因此 **追加覆写 + TUN 覆写开关 + 最终配置** 三项都要核对。

## 2. 确认配置实际生效

在 App 能查看/导出的运行配置中，检查上述五项。订阅原文或覆写文件的“查看”只说明源文件内容正确，不能证明最终配置已加载。若此版本 UI 只能显示源配置，记录“最终配置不可获取”，不要把它当成已确认。

有最终配置文件时，可在电脑离线检查（不要上传含订阅/密钥的配置）：

```sh
cd experiments/clashmi-loopback
npm ci --ignore-scripts
node check.mjs --effective /path/to/final-config.yaml
```

脚本只检查所需字段和 YAML 格式，不连接设备、不扫描端口、不输出配置内容。检查通过不代表 iOS 路由已生效。若失败，先排除覆写绑定、类型、TUN 内置覆写和重连问题。

## 3. 真机 A/B 测试

固定同一台 iPhone、同一 iOS 版本、同一网络、同一客户端和同一操作。关闭其他 VPN 的自动连接，避免客户端启动时自动切回 LocalDevVPN；每一步都核对系统当前 VPN。

1. **正对照：LocalDevVPN。** 关闭 Clash Mi，开启 LocalDevVPN。用已经配置好的客户端执行一次已知成功的本机操作，例如 SideStore 刷新某个现有 App，记录时间和结果。若测试 RemotePairing，使用已有原生客户端及其实际发现的服务端口，固定已有配对状态。
2. **负对照：两者均关闭。** 完全关闭并重新打开客户端，重复同一操作，记录是否失败。避免复用旧连接/缓存；如果仍成功，当前操作不足以区分这条 VPN 路径。
3. **实验组：只开 Clash Mi 1.0.28.1406。** 先用独立 `system.yaml`，确认 LocalDevVPN 未启动；重新打开客户端，重复完全相同操作两次。
4. **恢复正对照。** 若实验组失败，切回 LocalDevVPN 再重复一次。正对照也失败时，不能把原因归给 Clash Mi。
5. 独立配置成功后，再用现有订阅 + JS 覆写重复测试。若只有订阅版失败，检查其 TUN `route-address` / `route-exclude-address`（含旧 `inet4-*` 写法）、排除规则，以及 iOS `excludeLocalNetworks` 等设置是否绕过 10.7.0.1。先记录差异，再一次只改一个变量。

### 什么算成功

| 现象 | 可以得出的结论 |
| --- | --- |
| YAML 校验通过 / VPN 图标出现 | 配置检查或隧道启动成功，不能证明 loopback |
| 浏览器访问 `http://10.7.0.1` 失败 / ping 失败 | 不足以判断；目标未必运行 HTTP/ICMP 服务 |
| 正对照成功、负对照失败、Clash Mi 组重复成功 | 支持该客户端在本设备上以 Clash Mi 替代 LocalDevVPN 的传输用途 |
| SideStore 操作成功 | 该工作流可用；不能直接推导 RemotePairing、DVT 或系统定位成功 |
| 原生客户端向 10.7.0.1 的实际 RemotePairing 端口完成协议握手 | 更强的 CoreDevice 传输证据，仍需单独验证后续定位链路 |
| 正对照成功、Clash Mi 组失败，且最终字段正确 | 此测试组合未通过；记录路由/客户端错误，不直接断言内核回归 |

RemotePairing 端口不得猜测为固定值；没有原生客户端、服务端口和配对前提时，本轮只做已有工作流的 A/B。这个覆写不会创建 CoreDevice 客户端、Bonjour 服务或定位接口。仓库 `ios-probe` 会开启另一个 VPN，不能与 Clash Mi 同时开启来当作它的探针。

## 4. 回报模板及回退

```text
日期 / 网络（Wi-Fi 或蜂窝）：
iPhone 型号 / iOS 完整版本：
Clash Mi：1.0.28.1406；App 显示的内核版本：
PoC commit / 文件：
当前配置及绑定覆写 / 类型 / 追加覆写：
TUN 开启覆写是否已关闭：
最终配置五项检查（或不可获取）：
客户端及版本 / 相同测试操作：
LocalDevVPN 正对照：
两者关闭负对照：
Clash Mi 实验第 1 次 / 第 2 次：
恢复 LocalDevVPN 正对照：
错误时间 / 去敏后的具体错误：
```

回退：断开 Clash Mi → 选择原配置 → 恢复原覆写绑定、TUN 设置和模式 → 重连。需要时停用 Clash Mi，再开启 LocalDevVPN。无需删除配对记录或重装客户端。不要在 GitHub 提交配对文件、AltIRK、token、设备标识或完整诊断日志。

## 格式研究依据（2026-09-15）

- 核对目标 tag [`v1.0.28.1406`，commit `6c49baa`](https://github.com/KaringX/clashmi/tree/6c49baa787d3b5f426990c284abe2a041f7afbc2)：[`profile_patch_manager.dart`](https://github.com/KaringX/clashmi/blob/6c49baa787d3b5f426990c284abe2a041f7afbc2/lib/app/modules/profile_patch_manager.dart) 定义 `yaml` / `js`，支持 `.yaml/.yml/.js` 文件，JS 调用 `main(config)` 并使用返回结果。
- [`vpn_service.dart`](https://github.com/KaringX/clashmi/blob/6c49baa787d3b5f426990c284abe2a041f7afbc2/lib/app/local_services/vpn_service.dart) 的 `_prepareConfig`：YAML 传入 `core_path_patch`，JS 先生成配置，两者均有 `core_path_patch_final`。
- [`profile_patch_settings_edit_screen.dart`](https://github.com/KaringX/clashmi/blob/6c49baa787d3b5f426990c284abe2a041f7afbc2/lib/screens/profile_patch_settings_edit_screen.dart) 提供类型及“追加覆写”；[`clash_setting_manager.dart`](https://github.com/KaringX/clashmi/blob/6c49baa787d3b5f426990c284abe2a041f7afbc2/lib/app/modules/clash_setting_manager.dart) 的 `defaultConfigNoOverwrite` 仍携带 TUN。
- 同时对比当前 `main` [`4a82610`](https://github.com/KaringX/clashmi/tree/4a826101cd6a6f92c471b1ae658cf5e0821b1025)，上述格式和执行路径未改变。官方 [FAQ 的覆写顺序](https://clashmi.app/guide/faq) 与源码一致。这里的“模块”采用官方已有的自定义覆写入口，不使用 Surge/Loon 模块语法，也不编造配置 API。
- Mihomo [`v1.19.29 config.go`](https://github.com/MetaCubeX/mihomo/blob/e26714a181ac0e2fa803453c0a8e9a9ce94e31cb/config/config.go) 包含 `loopback-address` 地址列表；[`listener/sing_tun/server.go`](https://github.com/MetaCubeX/mihomo/blob/e26714a181ac0e2fa803453c0a8e9a9ce94e31cb/listener/sing_tun/server.go) 将其传给 IPv4/IPv6 loopback 参数。这证明配置字段和传参存在，不证明 App 二进制或真机行为。

## 开发校验与限制

```sh
cd experiments/clashmi-loopback
npm ci --ignore-scripts
npm run check
npm test
```

CI 运行 YAML 解析/字段校验、JS 入口、字段保留、重复执行、错误输入及最终配置被覆盖的检测。使用 Node 的隔离执行环境模拟 `main(config)`，没有执行 iOS Flutter JS 引擎、Libclash YAML 合并或 iOS PacketTunnel。尚未运行真机 A/B；CI 绿色只表示这些静态及脚本测试通过。

如果已有可信 Mihomo 二进制，可另做 `mihomo -t -f experiments/clashmi-loopback/system.yaml` 配置检查；也不能代替真机验证。当前阶段不需要定制 App、CoreDevice 引擎或描述文件。
