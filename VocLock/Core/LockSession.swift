import Foundation
import CoreBluetooth
import Combine

/// 一次开锁会话：扫描 → 逐把试连 → 用 13 步应答验身份 → 0D/13/0B 开锁
///
/// 全 App 共用 `LockSession.shared`：App 界面和快捷指令（App Intent）必须用同一个实例，
/// 否则会出现两个 `CBCentralManager` 抢同一把门锁的连接名额。
final class LockSession: NSObject, ObservableObject {

    static let shared = LockSession()

    @Published var statusText = "就绪"
    @Published var busy = false
    @Published var logLines: [String] = []

    private var central: CBCentralManager?
    private var target: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

    private enum Stage { case idle, requestRandom, establish, unlock, battery }
    private var stage: Stage = .idle
    private var wanted: Stage = .unlock
    private var randomFrame = ""
    private var key = ""

    private struct Candidate {
        let peripheral: CBPeripheral
        let name: String
        let rssi: Int
    }
    private var discovered: [Candidate] = []
    private var tryIndex = 0

    private var rxBuf: [UInt8] = []
    private var timeoutWork: DispatchWorkItem?

    private var pendingChunks: [Data] = []
    private var pendingIndex = 0
    private var pendingDone: ((Error?) -> Void)?

    /// 跳过当前这把锁时的重入保护：cancelPeripheralConnection 会回调 didDisconnect，
    /// 不挡住的话 tryIndex 会 +2，直接把下一把锁跳过去。
    private var skipping = false

    /// 快捷指令用的等待回调（只会在主线程读写）
    private var finishHandler: ((Bool) -> Void)?

    private var startedAt = Date()

    /// 冷启动时蓝牙还没就绪，先把请求挂起，等 poweredOn 再执行
    private var pendingStart: (key: String, wanted: Stage)?

