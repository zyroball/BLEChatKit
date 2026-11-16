//
//  BLEChatManager.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/15.
//


import Foundation

public final class BLEChatManager
{

    public weak var delegate: BLEChatManagerDelegate?

    private let central: BLECentral
    private let peripheral: BLEPeripheral
    private var centralDeviceIDs = Set<UUID>()
    private var readyCentralDeviceIDs = Set<UUID>()
    
    public var onSendCompleted: ((_ messageID: UUID,
                                  _ deviceID: UUID) -> Void)?
    
    
    public var onSendFailed: ((_ messageID: UUID?,
                               _ deviceID: UUID,
                               _ error: Error) -> Void)?


    private var peripheralCentralIDs = Set<UUID>()

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

    public func start()
    {
        shouldRun = true

        if isCentralReady
        {
            central.startScan()
        }

        if isPeripheralReady
        {
            peripheral.startAdvertising()
        }
    }

    public func stop() {
        shouldRun = false

        central.stopScan()
        peripheral.stopAdvertising()
    }

    public func connect(to deviceID: UUID) {
        central.connect(to: deviceID)
    }

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
}


extension BLEChatManager: BLECentralDelegate
{
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
            // Central側のデバイス情報をクリア
            centralDeviceIDs.removeAll()
            readyCentralDeviceIDs.removeAll()
        }

        delegate?.chatManagerDidUpdateBluetoothState(state)

        if shouldRun && isCentralReady
        {
            central.startScan()
        }
    }
    
    public func centralDidFailToSend(messageID: UUID,
                                     to deviceID: UUID,
                                     error: Error)
    {
        print("BLE send failed:",messageID,deviceID,error)
        
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
    
    public func centralDidBecomeReady(deviceID: UUID)
    {
        // 通信準備が完了したデバイスを登録
        readyCentralDeviceIDs.insert(deviceID)

        delegate?.chatManagerDidBecomeReady(deviceID: deviceID)
    }

}


extension BLEChatManager: BLEConnectionDelegate
{
    
    public func connectionDidChangeState(deviceID: UUID,
                                         state: BLEConnectionState)
    {
        switch state {

        case .disconnecting:
            // 切断開始時点で送信を禁止
            readyCentralDeviceIDs.remove(deviceID)

        case .disconnected:
            // 切断完了時にデバイス情報を削除
            readyCentralDeviceIDs.remove(deviceID)
            centralDeviceIDs.remove(deviceID)

        default:
            break
        }

        // アプリ側へ接続状態を通知
        delegate?.chatManagerDidChangeConnectionState(deviceID: deviceID,
                                                      state: state)
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
        peripheralCentralIDs.insert(centralID)
    }

    public func peripheralDidUnsubscribe(
        centralID: UUID
    ) {
        peripheralCentralIDs.remove(centralID)
    }

    public func peripheralDidStartAdvertising() {
        // 必要なら広告開始イベントを公開する
    }

    public func peripheralDidFailToAdvertise(
        error: Error
    ) {
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
