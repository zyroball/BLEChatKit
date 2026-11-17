//
//
//  BLEChatManager.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/15.
//


import Foundation

@MainActor
public final class BLEChatManager
{

    public weak var delegate: BLEChatManagerDelegate?

    private let central: BLECentral
    private let peripheral: BLEPeripheral
    private var centralDeviceIDs = Set<UUID>()
    private var readyCentralDeviceIDs = Set<UUID>()
    private var connectionStates: [UUID: BLEConnectionState] = [:]
    
    public var onSendCompleted: ((_ messageID: UUID,
                                  _ deviceID: UUID) -> Void)?
    
    
    public var onSendFailed: ((_ messageID: UUID?,
                               _ deviceID: UUID,
                               _ error: Error) -> Void)?


    private var peripheralCentralIDs = Set<UUID>()
    
    /// 現在、通信準備が完了しているデバイスID
    public var readyDeviceIDs: Set<UUID> {
        readyCentralDeviceIDs.union(peripheralCentralIDs)
    }
    
    public var isScanning: Bool {
        central.isScanning
    }

    private var shouldRun = false
    private var isCentralReady = false
    private var isPeripheralReady = false

    public init() {
        central = BLECentral()
        peripheral = BLEPeripheral()

        central.delegate = self
        central.connection.delegate = self
        peripheral.delegate = self
    }

    public func start() {

        shouldRun = true

        if isCentralReady {
            central.startScan()
        }

        if isPeripheralReady {
            peripheral.startAdvertising()
        }
    }

    /// BLEデバイスのスキャンと広告を停止する。
    ///
    /// 既存のBLE接続は切断しない。
    /// 接続を切断する場合は disconnect(from:) を使用する。
    public func stop() {
        shouldRun = false

        central.stopScan()
        peripheral.stopAdvertising()
    }

    public func connect(to deviceID: UUID) {
        central.connect(to: deviceID)
    }
    
    /// 指定したデバイスが送信可能か判定する
    public func isReady(for deviceID: UUID) -> Bool
    {
        // Central側で通信準備が完了している
        if readyCentralDeviceIDs.contains(deviceID) {
            return true
        }

        // Peripheral側で通知購読されている
        if peripheralCentralIDs.contains(deviceID) {
            return true
        }

        return false
    }

    /// 指定したデバイスとのCentral側の接続を切断する。
    ///
    /// - Parameter deviceID: 切断対象のデバイスID
    ///
    /// 切断処理は非同期で行われる。
    /// 実際の状態変更はDelegateで通知される。
    public func disconnect(from deviceID: UUID) {
        central.disconnect(from: deviceID)
    }

    
    @discardableResult
    public func send(_ message: String,
                     to deviceID: UUID) throws -> Bool
    {
        let canSendAsCentral =
            readyCentralDeviceIDs.contains(deviceID)

        let canSendAsPeripheral =
            peripheralCentralIDs.contains(deviceID)

        // 両方の送信経路が存在する場合
        // Central側を優先する
        if canSendAsCentral
        {
            print("[BLEChatKit] Central chunked send:", deviceID)
            try central.sendChunked(message, to: deviceID)

            return true
        }

        // Peripheral側の通知送信
        if canSendAsPeripheral
        {
            return try peripheral.send(message,to: deviceID)
        }

        // 送信できる経路がない
        return false
    }
    
    /// Central側のBLE接続状態を取得する。
    ///
    /// Peripheral側の購読状態は含まない。
    /// Peripheral側のみで通信している場合、
    /// .disconnected を返すことがある。
    ///
    /// 送信可能かどうかは isReady(for:) で判定する。
    public func connectionState(for deviceID: UUID) -> BLEConnectionState
    {
        connectionStates[deviceID] ?? .disconnected
    }
}


extension BLEChatManager: BLECentralDelegate
{
    public func centralDidDisconnect(deviceID: UUID) {

        // Central側のReady状態を解除
        readyCentralDeviceIDs.remove(deviceID)

        // 接続デバイスの登録を解除
        centralDeviceIDs.remove(deviceID)

        // 接続状態の更新と通知は
        // connectionDidChangeState に一本化する
    }
    
