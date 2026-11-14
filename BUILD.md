# 怎么把它变成一个能装的 IPA（给任何一台有 Xcode 的 Mac）

这个仓库不需要额外装 xcodegen / Homebrew，`VocLock.xcodeproj` 已经生成好并核对过。

## 方式一：图形界面（3 步）

1. 双击 `VocLock.xcodeproj`
2. 左侧选中 `VocLock` scheme，顶部设备选 **Any iOS Device (arm64)**
3. 菜单 **Product → Archive** → 完成后在 Organizer 点 **Distribute App → Custom → Copy App**，得到一个 `VocLock.app`

## 方式二：命令行（一条）

```bash
xcodebuild -project VocLock.xcodeproj -scheme VocLock -configuration Release \
  -sdk iphoneos -derivedDataPath build \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

## 打成 IPA

`Payload/` 里面必须只有一个 `VocLock.app`：

```bash
mkdir -p Payload
cp -R build/Build/Products/Release-iphoneos/VocLock.app Payload/
zip -qr VocLock-unsigned.ipa Payload
```

产物 `VocLock-unsigned.ipa` 是**未签名**的，拿回自己手机上用 Sideloadly / 爱思助手签名安装即可。

## 自检（可选）

```bash
xcodebuild test -project VocLock.xcodeproj -scheme VocLock \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

协议层也可以完全离线验证，不需要门锁、不需要 iPhone：

```bash
swiftc -O VocLock/Core/VocProtocol.swift Tools/ProtocolCheck/main.swift -o /tmp/check && /tmp/check
```

## 注意

- 这个仓库里**不含任何人的 activationKey**，钥匙只存在手机本地的 Keychain 里，编译者拿不到也看不到。
- 编译产物在别人机器上跑，等于别人手里有一份可以开你门的 App——只交给信得过的人。
