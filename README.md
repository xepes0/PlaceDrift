# PlaceDrift

PlaceDrift 是一个面向 **iOS 27+** 的 CoreDevice 虚拟定位工具。它在 iPhone 本机完成 RemotePairing / DVT `LocationSimulation` 链路，并支持从 **Apple 地图、高德地图、百度地图**直接分享地点到 PlaceDrift。

> **Public Beta 1 — 0.2.1 (Build 15)**
>
> 当前版本以“地图 App → 分享 → PlaceDrift”为唯一推荐入口。地图坐标解析全部在本机完成，不依赖 WLOC Worker，也不再提供 Shortcuts 坐标入口或实验性的地图区域切换功能。

## 工作原理

```text
Apple Maps / 高德地图 / 百度地图
  → Share Extension
  → 本地坐标解析与坐标系转换
  → PlaceDrift
  → TUN self-loop 10.7.0.1
  → RemotePairing / Pair Verify
  → TLS-PSK → RSD → DVT
  → LocationSimulation
```

**PlaceDrift 本身不会启动 VPN。** 它需要一个能够把 `10.7.0.1` 正确回环到本机 RemotePairing 服务的 TUN/VPN App。

## 兼容性

### 已实测可用

- **LocalDevVPN**
- **Clash Mi**
- **Clash**
- **Karing**

### 当前实测配置不可用

- **Loon**
- **Surge**
- **Shadowrocket**

这些结果只代表目前已经测试过的配置。PlaceDrift 的状态页不是单纯测试 TCP 端口，而是会向动态 RemotePairing 端口发送真实的 `RPPairing attemptPairVerify` 首帧并等待有效响应；只有协议级检测通过才显示绿色“已验证”。

## TUN 要求

请在当前 TUN 配置中启用：

```text
loopback-address 10.7.0.1
```

### Clash Mi / Clash

```yaml
tun:
  loopback-address:
    - 10.7.0.1
```

### Karing

已通过实机测试的一组设置：

```text
关闭新手模式
TUN: 开启
Loopback Address: 10.7.0.1
Stack: gvisor
```

如果配置里存在会排除 `10.7.0.1` 的大范围路由（例如错误地把整个 `10.0.0.0/8` 排除在 TUN 外），RemotePairing 可能无法工作。

## 安装

GitHub Release 提供的是 **unsigned IPA**。下载后需要使用你自己的开发者证书 / P12 + mobileprovision 或其它合法签名方式重新签名并安装。

安装时请保留主 App 内嵌的 `PlaceDriftShare.appex`，否则地图分享入口不会出现。

建议首次使用前确认：

1. iPhone 已开启 **Developer Mode / 开发者模式**。
2. 已安装并连接一个兼容的 TUN App。
3. TUN 已启用 `10.7.0.1` self-loop。
4. PlaceDrift 已获得本地网络权限。

## 首次配对

1. 先连接兼容的 TUN，并确认 PlaceDrift 首页“传输”显示绿色 **已验证 · 10.7.0.1**。
2. 在 PlaceDrift 中点击 **开始配对**。
3. 打开：

   **设置 → 隐私与安全性 → 开发者模式 → 与主机配对**

4. 选择 **PlaceDrift**。
5. 输入 PlaceDrift 页面显示的 PIN。
6. 配对成功后，配对记录会保存在本机 Keychain。正常情况下以后无需重新配对。

如果确实需要重新配对，请先在 PlaceDrift 中删除已保存的配对记录，再开始新的配对会话。

## 使用地图分享设置位置

1. 保持兼容的 TUN App 已连接。
2. 打开 PlaceDrift，确认：
   - 配对：**已保存**
   - 传输：**已验证 · 10.7.0.1**
   - **启用地图分享** 已打开
3. 建议把 PlaceDrift 的定位权限设置为 **始终**，用于维持后台分享接收器和 CoreDevice 会话。
4. 在 Apple 地图、高德地图或百度地图中选择地点。
5. 点击系统 **分享**。
6. 选择 **PlaceDrift**。
7. Share Extension 会显示 **“正在解析地图坐标…”**，随后把坐标直接发送到 PlaceDrift。
8. PlaceDrift 会立即设置或更新 `LocationSimulation`。

要回到真实定位，在 PlaceDrift 中点击 **恢复真实位置**。

如果 PlaceDrift 被系统或用户强制退出，请先重新打开 PlaceDrift，再使用地图分享。

## 地图解析

地图解析全部在 iPhone 本机完成：

- **Apple 地图**：解析 Apple Maps 分享 URL / 坐标参数。
- **高德地图**：支持短链跳转和常见坐标参数，并把 GCJ-02 转换为 WGS-84。
- **百度地图**：支持分享文本、短链、BD-09 / BD09MC 数据；对需要页面脚本才能得到 POI 坐标的页面使用本机 WebKit 解析，再转换为 WGS-84。

当前版本**不会请求 `wloc.xepesw.workers.dev` 或其它远程坐标解析 Worker**。

## 后台运行

PlaceDrift 使用 iOS Location 后台模式维持 CoreDevice 会话和地图分享接收器。为了尽量在锁屏 / 后台状态下继续接收地图分享，请允许 PlaceDrift **始终**访问位置。

后台能力仍受 iOS 调度策略影响；Public Beta 阶段欢迎反馈不同设备和系统版本的长期锁屏表现。

## 当前 Public Beta 不包含

- Shortcuts / App Intents 坐标设置入口
- 地图区域 / GeoServices Provider 切换实验
- 内置 VPN 或代理功能

这些功能不会影响当前已经验证的“地图直接分享到 PlaceDrift”主链路。

## URL Scheme

保留基础 Deep Link：

```text
placedrift://set?lat=34.052235&lon=-118.243683
placedrift://clear
placedrift://pair
```

## 从源码构建

需要：

- macOS + Xcode
- XcodeGen
- Rust toolchain

执行：

```bash
./scripts/build-app.sh
```

输出：

```text
.build/artifacts/PlaceDrift-unsigned.ipa
```

## 隐私

- 配对记录与 CoreDevice 凭据保存在设备本机 Keychain。
- 地图坐标默认在设备本地解析。
- 不要把 pairing record、AltIRK 或其它设备私密凭据上传到 GitHub、网页或日志平台。

## 反馈

如果遇到问题，建议提交 GitHub Issue，并注明：

- iOS 版本
- 使用的 TUN App 与版本
- `10.7.0.1` loopback 配置
- PlaceDrift 首页“传输”状态
- 问题发生在配对、地图分享、后台保持还是恢复真实位置

请不要在公开 Issue 中上传任何配对密钥或设备私密凭据。
