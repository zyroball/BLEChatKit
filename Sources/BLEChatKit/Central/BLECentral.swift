//
//  BLECentral.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/15.
//


import Foundation
import CoreBluetooth

public final class BLECentral: NSObject
{
    private let messageAssembler = BLEMessageAssembler()
    public weak var delegate: BLECentralDelegate?
    private var centralManager: CBCentralManager!
    private var discoveredPeripherals:[UUID: CBPeripheral] = [:]
    // 切断処理中のデバイス
    private var disconnectingDevices: Set<UUID> = []
    public let connection = BLEConnection()
    private var messageCharacteristics:[UUID: CBCharacteristic] = [:]
    
    private var retryCounts: [UUID: Int] = [:]
    private let maxRetryCount = 3
    
    private var packetQueues: [UUID: [Data]] = [:]
    private var writingDevices: Set<UUID> = []
    
    private var writeTimeoutTasks: [UUID: DispatchWorkItem] = [:]
    private let writeTimeout: TimeInterval = 10

    public override init()
    {
        super.init()

        centralManager = CBCentralManager(
            delegate: self,
            queue: nil
        )
    }


    public func startScan()
    {
        guard centralManager.state == .poweredOn
        else
        {
            return
        }
        centralManager.scanForPeripherals(
            withServices: [BLEUUID.service],
            options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: false
            ]
        )
    }

    public func stopScan()
    {
        centralManager.stopScan()
    }
    
    public func connect(to deviceID: UUID)
    {
        guard centralManager.state == .poweredOn,
              let peripheral = discoveredPeripherals[deviceID]
        else
        {
            return
        }

        guard connection.state(for: deviceID) == .disconnected
        else
        {
            return
        }

        connection.updateState(for: peripheral,
                               to: .connecting)
        centralManager.connect(peripheral,
                               options: nil)
    }

    public func disconnect(from deviceID: UUID)
    {
        guard let peripheral = discoveredPeripherals[deviceID]
        else {
            return
        }

        guard connection.state(for: deviceID) == .connected
            || connection.state(for: deviceID) == .connecting
        else
        {
            return
        }

        connection.updateState(
            for: peripheral,
            to: .disconnecting
        )

        centralManager.cancelPeripheralConnection(
            peripheral
        )
    }
    
    
    public func send(_ message: String,
                     to deviceID: UUID) throws
    {
        guard let peripheral = discoveredPeripherals[deviceID],peripheral.state == .connected, let characteristic = messageCharacteristics[deviceID]
        else
        {
            throw BLETransportError.invalidMessage
        }

        let data = try BLETransport.encode(message)

        guard data.count <= peripheral.maximumWriteValueLength(for: .withResponse)
        else
        {
            throw BLETransportError.messageTooLarge
        }

        peripheral.writeValue(data,
                              for: characteristic,
                              type: .withResponse)
    }
    
    
    public func preparePackets(_ message: String,
                               to deviceID: UUID) throws -> [BLEMessagePacket]
    {
        guard let peripheral = discoveredPeripherals[deviceID],
              peripheral.state == .connected,
              messageCharacteristics[deviceID] != nil
        else {
            throw BLETransportError.invalidMessage
        }

        let maximumLength =
            peripheral.maximumWriteValueLength(
                for: .withResponse
            )

        // エンコード後のパケットサイズも考慮する。
        let chunkSize = min(maximumLength - BLEMessagePacket.headerSize,
                            Int(UInt16.max))

        guard chunkSize > 0
        else
        {
            throw BLETransportError.messageTooLarge
        }

        guard chunkSize > 0
        else
        {
            throw BLETransportError.messageTooLarge
        }

        let packets = try BLEMessagePacketBuilder.build(message: message,
                                                        chunkSize: chunkSize)

        // 実際に送信可能なサイズか検証
        for packet in packets
        {
            let encodedData = try packet.encode()

            guard encodedData.count <= maximumLength
            else
            {
                throw BLETransportError.messageTooLarge
            }
        }

        return packets
    }
    
    
    public func sendChunked(_ message: String,
                            to deviceID: UUID) throws
    {
        guard let peripheral = discoveredPeripherals[deviceID],
              peripheral.state == .connected,
              messageCharacteristics[deviceID] != nil
        else {
            throw BLETransportError.invalidMessage
        }

        let packets = try preparePackets(
            message,
            to: deviceID
        )

        let encodedPackets = try packets.map
        {
            try $0.encode()
        }

        packetQueues[deviceID, default: []]
            .append(contentsOf: encodedPackets)

        sendNextPacket(to: deviceID)
    }
    
    
    private func cleanupConnection(for deviceID: UUID)
    {
        // 送信待ちパケットを破棄
        packetQueues.removeValue(forKey: deviceID)

        // 書き込み中の状態を解除
        writingDevices.remove(deviceID)
        
        messageAssembler.reset(for: deviceID)
        
        retryCounts.removeValue(forKey: deviceID)
        
        cancelWriteTimeout(for: deviceID)

        print("BLE connection cleaned:", deviceID)
    }
    
    
    private func sendNextPacket(to deviceID: UUID)
    {
        guard !writingDevices.contains(deviceID),
              !disconnectingDevices.contains(deviceID),
              let peripheral = discoveredPeripherals[deviceID],
              peripheral.state == .connected,
              let characteristic = messageCharacteristics[deviceID],
              let packet = packetQueues[deviceID]?.first
        else {
            return
        }

        writingDevices.insert(deviceID)

        // ★ タイムアウト監視開始
        startWriteTimeout(for: deviceID)

        peripheral.writeValue(packet,
                              for: characteristic,
                              type: .withResponse)
    }

    
    private func cancelWriteTimeout(for deviceID: UUID)
    {
        writeTimeoutTasks[deviceID]?.cancel()
        writeTimeoutTasks.removeValue(forKey: deviceID)
    }
    
    
    
    private func startWriteTimeout(for deviceID: UUID)
    {

        cancelWriteTimeout(for: deviceID)

        let task = DispatchWorkItem
        {
            [weak self] in

            guard let self else { return }

            guard self.writingDevices.contains(deviceID),
                  !self.disconnectingDevices.contains(deviceID)
            else {
                return
            }

            print("BLE write timeout:", deviceID)

            // 切断処理中にする
            self.disconnectingDevices.insert(deviceID)

            // 送受信状態をクリア
            self.cleanupConnection(for: deviceID)

            // BLE接続を切断
            if let peripheral = self.discoveredPeripherals[deviceID],
               peripheral.state != .disconnected
            {

                self.centralManager.cancelPeripheralConnection(
                    peripheral
                )
            }
        }

        writeTimeoutTasks[deviceID] = task

        DispatchQueue.main.asyncAfter(deadline: .now() + writeTimeout,
                                      execute: task)
    }


}