    /// 上次验明正身的门锁（iOS 的 CBPeripheral.identifier，等价于安卓那边的 MAC）
    private var boundID: UUID? {
        get {
            guard let s = UserDefaults.standard.string(forKey: "boundLockID") else { return nil }
            return UUID(uuidString: s)
        }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "boundLockID") }
    }

    var hasBoundLock: Bool { boundID != nil }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - 对外

    func unlock(key: String) { start(key: key, wanted: .unlock) }
    func battery(key: String) { start(key: key, wanted: .battery) }

    /// 等一次开锁跑完（给 App Intent / 快捷指令用）。
    /// 蓝牙不可用、超时、失败都会返回 false，不会一直挂着。
    func unlockAndWait(key: String, timeout: TimeInterval = 25) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            DispatchQueue.main.async {
                self.finishHandler = { ok in cont.resume(returning: ok) }
                self.unlock(key: key)
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                    if let handler = self.finishHandler {
                        self.finishHandler = nil
                        self.log("快捷指令超时，放弃等待")
                        handler(false)
                    }
                }
            }
        }
    }

    private func start(key: String, wanted: Stage) {
        guard !busy else { return }
        self.key = key.lowercased()
        self.wanted = wanted
        busy = true
        stage = .idle
        randomFrame = ""
        rxBuf = []
        discovered = []
        tryIndex = 0
        skipping = false
        logLines.removeAll()
        startedAt = Date()
        statusText = "准备中…"
        log("目标：\(wanted == .unlock ? "开锁" : "查电量")")

        log("钥匙 \(self.key.prefix(8))…")
        if let p = target, p.state == .connected, writeChar != nil, notifyChar != nil {
            beginFlow()
            return
        }
        guard let c = central, c.state == .poweredOn else {
            let st = central?.state
            if st == .unknown || st == .resetting || st == nil {
                pendingStart = (self.key, wanted)
                busy = false
                statusText = "蓝牙启动中…"
                log("等蓝牙就绪后再开")
                return
            }
            finish(false)
            statusText = "蓝牙不可用"
            log("❌ 蓝牙未开启或未授权")
            return
        }
        // 已绑定的锁：直接连，跳过扫描（对应安卓的按 MAC 直连）
        if let id = boundID, let known = c.retrievePeripherals(withIdentifiers: [id]).first {
            log("直连已绑定的门锁…")
            statusText = "连接门锁…"
            target = known
            known.delegate = self
            writeChar = nil
            notifyChar = nil
            c.connect(known, options: nil)
            arm(6, "连接超时") { [weak self] in self?.fallBackToScan() }
            return
        }
        startScan()
    }

    // MARK: - 日志 / 定时

    private func log(_ s: String) {
        let t = String(format: "%.3f", Date().timeIntervalSince(startedAt))
        if logLines.count > 80 { logLines.removeFirst() }
        logLines.append("[\(t)s] \(s)")
    }

    private func arm(_ seconds: Double, _ label: String, _ body: @escaping () -> Void) {
        timeoutWork?.cancel()
        let w = DispatchWorkItem(block: body)
        timeoutWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    private func clearTimer() {
        timeoutWork?.cancel()
        timeoutWork = nil
    }

    /// 一次性收尾：把结果交给快捷指令，然后清空
    private func finish(_ ok: Bool) {
        let handler = finishHandler
        finishHandler = nil
        handler?(ok)
    }

    private func succeed(_ msg: String) {
        clearTimer()
        statusText = msg
        log("✅ \(msg)")
        busy = false
        stage = .idle
        // 开完就断开，别占着门锁那 1~2 个并发名额（安卓版也是这么做的）
        if let p = target {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.central?.cancelPeripheralConnection(p)
            }
        }
        finish(true)
    }

    private func fail(_ msg: String) {
        clearTimer()
        statusText = msg
        log("❌ \(msg)")
        busy = false
        stage = .idle
        finish(false)
    }

    // MARK: - 扫描 / 逐把尝试

    private func startScan() {
        guard let c = central else { return }
        discovered = []
        statusText = "扫描附近门锁…"
        c.scanForPeripherals(withServices: nil, options: nil)
        arm(4, "扫描超时") { [weak self] in self?.finishScan() }
    }

    private func fallBackToScan() {
        log("直连没接上，改为扫描…")
        if let p = target { central?.cancelPeripheralConnection(p) }
        target = nil
        startScan()
    }

    private func finishScan() {
        clearTimer()
        central?.stopScan()
        let sorted = discovered.sorted { a, b in
            if let id = boundID {
                if a.peripheral.identifier == id { return true }
                if b.peripheral.identifier == id { return false }
            }
            return a.rssi > b.rssi
        }
        discovered = sorted
        guard !discovered.isEmpty else {
            fail("附近没扫到门锁，靠近门口再试")
            return
        }
        log("扫到 \(discovered.count) 把门锁，逐把验身份：")
        for (i, d) in discovered.enumerated() {
            log("  \(i + 1). \(d.name)  \(d.rssi) dBm")
        }
        tryIndex = 0
        connectNext()
    }

    private func connectNext() {
        guard tryIndex < discovered.count else {
            fail("试遍了，没有一把认得这把钥匙")
            return
        }
        let c = discovered[tryIndex]
        guard let central = central else { return }
        statusText = "连接第 \(tryIndex + 1)/\(discovered.count) 把…"
        log("连接第 \(tryIndex + 1) 把（\(c.rssi) dBm）…")
        target = c.peripheral
        c.peripheral.delegate = self
        writeChar = nil
        notifyChar = nil
        central.connect(c.peripheral, options: nil)
        arm(6, "连接超时") { [weak self] in self?.skipCurrent("连接超时") }
    }

    private func skipCurrent(_ reason: String) {
        guard !skipping else { return }
        skipping = true
        clearTimer()
        log("这把跳过：\(reason)")
        if let p = target { central?.cancelPeripheralConnection(p) }
        target = nil
        writeChar = nil
        notifyChar = nil
        rxBuf = []
        tryIndex += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self = self else { return }
            self.skipping = false
            self.connectNext()
        }
    }

    // MARK: - 流程

    private func beginFlow() {
        stage = .requestRandom
        statusText = "请求随机数…"
        arm(8, "随机数超时") { [weak self] in self?.skipCurrent("随机数没回来") }
        log("TX \(VocProtocol.fixedRequestRandom)")
        send(VocProtocol.fixedRequestRandom) { [weak self] err in
            if let err = err { self?.skipCurrent("发送失败：\(err.localizedDescription)") }
        }
    }

    private func handleFrame(_ hex: String) {
        clearTimer()
        log("RX \(hex)")
        switch stage {
        case .requestRandom:
            guard let rnd = VocProtocol.randomNumber(from: hex) else {
                skipCurrent("随机数解析失败")
                return
            }
            randomFrame = hex
            log("随机数 \(rnd)")
            stage = .establish
            statusText = "验证门锁身份…"
            arm(8, "链路超时") { [weak self] in self?.skipCurrent("加密链路超时") }
            log("TX \(VocProtocol.fixedEstablishLink)")
            send(VocProtocol.fixedEstablishLink) { [weak self] err in
                if let err = err { self?.skipCurrent("发送失败：\(err.localizedDescription)") }
            }
        case .establish:
            let (ok, note) = VocProtocol.parseAck(frameHex: hex, randomFrameHex: randomFrame, keyHex: key)
            guard ok else {
                skipCurrent("密钥不匹配（\(note)）")
                return
            }
            if tryIndex < discovered.count {
                boundID = discovered[tryIndex].peripheral.identifier
            } else {
                boundID = target?.identifier
            }
            log("身份确认：这把就是你的门锁（已记住）")
            if wanted == .battery { sendBattery() } else { sendUnlock() }
        case .unlock:
            // 固件有两条成功路径：裸 ack，或加密应答里状态位 00
            if hex.uppercased().hasPrefix(VocProtocol.unlockSuccessAck) {
                succeed("开锁成功")
                return
            }
            let (ok, note) = VocProtocol.parseAck(frameHex: hex, randomFrameHex: randomFrame, keyHex: key)
            if ok {
                succeed("开锁成功")
            } else {
                fail("门锁拒绝：\(note)")
            }
        case .battery:
            if let cipher = VocProtocol.cipherBytes(hex) {
                for (i, b) in cipher.enumerated() where i == 1 && b > 0 && b <= 100 {
                    succeed("电量 \(b)%")
                    return
                }
            }
            succeed("电量应答 \(hex)")
        case .idle:
            log("（空闲状态收到数据 \(hex)）")
        }
    }

    private func sendUnlock() {
        stage = .unlock
        statusText = "开锁中…"
        guard let frame = VocProtocol.unlockFrame(randomFrameHex: randomFrame, keyHex: key) else {
            fail("开锁帧构造失败")
            return
        }
        log("TX \(frame)")
        arm(10, "开锁超时") { [weak self] in self?.fail("开锁超时") }
        send(frame) { [weak self] err in
            if let err = err { self?.fail("发送失败：\(err.localizedDescription)") }
        }
    }

    private func sendBattery() {
        stage = .battery
        statusText = "查询电量…"
        guard let frame = VocProtocol.batteryFrame(randomFrameHex: randomFrame, keyHex: key) else {
            fail("电量帧构造失败")
            return
        }
        log("TX \(frame)")
        arm(10, "电量超时") { [weak self] in self?.fail("电量查询超时") }
        send(frame) { [weak self] err in
            if let err = err { self?.fail("发送失败：\(err.localizedDescription)") }
        }
    }

    // MARK: - 写（20 字节切包）

    private func send(_ hex: String, done: @escaping (Error?) -> Void) {
        guard let p = target, let ch = writeChar else {
            done(NSError(domain: "voclock", code: 1, userInfo: [NSLocalizedDescriptionKey: "未连接门锁"]))
            return
        }
        let raw = VocProtocol.bytes(hex)
        var chunks: [Data] = []
        var i = 0
        while i < raw.count {
            let end = min(i + 20, raw.count)
            chunks.append(Data(raw[i..<end]))
            i += 20
        }
        guard !chunks.isEmpty else {
            done(nil)
            return
        }
        if ch.properties.contains(.write) {
            pendingChunks = chunks
            pendingIndex = 0
            pendingDone = done
            p.writeValue(chunks[0], for: ch, type: .withResponse)
        } else {
            for (idx, d) in chunks.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(idx) * 0.02) {
                    p.writeValue(d, for: ch, type: .withoutResponse)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(chunks.count) * 0.02) { done(nil) }
        }
    }

    /// 按帧头长度精确切帧；多余字节留在缓冲里，下一帧接着用。
    private func pump() {
        while true {
            if rxBuf.count >= 2 && !(rxBuf[0] == 0x55 && rxBuf[1] == 0xAA) {
                // 失步：丢掉首字节重新找帧头（不要整段清空，否则会把半帧丢掉）
                rxBuf.removeFirst()
                continue
            }
            guard let want = VocProtocol.expectedFrameLength(rxBuf) else { return }
            guard rxBuf.count >= want else { return }
            let frame = Array(rxBuf.prefix(want))
            rxBuf.removeFirst(want)
            handleFrame(VocProtocol.hexString(frame))
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension LockSession: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log("蓝牙已就绪")
            if let p = pendingStart {
                pendingStart = nil
                log("补执行挂起的开锁")
                start(key: p.key, wanted: p.wanted)
            }
        case .unauthorized:
            pendingStart = nil
            statusText = "蓝牙权限被拒绝，请到设置里允许"
            finish(false)
        case .poweredOff:
            statusText = "请打开蓝牙"
            finish(false)
        default: break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advName ?? ""
        let lower = name.lowercased()
        let advServices = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let hasLockService = advServices.contains { $0.uuidString.uppercased() == VocProtocol.serviceUUID.uppercased() }
        guard lower.contains("vtmall") || lower.contains("voc") || hasLockService else { return }
        if discovered.contains(where: { $0.peripheral.identifier == peripheral.identifier }) { return }
        discovered.append(Candidate(peripheral: peripheral, name: name, rssi: RSSI.intValue))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        clearTimer()
        log("GATT 已连接，发现服务…")
        statusText = "发现服务…"
        peripheral.discoverServices([CBUUID(string: VocProtocol.serviceUUID)])
        arm(8, "服务发现超时") { [weak self] in self?.skipCurrent("服务发现超时") }
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        skipCurrent("连接失败")
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        writeChar = nil
        notifyChar = nil
        // 主动断开（跳过/开锁成功后清理）走这里时不要再触发一次“跳过”
        if skipping { return }
        if busy && stage == .idle { return }
        if busy { skipCurrent("连接断开") } else { log("连接已断开") }
    }
}

