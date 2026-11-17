//
//  BLECentral.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/15.
//


import Foundation
import CoreBluetooth

@MainActor
public final class BLECentral: NSObject
{
    private let messageAssembler = BLEMessageAssembler()
    public weak var delegate: BLECentralDelegate?
    private var centralManager: CBCentralManager!
    private var discoveredPeripherals:[UUID: CBPeripheral] = [:]
    // 通知購読の設定処理中
    private var subscribingNotificationDevices = Set<UUID>()
    // サービス探索中のデバイス
    private var discoveringServiceDevices = Set<UUID>()
    // 探索中に追加のサービス変更が発生したデバイス
    private var pendingServiceRediscoveryDevices = Set<UUID>()
    // 切断処理中のデバイス
    private var disconnectingDevices: Set<UUID> = []
    public let connection = BLEConnection()
    private var messageCharacteristics:[UUID: CBCharacteristic] = [:]
    
    private var retryCounts: [UUID: Int] = [:]
    private let maxRetryCount = 3
    
    public var isScanning: Bool {
        centralManager.isScanning
    }
    
    private let outgoingPacketQueue = BLEOutgoingPacketQueue()
    
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
        else {
            return
        }

        // 切断処理中として登録
        disconnectingDevices.insert(deviceID)

        // 明示的な切断によって未完了となった送信を通知
        let disconnectError = NSError(
            domain: "BLEChatKit",
            code: 1003,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "BLE connection was disconnected by the application."
            ]
        )
        
        print(
            "[BLEChatKit] Pending packets before disconnect:",
            outgoingPacketQueue.count(for: deviceID)
        )
        
        print(
            "[BLEChatKit] Pending message IDs:",
            outgoingPacketQueue.messageIDs(for: deviceID)
        )

        failPendingMessages(
            for: deviceID,
            error: disconnectError
        )
        // 接続状態を更新
        connection.updateState(for: peripheral,
                               to: .disconnecting)

        // BLE接続を切断
        centralManager.cancelPeripheralConnection(peripheral)
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
    