// MARK: - CBCentralManagerDelegate

extension BLECentral: CBCentralManagerDelegate
{

    public func centralManagerDidUpdateState(_ central: CBCentralManager)
    {
        let state: BLECentralState

        switch central.state
        {
        case .unknown:
            state = .unknown
        case .resetting:
            state = .resetting
        case .unsupported:
            state = .unsupported
        case .unauthorized:
            state = .unauthorized
        case .poweredOff:
            state = .poweredOff
        case .poweredOn:
            state = .poweredOn
        @unknown default:
            state = .unknown
        }

        delegate?.centralDidUpdateState(state)
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber)
    {
        discoveredPeripherals[peripheral.identifier] = peripheral

        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String

        let device = BLEDevice(id: peripheral.identifier,
                               name: advertisedName ?? peripheral.name,
                               rssi: RSSI.intValue)
        delegate?.centralDidDiscover(device)
    }

    public func centralManager(_ central: CBCentralManager,
                               didConnect peripheral: CBPeripheral)
    {
        let deviceID = peripheral.identifier

        // 再接続時に古い送受信状態をクリア
        cleanupConnection(for: deviceID)

        // 切断処理中の状態を解除
        disconnectingDevices.remove(deviceID)

        // PeripheralのDelegateを設定
        peripheral.delegate = self

        // 接続状態を更新
        connection.updateState(
            for: peripheral,
            to: .connected
        )

        // サービス探索を開始
        peripheral.discoverServices([
            BLEUUID.service
        ])

        print("BLE connected:", deviceID)
    }


    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral,
                               error: Error?)
    {
        connection.notifyFailure(for: peripheral,
                                 error: error)
    }

    

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?)
    {
        let deviceID = peripheral.identifier
        
        disconnectingDevices.remove(peripheral.identifier)

        // メッセージCharacteristicを削除
        messageCharacteristics.removeValue(forKey: deviceID)

        // ★ 追加：送信キューをクリーンアップ
        cleanupConnection(for: deviceID)

        // 接続状態を更新
        connection.updateState(for: peripheral,
                               to: .disconnected)

        // エラーがある場合は通知
        if let error
        {
            connection.delegate?.connectionDidFail(deviceID: deviceID,
                                                   error: error)
        }
    }
}



