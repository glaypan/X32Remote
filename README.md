# X32 Remote

一个用于远程控制 Behringer X32 / Midas M32 系列数字调音台的原生 iOS 应用。

## 项目简介

X32 Remote 是一个基于 SwiftUI 开发的 iOS 应用,通过 OSC (Open Sound Control) 协议与 X32/M32 调音台进行实时通信。支持 iPad 和 iPhone,以横屏模式为主,提供直观的混音控制界面。

### 主要特性

- 🎚️ 实时推子控制与通道管理
- 🔌 基于 OSC 协议的本地网络通信
- 📱 支持 iPad 和 iPhone 通用
- 🎨 原生 SwiftUI 界面
- 🔄 横屏优先设计
- ⚡ 最低支持 iOS 15+

## 系统要求

- **Xcode**: 14.0 或更高版本
- **iOS 部署<u>目标</u>**<u>: iOS 15.0+</u>
- **<u>Swift 工具版本</u>**<u>: 5.9</u>
- **<u>支持设备</u>**<u>: iPhone 和 iPad (通用应用)</u>
- **<u>网络要求</u>**<u>: 本地网络访问权限(用</u>于 OSC 通信)

## 项目结构

本项目采用 **Swift Package + Xcode App Target** 的混合架构:

```
X32Remote/
├── Package.swift                    # Swift Package 清单
├── X32Remote.xcodeproj/             # Xcode 项目文件
├── X32Remote.xcworkspace/           # Xcode 工作空间
├── App/                             # iOS 应用层
│   ├── X32RemoteApp.swift          # App 入口点
│   ├── AppModel.swift              # 应用状态模型
│   ├── Views/                      # SwiftUI 视图
│   │   ├── RootTabView.swift       # 主标签导航
│   │   └── SettingsView.swift      # 设置页面
│   └── Components/                 # 可复用组件
│       └── FaderRow.swift          # 推子行组件
├── Sources/                        # Swift Package 源码
│   └── X32RemoteCore/              # 核心库
│       ├── Model/                  # 数据模型
│       ├── Network/                # 网络层
│       ├── Osc/                    # OSC 协议实现
│       └── Show/                   # 场景管理
└── Tests/                          # 单元测试
    └── X32RemoteCoreTests/
```

### 架构说明