#if DEBUG
public func debugDisableNotification(for deviceID: UUID) {

    guard let peripheral = discoveredPeripherals[deviceID],
          connection.state(for: deviceID) == .connected,
          let characteristic = messageCharacteristics[deviceID]
    else {
        print(
            "[BLECentral] Debug disable notification skipped:",
            deviceID
        )
        return
    }

    print(
        "[BLECentral] Debug disabling notification:",
        deviceID
    )

    peripheral.setNotifyValue(
        false,
        for: characteristic
    )
}
#endif
    
    
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

        let chunkSize = min(
            maximumLength - BLEMessagePacket.headerSize,
            Int(UInt16.max)
        )

        guard chunkSize > 0 else {
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
              messageCharacteristics[deviceID] != nil,
              !disconnectingDevices.contains(deviceID)
        else {
            throw BLETransportError.invalidMessage
        }

        let packets = try preparePackets(
            message,
            to: deviceID
        )

        print(
            "[BLECentral] Chunk count:",
            packets.count
        )

        // 各パケットに最終チャンク情報を付与
        let outgoingPackets = try packets.enumerated().map { index, packet in
            BLEOutgoingPacketQueue.OutgoingPacket(
                messageID: packet.messageID,
                data: try packet.encode(),
                isLastChunk: index == packets.count - 1
            )
        }

        // デバイスごとの送信キューに追加
        outgoingPacketQueue.enqueue(outgoingPackets,
                                    for: deviceID)

        // 送信中でなければ送信開始
        sendNextPacket(to: deviceID)
    }
    
    private func cleanupConnection(for deviceID: UUID)
    {
        // サービス探索状態をクリア
        discoveringServiceDevices.remove(deviceID)
        // 予約された再探索もクリア
        pendingServiceRediscoveryDevices.remove(deviceID)
        // 送信待ちパケットを破棄
        outgoingPacketQueue.clear(for: deviceID)
        // 書き込み中の状態を解除
        writingDevices.remove(deviceID)
        
        messageAssembler.reset(for: deviceID)
        
        retryCounts.removeValue(forKey: deviceID)
        
        cancelWriteTimeout(for: deviceID)

        print("BLE connection cleaned:", deviceID)
    }
    
    private func failPendingMessages(for deviceID: UUID,
                                     error: Error)
    {

        // 失敗対象のメッセージIDを先に確定
        let messageIDs = outgoingPacketQueue.messageIDs(for: deviceID)

        // 通知前に送信状態をクリア
        cleanupConnection(for: deviceID)

        // キューの状態が確定してから通知
        for messageID in messageIDs {

            delegate?.centralDidFailToSend(messageID: messageID,
                                           to: deviceID,
                                           error: error)
        }
    }

    
    private func sendNextPacket(to deviceID: UUID)
    {
        guard !writingDevices.contains(deviceID),
              !disconnectingDevices.contains(deviceID),
              let peripheral = discoveredPeripherals[deviceID],
              peripheral.state == .connected,
              let characteristic = messageCharacteristics[deviceID],
              let packet = outgoingPacketQueue.peek(for: deviceID)
        else {
            return
        }
        
        // 書き込み中として登録
        writingDevices.insert(deviceID)

        // タイムアウト監視開始
        startWriteTimeout(for: deviceID)

        // パケットデータを送信
        peripheral.writeValue(packet.data,
                              for: characteristic,
                              type: .withResponse)
    }

    private func cancelWriteTimeout(for deviceID: UUID)
    {
        writeTimeoutTasks[deviceID]?.cancel()
        writeTimeoutTasks.removeValue(forKey: deviceID)
    }
    
    private func startWriteTimeout(for deviceID: UUID) {

        cancelWriteTimeout(for: deviceID)

        
        let task = DispatchWorkItem { [weak self] in

            guard let self else { return }

            guard self.writingDevices.contains(deviceID),
                  !self.disconnectingDevices.contains(deviceID)
            else {
                return
            }

            print("BLE write timeout:", deviceID)

            // 切断処理中にする
            self.disconnectingDevices.insert(deviceID)

            let error = NSError(
                domain: "BLEChatKit",
                code: 1001,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "BLE write operation timed out."
                ]
            )

            // キュー内の全メッセージに失敗通知
            self.failPendingMessages(
                for: deviceID,
                error: error
            )

            // cleanupConnectionで削除される場合に備えて再登録
            self.disconnectingDevices.insert(deviceID)

            // BLE接続を切断
            if let peripheral = self.discoveredPeripherals[deviceID],
               peripheral.state != .disconnected {

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

extension BLECentral: @preconcurrency CBCentralManagerDelegate
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

        // サービス探索状態を初期化
        discoveringServiceDevices.remove(deviceID)
        pendingServiceRediscoveryDevices.remove(deviceID)

        // サービス探索中として登録
        discoveringServiceDevices.insert(deviceID)

        // サービス探索を開始
        print(
            "[BLECentral] discoverServices:",
            deviceID
        )

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

    

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let deviceID = peripheral.identifier

        disconnectingDevices.remove(deviceID)

        // サービス探索状態をクリア
        discoveringServiceDevices.remove(deviceID)
        pendingServiceRediscoveryDevices.remove(deviceID)

        // 通知購読中の状態をクリア
        subscribingNotificationDevices.remove(deviceID)

        // Characteristicを削除
        messageCharacteristics.removeValue(forKey: deviceID)

        print("[BLECentral] Disconnected:", deviceID)

        // 未完了メッセージを確認
        let pendingMessageIDs =
            outgoingPacketQueue.messageIDs(for: deviceID)

        print(
            "[BLECentral] Pending messages:",
            pendingMessageIDs.count
        )

        // 未完了メッセージがある場合のみ失敗処理
        if !pendingMessageIDs.isEmpty {

            let disconnectError = error ?? NSError(
                domain: "BLEChatKit",
                code: 1002,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "BLE connection disconnected before sending completed."
                ]
            )

            print(
                "[BLECentral] Pending send failed:",
                disconnectError.localizedDescription
            )

            failPendingMessages(
                for: deviceID,
                error: disconnectError
            )
        }

        // 接続状態を更新
        connection.updateState(
            for: peripheral,
            to: .disconnected
        )

        // 実際の切断エラーがある場合のみ通知
        if let error {
            print(
                "[BLECentral] Disconnect error:",
                error.localizedDescription
            )

            connection.delegate?.connectionDidFail(
                deviceID: deviceID,
                error: error
            )
        }

        delegate?.centralDidDisconnect(deviceID: deviceID)
    }
}



extension BLECentral: @preconcurrency CBPeripheralDelegate
{

    public func peripheral(
        _ peripheral: CBPeripheral,
        didModifyServices invalidatedServices: [CBService]
    ) {
        let deviceID = peripheral.identifier

        print(
            "[BLECentral] Services modified:",
            deviceID
        )

        for service in invalidatedServices {
            print(
                "[BLECentral] Invalidated service:",
                service.uuid
            )
        }

        // BLEChatKitのサービスが無効化された場合のみ処理
        guard invalidatedServices.contains(where: {
            $0.uuid == BLEUUID.service
        }) else {
            return
        }

        // 古いCharacteristicを削除
        messageCharacteristics.removeValue(forKey: deviceID)

        // 通知購読中の状態を解除
        subscribingNotificationDevices.remove(deviceID)

        print(
            "[BLECentral] Notification state cleared:",
            deviceID
        )

        // Ready状態を解除
        delegate?.centralDidInvalidateService(
            deviceID: deviceID
        )

        // すでにサービス探索中なら再探索を予約
        guard !discoveringServiceDevices.contains(deviceID)
        else {
            pendingServiceRediscoveryDevices.insert(deviceID)

            print(
                "[BLECentral] Rediscovery pending:",
                deviceID
            )
            return
        }

        // サービス探索中として登録
        discoveringServiceDevices.insert(deviceID)

        print(
            "[BLECentral] Rediscovering services:",
            deviceID
        )

        peripheral.discoverServices([
            BLEUUID.service
        ])
    }
    
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