extension BLECentral: CBPeripheralDelegate
{
    public func peripheral(_ peripheral: CBPeripheral,
                           didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?)
    {
        guard characteristic.uuid == BLEUUID.message
        else
        {
            return
        }

        let deviceID = peripheral.identifier

        // 切断処理中、または送信中でなければ無視
        guard !disconnectingDevices.contains(deviceID),
              writingDevices.contains(deviceID)
        else {
            return
        }

        // 書き込み応答を受信したのでタイマー解除
        cancelWriteTimeout(for: deviceID)

        // 書き込み失敗
        if let error = error
        {

            let retryCount = retryCounts[deviceID] ?? 0

            // 最大再送回数に達した場合
            guard retryCount < maxRetryCount
            else
            {

                print("BLE send failed:", deviceID, error)

                // ★ 追加：アプリ側へ送信失敗を通知
                delegate?.centralDidFailToSend(
                    to: deviceID,
                    error: error
                )

                // 送信状態をクリア
                packetQueues.removeValue(forKey: deviceID)
                writingDevices.remove(deviceID)
                retryCounts.removeValue(forKey: deviceID)

                return
            }

            // 再送回数を更新
            retryCounts[deviceID] = retryCount + 1

            print(
                "BLE retry:",
                retryCount + 1,
                "/",
                maxRetryCount
            )

            // 同じパケットを再送
            if let data = packetQueues[deviceID]?.first
            {

                startWriteTimeout(for: deviceID)

                peripheral.writeValue(
                    data,
                    for: characteristic,
                    type: .withResponse
                )
            }

            return
        }

        // 書き込み成功
        retryCounts.removeValue(forKey: deviceID)

        // 送信済みパケットを削除
        if packetQueues[deviceID]?.isEmpty == false
        {
            packetQueues[deviceID]?.removeFirst()
        }

        // 送信状態を解除
        writingDevices.remove(deviceID)

        // 次のパケットへ
        sendNextPacket(to: deviceID)
    }


    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverServices error: Error?)
    {
        guard error == nil,
              let services = peripheral.services
        else {
            return
        }

        for service in services
        where service.uuid == BLEUUID.service
        {
            peripheral.discoverCharacteristics([BLEUUID.message],
                                               for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?)
    {
        guard error == nil,
              let characteristics = service.characteristics
        else {
            return
        }

        for characteristic in characteristics
        where characteristic.uuid == BLEUUID.message
        {
            messageCharacteristics[
                peripheral.identifier
            ] = characteristic
            
            peripheral.setNotifyValue(true,
                                      for: characteristic)
        }
    }
    
    
    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?)
    {
        guard error == nil,
              characteristic.uuid == BLEUUID.message,
              characteristic.isNotifying
        else {
            return
        }
        delegate?.centralDidBecomeReady(
            deviceID: peripheral.identifier
        )
    }
    
    
    
    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?)
    {
        guard error == nil,
              characteristic.uuid == BLEUUID.message,
              let data = characteristic.value
        else
        {
            return
        }

        do
        {
            // 分割パケットとしてデコード
            if BLEMessagePacket.isPacket(data)
            {
                let packet = try BLEMessagePacket.decode(from: data)

                guard let restoredData = messageAssembler.append(packet,
                                                                 from: peripheral.identifier)
                else
                {
                    return
                }

                let message = try BLETransport.decode(restoredData)

                delegate?.centralDidReceiveMessage(message,
                                                   from: peripheral.identifier)
            }
            else
            {
                let message = try BLETransport.decode(data)

                delegate?.centralDidReceiveMessage(message,
                                                   from: peripheral.identifier)
            }
        }
        catch
        {
            print("BLE message decode error: \(error)")
        }
    }

}