- **X32RemoteCore**: 核心库,封装 OSC 协议、网络通信、数据模型等跨平台逻辑
- **App/**: iOS 应用层,包含 SwiftUI 界面与平台特定代码
- **Swift Package Manager**: 用于管理核心库的模块化开发
- **Xcode Project**: 用于 iOS 应用的打包、签名与部署

## 快速开始

### 1. 克隆或下载项目

```bash
cd e:\AI\trae\遥控\ios
```

### 2. 打开工作空间

使用 Xcode 打开 `X32Remote.xcworkspace` (而非 `.xcodeproj`):

```bash
open X32Remote.xcworkspace
```

### 3. 配置签名

1. 在 Xcode 中选择 `X32Remote` target
2. 进入 **Signing & Capabilities** 标签
3. 选择你的开发团队或使用自动签名

### 4. 选择目标设备

- 在 Xcode 顶部工具栏选择目标设备(模拟器或真机)
- 推荐使用 iPad 模拟器以获得最佳横屏体验

### 5. 构建并运行

按 `Cmd + R` 或点击运行按钮。

## 配置信息

### 应用元数据

- **Bundle Identifier**: `com.example.X32Remote`
- **Display Name**: X32 Remote
- **Version**: 1.0.0
- **Build Number**: 1

### 设备支持

- **Supported Devices**: iPhone & iPad (通用)
- **Orientation**: 横屏优先(Landscape Left/Right),支持竖屏回退

### 权限与隐私

应用需要以下权限:

- **本地网络访问** (`NSLocalNetworkUsageDescription`):
  > 需要访问本地网络以连接 X32/M32 调音台

确保在真机测试时,设备与调音台处于同一局域网。

## OSC 通信协议

### 连接参数

- **协议**: OSC (Open Sound Control) over UDP
- **默认端口**: 10023
- **目标**: X32/M32 调音台 IP 地址

### 消息格式

应用使用 X32/M32 官方 OSC 命令集,包括但不限于:

- `/ch/01/mix/fader` - 通道 1 推子
- `/ch/01/config/name` - 通道 1 名称
- `/main/st/mix/fader` - 主输出推子
- `/xremote` - 保活消息(每 10 秒)

详细 OSC 命令参考 Behringer X32 OSC 协议文档。

## 开发指南

### 添加新功能

1. **核心逻辑**: 在 `Sources/X32RemoteCore/` 中添加新模型或网络层代码
2. **界面层**: 在 `App/Views/` 或 `App/Components/` 中添加 SwiftUI 视图
3. **测试**: 在 `Tests/X32RemoteCoreTests/` 中添加对应单元测试

### 运行测试

```bash
# 使用 Xcode
Cmd + U

# 使用命令行
swift test
```

### 代码风格

- 遵循 Swift API 设计指南
- 使用 SwiftUI 声明式语法
- 保持关注点分离(核心逻辑 vs UI 层)

## 已知限制

- 当前为开发版本,仅用于学习与内部原型
- 自动发现:已实现子网 /xinfo 轻量扫描(每 IP 仅 1 条探测消息),兜底使用设备本机 IPv4 推断子网
- 电平表:通过 /meters/1 blob 流式获取(每 500ms 重订阅一次),-60dB~~0dB 映射到 0~~1
- Main LR 主输出已支持推子/静音控制(列表末尾,无详情页)
- Routing 等高级功能尚未实现

## 更新记录

### 2026-09 优化版

- 修复编译错误:`OscCodec.encode` 调用方式、缺失的 `decodeMessages`(含 OSC Bundle 支持)、`OscMessage` 默认参数、`args` 属性名不一致
- 修复 DCA 地址补零不一致导致的状态重复条目 (/dca/1 与 /dca/01)
- 性能:OSC 状态同步从"每条消息全量重建 UI"改为 100ms 节流合并;电平轮询从每 200ms 发送 32 条消息改为每 500ms 一条 /meters/1 blob(轻量快速通道,不触发全量同步)
- 线程安全:X32Client.state 读写加 NSLock,提供一致的快照语义
- 自动发现重写:每 IP 1 条 /xinfo 探测(原来每 IP 约 280 条初始查询),并发分批(每批 32 个),修复子网推断与 /xinfo 回复解析
- 新增 Main LR 主输出控制;IP/端口持久化保存

### 2026-09-14 Windows 工具链验证(Swift 6.3.3)

在 Windows 上安装 Swift 6.3.3 工具链,对不含 `X32Client`(依赖 Apple Network 框架)的核心库跑真实单元测试,共执行 **92 个测试全部通过**。验证过程中额外发现并修复 3 个问题:

- `OscCodec.decodeBundle`:元素长度从 offset=8 开始读,把 timetag 前 4 字节当成了长度 → 修正为 offset=16(8 字节 `#bundle\0` + 8 字节 timetag),Bundle 解码此前实际完全不可用
- `OscAddresses.meterFloats`:把 blob 首部的 Int32 数量字段也当 Float 解析 → 现在跳过数量字段仅返回电平值,`X32Client`/`AppModel` 调用点索引同步改为 0 起
- `OscArgument` 显式 `import Foundation`(Windows 下 `Data` 一致性依赖);`RemoteStateTests` 原按虚构 API 编写,已重写为针对真实 API 的有效用例

注意:App 层(SwiftUI 视图)与 `X32Client` 仍需在 macOS/Xcode 上构建验证;本 Windows 验证覆盖 OSC 编解码、地址生成、状态模型、场景执行等约 70% 核心逻辑。

## 故障排除

### 无法连接到调音台

1. 确认设备与调音台在同一局域网
2. 检查调音台是否开启网络功能
3. 验证 IP 地址与端口(10023)是否正确
4. 确认 iOS 设备已授予本地网络访问权限

### 编译错误

1. 确保使用 `X32Remote.xcworkspace` 而非 `.xcodeproj`
2. 清理构建文件夹: `Cmd + Shift + K`
3. 重置 Package 缓存: `File > Packages > Reset Package Caches`

## 许可证

本项目仅供学习与研究用途。请遵守 Behringer/Midas 的商标与知识产权政策。

## 免责声明

**本项目非 Behringer 或 Midas 官方产品。**

本应用仅用于学习、研究及内部原型开发,不得用于商业用途。X32、M32 及相关商标归 Music Tribe 所有。

## 技术支持

如有问题或建议,请通过以下方式联系:

- **项目路径**: `e:\AI\trae\遥控\ios\`
- **最后更新**: 2025 年 1 月

---

**Happy Mixing! 🎛️**
