import Foundation

// ============================================================================
// 离线协议自检：在 Mac 上直接跑 VocLock 的 VocProtocol.swift，
// 用一把内存里的「假门锁」走完 0D → 13 → 0B，验证真实代码而不是复述逻辑。
//   swiftc -O VocLock/Core/VocProtocol.swift Tools/ProtocolCheck/main.swift -o check
// ============================================================================

var failures = 0
func check(_ name: String, _ cond: Bool) {
    print(cond ? "  ✅ \(name)" : "  ❌ \(name)")
    if !cond { failures += 1 }
}

func eq(_ name: String, _ got: String?, _ want: String) {
    check("\(name)  \(got ?? "nil")", (got ?? "nil").uppercased() == want.uppercased())
}

/// 内存里的门锁：持有 activationKey，收到帧就用派生密钥加解密
final class MockLock {
    let activationKey: String
    var randomHex = ""
    var lastPlain = ""

    init(activationKey: String) { self.activationKey = activationKey }

    private func actualKey() -> [UInt8] {
        VocProtocol.aesKeyBytes(VocProtocol.xorHex(randomHex, activationKey))!
    }

    private func clearFrame(cmd: String, payload: String) -> String {
        let head = "55AA" + "FF" + cmd + String(format: "%04X", payload.count / 2) + payload
        return (head + VocProtocol.checksum(head)).uppercased()
    }

    private func cipherFrame(plainBlob: String) -> String {
        let cipher = VocProtocol.aesECB(VocProtocol.bytes(plainBlob), key: actualKey(), encrypt: true)!
        let head = "55AA" + String(format: "%04X", cipher.count) + VocProtocol.hexString(cipher)
        return (head + VocProtocol.checksum(head)).uppercased()
    }

    /// 0D：回 24 字节明文帧，带 16 字节随机数
    func receiveRequestRandom(_ frame: String) -> String {
        precondition(frame == "55AAFF0D00000B")
        randomHex = (0..<16).map { _ in String(format: "%02X", UInt8.random(in: 0...255)) }.joined()
        return clearFrame(cmd: "0D", payload: "00" + randomHex)
    }

    /// 13：请求是明文固定帧，响应是密文
    func receiveEstablish(_ frame: String) -> String {
        precondition(frame == "55AAFF13000011")
        lastPlain = VocProtocol.assembleContent(sign: "13", contentHex: "00")
        return cipherFrame(plainBlob: lastPlain)
    }

    /// 0B：请求是密文，能解开才认
    func receiveUnlock(_ frame: String) -> String? {
        guard let cipher = VocProtocol.cipherBytes(frame),
              let plain = VocProtocol.aesECB(cipher, key: actualKey(), encrypt: false),
              VocProtocol.hexString(plain).lowercased().hasPrefix("ff0b") else { return nil }
        lastPlain = VocProtocol.hexString(plain).lowercased()
        return cipherFrame(plainBlob: VocProtocol.assembleContent(sign: "0B", contentHex: "00"))
    }
}

let demoKey = "000102030405060708090a0b0c0d0e0f"

print("== 1. 已知向量（与安卓参考实现逐字节对齐） ==")
eq("AES-128 FIPS-197",
   VocProtocol.hexString(VocProtocol.aesECB(VocProtocol.bytes("00112233445566778899aabbccddeeff"),
                                           key: VocProtocol.bytes(demoKey), encrypt: true) ?? []),
   "69c4e0d86a7b0430d8cdb78070b4c55a")

let fixedRandomFrame = "55AAFF0D00110000112233445566778899AABBCCDDEEFF14"
eq("unlock 帧", VocProtocol.unlockFrame(randomFrameHex: fixedRandomFrame, keyHex: demoKey),
   "55AA0010EB99D2CB9F8DCB9384C2066473171995A2")
eq("battery 帧", VocProtocol.batteryFrame(randomFrameHex: fixedRandomFrame, keyHex: demoKey),
   "55AA0010ADC57A17E60E8ADCF3B5BB2C4506982503")