        guard !disconnectingDevices.contains(deviceID),
              writingDevices.contains(deviceID),
              let packet = outgoingPacketQueue.peek(for: deviceID)
        else {
            return
        }

        // 書き込み応答を受信したのでタイマー解除
        cancelWriteTimeout(for: deviceID)

        // MARK: - 書き込み失敗
        if let error {

            let retryCount = retryCounts[deviceID] ?? 0
            guard retryCount < maxRetryCount
            else
            {
                print("BLE send failed:", deviceID, error)

                // 切断処理中として登録
                disconnectingDevices.insert(deviceID)

                // キュー内の全メッセージに失敗通知
                // 通知前に送信状態もクリアされる
                failPendingMessages(for: deviceID,
                                    error: error)

                // 接続状態を更新して切断
                if peripheral.state != .disconnected {

                    connection.updateState(for: peripheral,
                                           to: .disconnecting)

                    centralManager.cancelPeripheralConnection(peripheral)
                }

                return
            }


            retryCounts[deviceID] = retryCount + 1

            print("BLE retry:",retryCount + 1,"/",maxRetryCount)

            // 同じチャンクを再送
            startWriteTimeout(for: deviceID)

            peripheral.writeValue(packet.data,
                                  for: characteristic,
                                  type: .withResponse)

            return
        }

        // MARK: - 書き込み成功

        retryCounts.removeValue(forKey: deviceID)

        // 送信済みチャンクをキューから削除
        outgoingPacketQueue.dequeue(for: deviceID)

        // 書き込み状態を解除
        writingDevices.remove(deviceID)

        // メッセージの最終チャンクなら通知
        if packet.isLastChunk
        {
            delegate?.centralDidFinishSending(messageID: packet.messageID,
                                              to: deviceID)
        }

        // 次のチャンクを送信
        sendNextPacket(to: deviceID)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverServices error: Error?)
    {
        let deviceID = peripheral.identifier

        // サービス探索完了
        discoveringServiceDevices.remove(deviceID)

        // 探索中にサービス変更が発生していた場合
        if pendingServiceRediscoveryDevices.remove(deviceID) != nil {

            // 再探索中として登録
            discoveringServiceDevices.insert(deviceID)

            print(
                "[BLECentral] Executing pending rediscovery:",
                deviceID
            )

            peripheral.discoverServices([
                BLEUUID.service
            ])

            return
        }

        guard error == nil,
              let services = peripheral.services
        else {
            print(
                "[BLECentral] Service discovery failed:",
                String(describing: error)
            )
            return
        }

        print(
            "[BLECentral] Service count:",
            services.count
        )

        for service in services {
            print(
                "[BLECentral] Service UUID:",
                service.uuid
            )
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
            let deviceID = peripheral.identifier

            messageCharacteristics[deviceID] = characteristic

            // 通知購読の設定処理中なら重複要求しない
            guard !subscribingNotificationDevices.contains(deviceID)
            else {
                print(
                    "[BLECentral] Notification subscription pending:",
                    deviceID
                )
                continue
            }

            // すでに通知購読済みなら再要求しない
            guard !characteristic.isNotifying
            else {
                print(
                    "[BLECentral] Already notifying:",
                    deviceID
                )
                continue
            }

            // 通知購読処理中として登録
            subscribingNotificationDevices.insert(deviceID)

            print("[BLECentral] setNotifyValue:", deviceID)

            peripheral.setNotifyValue(
                true,
                for: characteristic
            )
        }
    }
    
    
    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let deviceID = peripheral.identifier

        print("[BLECentral] Notification state updated:", deviceID)
        print("[BLECentral] Characteristic UUID:", characteristic.uuid)
        print("[BLECentral] Is notifying:", characteristic.isNotifying)

        // 対象Characteristic以外は処理しない
        guard characteristic.uuid == BLEUUID.message else {
            return
        }

        // 現在管理しているCharacteristicと同じインスタンスか確認
        guard let currentCharacteristic = messageCharacteristics[deviceID],
              currentCharacteristic === characteristic
        else {
            print(
                "[BLECentral] Ignoring stale notification callback:",
                deviceID
            )
            return
        }

        // 現在のCharacteristicに対する購読処理が完了
        subscribingNotificationDevices.remove(deviceID)

        if let error {
            print(
                "[BLECentral] Notification error:",
                error
            )

            // 通知購読状態を確認
            if !characteristic.isNotifying {
                delegate?.centralDidBecomeNotReady(
                    deviceID: deviceID
                )
            }

            return
        }

        guard characteristic.isNotifying else {

            print(
                "[BLECentral] Notification disabled:",
                deviceID
            )

            delegate?.centralDidBecomeNotReady(
                deviceID: deviceID
            )

            return
        }

        delegate?.centralDidBecomeReady(deviceID: deviceID)    }
    
    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?)
    {
        print(
            "[BLECentral] didUpdateValueFor:",
            characteristic.uuid,
            "bytes:",
            characteristic.value?.count ?? 0,
            "error:",
            String(describing: error)
        )
        
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
