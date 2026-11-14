# 天猫校园 iOS 版快速解锁（VocLock）

在 iPhone 上用一个 App 直接开宿舍门锁：**点开就开、不联网、没有开屏广告、没有摇一摇**。
协议实现移植自安卓项目 [lmc2007/TMallKey](https://github.com/lmc2007/TMallKey)（作者：牧冷，MIT），这里是 iOS 的原生重写（Swift + CoreBluetooth），不 hook、不注入、不读取天猫校园进程。

> ⚠️ **仅供本人有权开启的宿舍门使用。** 与天猫校园官方无关。`activationKey` 等价于你这扇门的钥匙，请勿外传、勿提交到仓库。
> ⚠️ 侧载证书过期或被吊销时 App 会打不开，**实体钥匙请务必留一把**。

---

## 最省事的方案：先用安卓版

如果你有安卓手机，**直接用 [TMallKey](https://github.com/lmc2007/TMallKey)** 就好，作者已经把它做得很好：一点即开、离线、支持桌面快捷方式和快捷设置磁贴。
iOS 版只是给「手上只有 iPhone」的人准备的。

## 一、先拿到你自己的钥匙

iOS 不像安卓能直接读写门锁 MAC，也没有办法在 App 里替你抓钥匙，所以**第一步必须在安卓手机上完成**，二选一：

### 方案 A：用 TMallKey 的「补丁版天猫校园」（推荐，免 root）
1. 从 [TMallKey Releases](https://github.com/lmc2007/TMallKey/releases) 下载「补丁版天猫校园 5.0.0」（LSPatch 版本）
2. 卸载手机上的官方天猫校园（同包名，只能装一个），安装补丁版，用手机号验证码登录
3. 走进宿舍门锁页面，**点一次「开锁」，让门真的开一下**
4. 打开 TMallKey，门锁凭证会自动同步进来；在门锁卡片上就能看到 `activationKey`

> 注意：天猫校园 **5.8.0 之后不再把钥匙打进日志**（改成了 AES-GCM 加密 + 只打前 8 位），所以必须是 5.0.0 版本才有这个口子。

### 方案 B：adb 抓 logcat（不想换 App 时）
1. 手机开启开发者选项与 USB 调试，连电脑
2. `adb logcat -c && adb logcat -v time VocLockHelperV2:V VocLockHelper:V VocLockManager:V '*:S'`
3. 在官方天猫校园里点一次「开锁」
4. 日志里会出现：`VocLockHelperV2: unlock: macAddress: XX:XX:.. activationKey: <32 位十六进制>`

拿到的是 **32 位十六进制**，形如 `0123456789abcdef0123456789abcdef`。

## 二、构建 IPA

### GitHub Actions（不需要 Mac）
1. Fork 或 clone 本仓库，推到自己的 GitHub
2. Actions 会自动跑 `build-ipa`：先跑协议单元测试，再构建
3. 在运行结果页的 **Artifacts** 里下载 `VocLock-unsigned-ipa`

### 本机 Mac
```bash
./build.sh        # 需要 Xcode + xcodegen（脚本会自动装 xcodegen）
```
> 仓库里已经附带生成好的 `VocLock.xcodeproj`（XcodeGen 2.46 生成，`TEST_HOST`、部署目标、源文件都已核对）。装了 Xcode 之后可以直接双击打开、选自己的 iPhone 运行，**不需要再装 xcodegen 或 Homebrew**。
产物：`VocLock-unsigned.ipa`（未签名）。

## 三、安装到 iPhone

用 **全能签 / Sideloadly / AltStore** 等工具对未签名 IPA 重签后安装。
首次打开会请求**蓝牙权限**，允许即可。

## 四、使用

1. 打开 App → 点「钥匙」→ 粘贴你的 32 位 `activationKey` → 保存（存进本机 Keychain，不上传）
2. 回到首页点「开锁」；之后**每次打开 App（或从后台切回来）都会自动开一次**
3. 钥匙页里可以关掉「打开 App 就自动开锁」

### 四之二、完全不打开 App 开门（v1.1 新增）

App 现在向系统注册了「开门」动作（App Intents），执行时**不会切到前台**：

| 入口 | 怎么用 |
|---|---|
| 主屏 / 锁屏 | 快捷指令 App → 新建 → 添加操作 → 搜「宿舍门」→ 「开宿舍门」→ 加入主屏幕 |
| 操作按钮（15 Pro+）/ 轻点背面 | 设置 → 操作按钮 / 辅助功能 → 轻点背面 → 选该快捷指令 |
| 锁屏小组件 | 锁屏编辑 → 添加「快捷指令」小组件 → 选「开门」 |
| Siri | 对 Siri 说「用宿舍门开门」 |
| Apple Watch | 手表上的快捷指令同样可用 |

前提：先在 App 里保存过钥匙（钥匙存在 Keychain，快捷指令直接读），并允许蓝牙权限。
因为动作是后台执行的，`Info.plist` 里已声明 `bluetooth-central` 后台模式。

## 已知限制（iOS 的锅，不是 bug）

- **拿不到 MAC**：宿舍走廊里所有门锁广播名都是 `~vTmallLock`，iOS 也不给 App 看 MAC。所以首次要「逐把连上去验身份」——用你的钥匙去解门锁的 13 应答，解得开才开锁，解不开就断开换下一把。首次约 5~8 秒。
- **认出来之后会记住**（`boundLockID`），以后直连，约 2 秒。
- 以下情况会退回一次「扫描 + 重新认」：手机重启、iOS 清了设备缓存、App 重新签名安装。
- 把 App 从后台划掉后重新打开，属于冷启动：仍然会自动开锁，只是会重新扫描一次。
- 快捷指令后台执行时，系统给的时间有限（约 25 秒兜底超时）；扫描 + 逐把验身份如果超时会提示失败，重试一次即可。

## 原理

门锁是 BLE 蓝牙锁，一次开锁三步：

| 步骤 | 方向 | 内容 |
|---|---|---|
| 0D 请求随机数 | 明文帧 `55AAFF0D00000B` | 响应里带 16 字节随机数 |
| 13 建立加密链路 | 明文帧 `55AAFF13000011` | 响应用钥匙解密，`ff 13 0001 00` 表示成功 |
| 0B 开锁 | 密文帧 | 裸 ack `55AAFF0B0001000A` 或加密 ack 状态位 `00` |

- `actualAesKey = randomNumber ⊕ activationKey`（各 16 字节）
- 明文 blob：`FF | sign | len(2B) | content | cksum`，补 `0` 对齐 16 字节
- 加密：**AES-128 / ECB / NoPadding**（iOS 用 CommonCrypto 的 `CCCrypt`）
- 服务 UUID：`00002760-08c2-11e1-9073-0e8ac72e1001`，20 字节切包写入，按帧长判帧

## 目录结构

```
VocLock/
├── VocLock/
│   ├── VocLockApp.swift
│   ├── ContentView.swift           # 大按钮 + 自动开锁 + 收发日志
│   ├── OpenDoorIntent.swift        # 快捷指令 / Siri 的「开门」动作（v1.1）
│   ├── Core/
│   │   ├── VocProtocol.swift       # 帧编解码 / AES-128-ECB / 应答校验
│   │   ├── LockSession.swift       # CoreBluetooth 状态机（扫描/验身份/开锁）
│   │   ├── KeychainStore.swift     # 钥匙存 Keychain
│   │   └── AppConfig.swift
│   └── Resources/                  # Info.plist + AppIcon
├── VocLockTests/VocProtocolTests.swift
├── .github/workflows/ios.yml       # macOS runner → 未签名 IPA
├── project.yml                     # XcodeGen
└── build.sh
```

## v1.1 改动（相对初版）

**新增能力**

- **快捷指令 / Siri 开门**：`OpenDoorIntent`（`openAppWhenRun = false`），可放到主屏、锁屏、操作按钮、轻点背面或 Apple Watch，执行时完全不进 App 前台。
- `LockSession.shared` 单例：界面与快捷指令共用同一个 `CBCentralManager`（两个实例会抢门锁那 1~2 个连接名额）。
- `UIBackgroundModes: bluetooth-central`，后台执行 BLE 才不会被挂起。

**修掉的真问题**

| 问题 | 后果 | 修法 |
|---|---|---|
| `cancelPeripheralConnection` 触发 `didDisconnect` → 又调一次 `skipCurrent` | `tryIndex` 一次加 2，**直接跳过下一把门锁**，走廊里永远认不到自己的门 | 加 `skipping` 重入标志 |
| `pump()` 在帧头不足 6 字节时把整个缓冲清空 | 0D 应答先到 4~5 字节时会**丢掉整帧**，表现为随机数超时 | 只在失步时逐字节丢弃，合法半帧保留 |
| 开锁成功后不断开连接 | 一直占着门锁的并发名额，同宿舍其他人开不了门 | 成功后 0.6 s 主动断开 |
| 扫描窗口 2.5 s / 连接超时 5 s | 走廊信号差时经常「附近没扫到门锁」 | 扫描 4 s、连接 6 s |
| 只按广播名匹配 `vtmall` / `voc` | 广播里不带名字、只带 Service UUID 的批次扫不到 | 名字 **或** 广播 Service UUID 命中都算 |
| 蓝牙被拒 / 不可用时直接 return | 快捷指令会一直等到超时 | 走 `finish(false)` 立即返回 |

**验证**

- 协议层未改动，黄金向量（unlock / battery / AES-FIPS-197 / 帧长 / 13 与 0B 应答解密）全部保留；另外独立用 Node 的 `aes-128-ecb` 复算过这三条向量，逐字节一致。
- 新增两条断言：`assembleContent("0B","")` 的 16 字节补位、`cksum("55AAFF0D0000") == 0b`。
- 部署目标从 iOS 15 提到 **iOS 16**（App Intents 要求；iOS 16 以下设备用初版）。

## 致谢与许可

- 协议逆向、常量、真机抓包验证：**[lmc2007/TMallKey](https://github.com/lmc2007/TMallKey)**（牧冷），MIT
- 本项目：MIT。仅供学习研究与本人宿舍门使用，请勿用于开启他人门锁或任何未经授权的场景。