eq("明文 blob 补位", VocProtocol.assembleContent(sign: "0B", contentHex: ""),
   "FF0B0000090000000000000000000000")
check("cksum(55AAFF0D0000) == 0b", VocProtocol.checksum("55AAFF0D0000") == "0b")
eq("从 0D 帧取随机数", VocProtocol.randomNumber(from: fixedRandomFrame), "00112233445566778899AABBCCDDEEFF")

print("== 2. 帧长判定 ==")
check("0D 响应 = 24B", VocProtocol.expectedFrameLength(VocProtocol.bytes(fixedRandomFrame)) == 24)
check("密文 ack = 21B",
      VocProtocol.expectedFrameLength(VocProtocol.bytes("55AA0010ADC57A17E60E8ADCF3B5BB2C4506982503")) == 21)
check("固定帧 = 7B", VocProtocol.expectedFrameLength(VocProtocol.bytes("55AAFF0D00000B")) == 7)
check("非法帧头 = nil", VocProtocol.expectedFrameLength(VocProtocol.bytes("1234")) == nil)

print("== 3. 与假门锁跑完整开锁时序 ==")
let lock = MockLock(activationKey: demoKey)
print("  0D → TX \(VocProtocol.fixedRequestRandom)")
let rndResp = lock.receiveRequestRandom(VocProtocol.fixedRequestRandom)
print("  0D ← RX \(rndResp)")
check("随机数帧长度 24", VocProtocol.expectedFrameLength(VocProtocol.bytes(rndResp)) == 24)
check("能取出随机数", VocProtocol.randomNumber(from: rndResp) == lock.randomHex)

print("  13 → TX \(VocProtocol.fixedEstablishLink)")
let estResp = lock.receiveEstablish(VocProtocol.fixedEstablishLink)
print("  13 ← RX \(estResp)")
let (ok13, note13) = VocProtocol.parseAck(frameHex: estResp, randomFrameHex: rndResp, keyHex: demoKey)
check("13 应答用正确钥匙可解开（\(note13)）", ok13)

guard let unlockFrame = VocProtocol.unlockFrame(randomFrameHex: rndResp, keyHex: demoKey) else {
    print("  ❌ 开锁帧构造失败"); exit(1)
}
print("  0B → TX \(unlockFrame)")
if let ack = lock.receiveUnlock(unlockFrame) {
    print("  0B ← RX \(ack)")
    let (ok0B, note0B) = VocProtocol.parseAck(frameHex: ack, randomFrameHex: rndResp, keyHex: demoKey)
    check("0B 应答状态位为 00（\(note0B)）", ok0B)
} else {
    check("0B 帧能被门锁解开", false)
}

print("== 4. 错误钥匙必须被拒（防止连错门锁） ==")
let otherLock = MockLock(activationKey: "ffffffffffffffffffffffffffffffff")
let wrongRnd = otherLock.receiveRequestRandom(VocProtocol.fixedRequestRandom)
let wrongEst = otherLock.receiveEstablish(VocProtocol.fixedEstablishLink)
let (bad, _) = VocProtocol.parseAck(frameHex: wrongEst, randomFrameHex: wrongRnd, keyHex: demoKey)
check("别把钥匙解不开的锁当成自己的门", bad == false)
check("错误钥匙也不会生成可解开的 0B 帧",
      otherLock.receiveUnlock(VocProtocol.unlockFrame(randomFrameHex: wrongRnd, keyHex: demoKey) ?? "") == nil)

print("== 5. 裸 ack 路径（老固件） ==")
check("55AAFF0B0001000A 前缀判定",
      "55AAFF0B0001000A".uppercased().hasPrefix(VocProtocol.unlockSuccessAck))

print("")
if failures == 0 {
    print("全部通过（0 失败）")
    exit(0)
} else {
    print("有 \(failures) 项失败")
    exit(1)
}