    public func centralDidFinishSending(messageID: UUID,
                                        to deviceID: UUID)
    {

        print("BLE message sent:",messageID,"to:",deviceID)

        onSendCompleted?(messageID,deviceID)
    }

    
    public func centralDidUpdateState(_ state: BLECentralState)
    {
        isCentralReady = (state == .poweredOn)

        if !isCentralReady
        {

            centralDeviceIDs.removeAll()
            readyCentralDeviceIDs.removeAll()

            // 接続中だったデバイスを切断状態へ変更
            for deviceID in Array(connectionStates.keys)
            {

                guard connectionStates[deviceID] != .disconnected
                else {
                    continue
                }

                connectionDidChangeState(deviceID: deviceID,
                                         state: .disconnected
                )
            }
        }

        delegate?.chatManagerDidUpdateBluetoothState(state)

        if shouldRun && isCentralReady
        {
            central.startScan()
        }
    }
    
    public func centralDidFailToSend(
        messageID: UUID,
        to deviceID: UUID,
        error: Error
    ) {
        print("[BLEChatKit] Send failed")
        print("[BLEChatKit] Message ID:", messageID)
        print("[BLEChatKit] Device ID:", deviceID)
        print("[BLEChatKit] Error:", error.localizedDescription)

        onSendFailed?(messageID, deviceID, error)
    }
    
    public func centralDidDiscover(
        _ device: BLEDevice
    ) {
        centralDeviceIDs.insert(device.id)

        delegate?.chatManagerDidDiscover(device)
    }


    public func centralDidReceiveMessage(
        _ message: String,
        from deviceID: UUID
    ) {
        delegate?.chatManagerDidReceiveMessage(
            message,
            from: deviceID
        )
    }
    
    public func centralDidBecomeReady(deviceID: UUID) {

        let inserted = readyCentralDeviceIDs.insert(deviceID).inserted

        print(
            "[BLEChatManager] Central Ready:",
            deviceID,
            "inserted:",
            inserted
        )

        guard inserted else {
            return
        }

        delegate?.chatManagerDidBecomeReady(deviceID: deviceID)
    }
}


extension BLEChatManager: BLEConnectionDelegate
{
    
    public func connectionDidChangeState(
        deviceID: UUID,
        state: BLEConnectionState
    ) {
        // 同じ状態なら通知しない
        guard connectionStates[deviceID] != state else {
            return
        }

        // 接続状態を更新
        connectionStates[deviceID] = state

        switch state {

        case .disconnecting:
            readyCentralDeviceIDs.remove(deviceID)

        case .disconnected:
            readyCentralDeviceIDs.remove(deviceID)
            centralDeviceIDs.remove(deviceID)

        default:
            break
        }

        // アプリ側へ状態変更を通知
        delegate?.chatManagerDidChangeConnectionState(
            deviceID: deviceID,
            state: state
        )
    }

    public func connectionDidFail(
        deviceID: UUID,
        error: Error?
    ) {
        // 接続失敗したデバイスを送信可能一覧から削除
        readyCentralDeviceIDs.remove(deviceID)

        if let error {
            delegate?.chatManagerDidFail(error)
        }
    }
}


extension BLEChatManager: BLEPeripheralDelegate
{
    public func peripheralDidUpdateState(_ state: BLEPeripheralState)
    {

        isPeripheralReady = (state == .poweredOn)

        if !isPeripheralReady
        {
            // Peripheral側の購読デバイス情報をクリア
            peripheralCentralIDs.removeAll()
        }

        if shouldRun && isPeripheralReady
        {
            peripheral.startAdvertising()
        }
    }

    
    public func peripheralDidFailToSend(to centralID: UUID,
                                 error: Error)
    {
        print("BLE peripheral send failed:", centralID, error)

           onSendFailed?(nil, centralID, error)
    }
    
    public func peripheralDidSubscribe(
        centralID: UUID
    ) {
        let inserted = peripheralCentralIDs.insert(centralID).inserted

        guard inserted else {
            return
        }

        print(
            "[BLEChatManager] Peripheral Ready:",
            centralID
        )

        delegate?.chatManagerDidBecomeReady(
            deviceID: centralID
        )
    }

    public func peripheralDidUnsubscribe(
        centralID: UUID
    ) {
        peripheralCentralIDs.remove(centralID)
    }

    public func peripheralDidStartAdvertising() {
        print("[BLEChatKit] Advertising started")
    }

    public func peripheralDidFailToAdvertise(
        error: Error
    ) {
        print("[BLEChatKit] Advertising failed:", error)

        delegate?.chatManagerDidFail(error)
    }
    
    public func peripheralDidReceiveMessage(
        _ message: String,
        from centralID: UUID
    ) {
        delegate?.chatManagerDidReceiveMessage(
            message,
            from: centralID
        )
    }
}