// MARK: - CBPeripheralDelegate

extension LockSession: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        clearTimer()
        if let error = error { skipCurrent("服务发现失败：\(error.localizedDescription)"); return }
        guard let svc = peripheral.services?.first(where: {
            $0.uuid.uuidString.uppercased() == VocProtocol.serviceUUID.uppercased()
        }) else {
            skipCurrent("没有门锁服务")
            return
        }
        peripheral.discoverCharacteristics(nil, for: svc)
        arm(8, "特征发现超时") { [weak self] in self?.skipCurrent("特征发现超时") }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        clearTimer()
        if let error = error { skipCurrent("特征发现失败：\(error.localizedDescription)"); return }
        writeChar = nil
        notifyChar = nil
        for c in service.characteristics ?? [] {
            if writeChar == nil && (c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse)) {
                writeChar = c
            }
            if notifyChar == nil && (c.properties.contains(.notify) || c.properties.contains(.indicate)) {
                notifyChar = c
            }
        }
        guard let notify = notifyChar, writeChar != nil else {
            skipCurrent("缺少 write/notify 特征")
            return
        }
        peripheral.setNotifyValue(true, for: notify)
        arm(8, "通知开启超时") { [weak self] in self?.skipCurrent("开启通知超时") }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        clearTimer()
        if let error = error { skipCurrent("开启通知失败：\(error.localizedDescription)"); return }
        guard characteristic.isNotifying else { skipCurrent("门锁没开启通知"); return }
        log("通知已开启")
        beginFlow()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error { log("收包异常：\(error.localizedDescription)"); return }
        guard let data = characteristic.value, !data.isEmpty else { return }
        rxBuf.append(contentsOf: [UInt8](data))
        pump()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            let done = pendingDone
            pendingDone = nil
            pendingChunks = []
            done?(error)
            return
        }
        pendingIndex += 1
        if pendingIndex < pendingChunks.count {
            peripheral.writeValue(pendingChunks[pendingIndex], for: characteristic, type: .withResponse)
        } else {
            pendingChunks = []
            pendingIndex = 0
            let done = pendingDone
            pendingDone = nil
            done?(nil)
        }
    }
}
