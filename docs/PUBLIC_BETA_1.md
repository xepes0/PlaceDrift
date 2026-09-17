# PlaceDrift 0.2.1 Public Beta 1

Build: **15**

这是 PlaceDrift 第一版公开测试版。

## 已验证主链路

- iOS 27+ CoreDevice / RemotePairing
- 动态 RemotePairing 端口协议级 `attemptPairVerify` 检测
- DVT `LocationSimulation` 设置、更新、清除后再次设置
- Apple 地图 → 分享 → PlaceDrift
- 高德地图 → 分享 → PlaceDrift
- 百度地图 → 分享 → PlaceDrift
- 地图坐标本机解析，不依赖远程 Worker
- 配对记录保存在本机 Keychain
- 地图分享接收器与后台 Location 保活

## TUN 兼容性

已实测可用：

- LocalDevVPN
- Clash Mi
- Clash
- Karing

当前实测配置无法通过 RemotePairing 协议检测：

- Loon
- Surge
- Shadowrocket

必须在兼容 TUN 配置中启用 `loopback-address 10.7.0.1`。

**PlaceDrift 本身不会启动 VPN。**

## Public Beta 1 的取舍

为了让第一版公开测试聚焦已经实测稳定的路径，本版移除了：

- Shortcuts / App Intents 坐标设置功能
- 实验性的 GeoServices 地图区域切换功能

当前推荐且已验证的操作方式是：

**Apple 地图 / 高德地图 / 百度地图 → 系统分享 → PlaceDrift**

## 安装

Release 附件提供 **unsigned IPA**。请使用你自己的合法开发者证书 / P12 + mobileprovision 重新签名并安装，并保留内嵌的 `PlaceDriftShare.appex`。

详细配对、TUN 配置和使用方法请查看项目首页 README。

## 反馈

提交 Issue 时请附上 iOS 版本、TUN App 与版本、`10.7.0.1` 配置和 PlaceDrift 的传输状态。

请勿公开上传 pairing record、AltIRK 或其它设备私密凭据。
