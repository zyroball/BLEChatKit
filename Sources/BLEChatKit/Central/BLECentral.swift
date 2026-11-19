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
    private struct PendingAcknowledgment {
        let messageID: UUID
        let deviceID: UUID
        let packets: [BLEOutgoingPacketQueue.OutgoingPacket]
        var retryCount: Int
    }

    private var pendingAcknowledgments:
        [UUID: [UUID: PendingAcknowledgment]] = [:]
    private let messageAssembler = BLEMessageAssembler()
    public weak var delegate: BLECentralDelegate?
    private var centralManager: CBCentralManager!
    private var discoveredPeripherals:[UUID: CBPeripheral] = [:]
    private var writeTimeoutIDs: [UUID: UUID] = [:]
    private let acknowledgmentTimeout: TimeInterval = 30
    private var acknowledgmentTimeoutTasks:
        [UUID: [UUID: Task<Void, Never>]] = [:]
    private let maxAcknowledgmentRetryCount = 3
    // 通知購読の設定処理中
    private var subscribingNotificationDevices = Set<UUID>()
    private var subscribingCharacteristics: [UUID: CBCharacteristic] = [:]
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
        guard centralManager.state == .poweredOn,
                 !centralManager.isScanning
           else {
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
    
    private func cancelAcknowledgmentTimeout(
        messageID: UUID,
        for deviceID: UUID
    ) {
        acknowledgmentTimeoutTasks[deviceID]?
            .removeValue(forKey: messageID)?
            .cancel()

        if acknowledgmentTimeoutTasks[deviceID]?.isEmpty == true {
            acknowledgmentTimeoutTasks.removeValue(forKey: deviceID)
        }
    }
    
    private func startAcknowledgmentTimeout(
        messageID: UUID,
        for deviceID: UUID
    ) {
        cancelAcknowledgmentTimeout(
            messageID: messageID,
            for: deviceID
        )

        let timeout = acknowledgmentTimeout

        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(timeout * 1_000_000_000)
            )

            guard !Task.isCancelled else {
                return
            }

            guard let self,
                  self.pendingAcknowledgments[deviceID]?[messageID] != nil
            else {
                return
            }

            print(
                "[BLECentral] ACK timeout:",
                messageID,
                "device:",
                deviceID
            )
            self.retryPendingAcknowledgment(
                messageID: messageID,
                for: deviceID
            )
        }

        acknowledgmentTimeoutTasks[deviceID, default: [:]][messageID] = task
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
    
#if DEBUG
public func debugEnableNotification(for deviceID: UUID) {

    guard let peripheral = discoveredPeripherals[deviceID],
          connection.state(for: deviceID) == .connected,
          let characteristic = messageCharacteristics[deviceID]
    else {
        print(
            "[BLECentral] Debug enable notification skipped:",
            deviceID
        )
        return
    }

    guard !characteristic.isNotifying,
          !subscribingNotificationDevices.contains(deviceID)
    else {
        return
    }

    subscribingNotificationDevices.insert(deviceID)

    // 購読要求中のCharacteristicを記録
    subscribingCharacteristics[deviceID] = characteristic

    print("[BLECentral] Debug enabling notification:", deviceID)

    peripheral.setNotifyValue(true, for: characteristic)
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

        guard let messageID = outgoingPackets.first?.messageID else {
            throw BLETransportError.invalidMessage
        }

        let pending = PendingAcknowledgment(
            messageID: messageID,
            deviceID: deviceID,
            packets: outgoingPackets,
            retryCount: 0
        )

        pendingAcknowledgments[deviceID, default: [:]][messageID] = pending
        // デバイスごとの送信キューに追加
        outgoingPacketQueue.enqueue(outgoingPackets,
                                    for: deviceID)

        // 送信中でなければ送信開始
        sendNextPacket(to: deviceID)
    }
    
    
    private func cleanupConnection(for deviceID: UUID) {

        // 書き込みタイムアウトを解除
        cancelWriteTimeout(for: deviceID)

        // 未送信パケットを破棄
        outgoingPacketQueue.clear(for: deviceID)

        // 送信中フラグを解除
        writingDevices.remove(deviceID)

        // 再送回数をリセット
        retryCounts.removeValue(forKey: deviceID)

        // Characteristicの情報を削除
        messageCharacteristics.removeValue(forKey: deviceID)

        // 通知購読中の状態を解除
        subscribingNotificationDevices.remove(deviceID)

        // 購読要求中のCharacteristicを削除
        subscribingCharacteristics.removeValue(forKey: deviceID)

        // サービス探索状態を解除
        discoveringServiceDevices.remove(deviceID)

        // 再探索待ち状態を解除
        pendingServiceRediscoveryDevices.remove(deviceID)
        
        // ACKタイムアウトをすべて解除
        if let tasks = acknowledgmentTimeoutTasks.removeValue(
            forKey: deviceID
        ) {
            for task in tasks.values {
                task.cancel()
            }
        }

        // ACK待機中のメッセージ情報を削除
        pendingAcknowledgments.removeValue(
            forKey: deviceID
        )
    }

    
    private func failPendingMessages(
        for deviceID: UUID,
        error: Error
    ) {
        // 送信キューに残っているメッセージ
        let queuedMessageIDs =
            outgoingPacketQueue.messageIDs(for: deviceID)

        // ACK待機中のメッセージ
        let pendingACKMessageIDs =
            Array(pendingAcknowledgments[deviceID]?.keys ?? [:].keys)

        // 重複を除去
        let messageIDs = Array(
            Set(queuedMessageIDs).union(pendingACKMessageIDs)
        )

        // 古い送信状態をクリア
        cleanupConnection(for: deviceID)

        // 未完了メッセージを失敗通知
        for messageID in messageIDs {
            delegate?.centralDidFailToSend(
                messageID: messageID,
                to: deviceID,
                error: error
            )
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

    private func cancelWriteTimeout(for deviceID: UUID) {

        // タイムアウトタスクをキャンセル
        writeTimeoutTasks[deviceID]?.cancel()

        // タスクの管理情報を削除
        writeTimeoutTasks.removeValue(forKey: deviceID)

        // タイムアウトIDも無効化
        writeTimeoutIDs.removeValue(forKey: deviceID)
    }
    
    private func startWriteTimeout(for deviceID: UUID) {

        cancelWriteTimeout(for: deviceID)

        // 今回のタイムアウトを識別するID
        let timeoutID = UUID()

        writeTimeoutIDs[deviceID] = timeoutID

        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }

            // 古いタイムアウトタスクは処理しない
            guard self.writeTimeoutIDs[deviceID] == timeoutID else {
                return
            }

            guard let currentTask = self.writeTimeoutTasks[deviceID],
                  !currentTask.isCancelled
            else {
                return
            }

            guard self.writingDevices.contains(deviceID),
                  !self.disconnectingDevices.contains(deviceID)
            else {
                return
            }
            print("BLE write timeout:", deviceID)

            // 切断処理中にする
            self.disconnectingDevices.insert(deviceID)

            if let peripheral = self.discoveredPeripherals[deviceID] {
                self.connection.updateState(
                    for: peripheral,
                    to: peripheral.state == .disconnected
                        ? .disconnected
                        : .disconnecting
                )
            }

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
                self.centralManager.cancelPeripheralConnection(peripheral)
            } else {
                self.disconnectingDevices.remove(deviceID)
            }
        }

        writeTimeoutTasks[deviceID] = task

        DispatchQueue.main.asyncAfter(deadline: .now() + writeTimeout,
                                      execute: task)
    }
    
    // MARK: - ACK再送上限到達時の失敗処理

    private func failPendingAcknowledgment(
        messageID: UUID,
        for deviceID: UUID
    ) {
        // ACKタイマーを解除
        cancelAcknowledgmentTimeout(
            messageID: messageID,
            for: deviceID
        )

        // ACK待機状態を削除
        guard pendingAcknowledgments[deviceID]?
            .removeValue(forKey: messageID) != nil
        else {
            return
        }

        if pendingAcknowledgments[deviceID]?.isEmpty == true {
            pendingAcknowledgments.removeValue(forKey: deviceID)
        }

        // 書き込み中の先頭パケットを保護
        let isWritingMessage =
            writingDevices.contains(deviceID) &&
            outgoingPacketQueue.peek(for: deviceID)?.messageID
                == messageID

        outgoingPacketQueue.removePackets(
            messageID: messageID,
            for: deviceID,
            preservingFirstPacket: isWritingMessage
        )

        let error = NSError(
            domain: "BLEChatKit",
            code: 1005,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "BLE acknowledgment retry limit reached."
            ]
        )

        delegate?.centralDidFailToSend(
            messageID: messageID,
            to: deviceID,
            error: error
        )

        // 別メッセージの送信を継続
        sendNextPacket(to: deviceID)
    }
    
    private func retryPendingAcknowledgment(
        messageID: UUID,
        for deviceID: UUID
    ) {
        guard var pending =
            pendingAcknowledgments[deviceID]?[messageID]
        else {
            return
        }

        guard pending.retryCount < maxAcknowledgmentRetryCount else {
            print(
                "[BLECentral] ACK retry limit reached:",
                messageID
            )

            failPendingAcknowledgment(
                messageID: messageID,
                for: deviceID
            )

            return
        }

        guard let peripheral = discoveredPeripherals[deviceID],
              peripheral.state == .connected,
              messageCharacteristics[deviceID] != nil,
              !disconnectingDevices.contains(deviceID)
        else {
            print(
                "[BLECentral] ACK retry deferred (disconnected):",
                messageID
            )
            return
        }

        // 再送パケットがキューに残っている場合は
        // 書き込み完了を待つ
        guard !outgoingPacketQueue.contains(
            messageID: messageID,
            for: deviceID
        ) else {
            print(
                "[BLECentral] ACK retry waiting for write completion:",
                messageID
            )

            // 既存キューの送信を継続
            sendNextPacket(to: deviceID)

            // ACKタイマーはここでは再起動しない
            // 最終チャンクの書き込み完了後に開始する
            return
        }
        
        pending.retryCount += 1

        pendingAcknowledgments[deviceID]?[messageID] = pending

        print(
            "[BLECentral] ACK retry:",
            pending.retryCount,
            "message:",
            messageID
        )

        // ACK未受信メッセージのパケットを再送キューへ登録
        outgoingPacketQueue.enqueue(
            pending.packets,
            for: deviceID
        )

        // 送信開始（送信中なら何もしない）
        sendNextPacket(to: deviceID)
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

        if central.state != .poweredOn
        {
            let error = NSError(
                domain: "BLEChatKit",
                code: 1003,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Bluetooth is unavailable."
                ]
            )

            cleanupAllConnections(error: error)
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

        // 再接続時に未完了メッセージが残っているか確認
        let queuedMessageIDs =
            outgoingPacketQueue.messageIDs(for: deviceID)

        let hasPendingACK =
            !(pendingAcknowledgments[deviceID]?.isEmpty ?? true)

        if !queuedMessageIDs.isEmpty || hasPendingACK {

            let error = NSError(
                domain: "BLEChatKit",
                code: 1006,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Pending messages remained when BLE reconnected."
                ]
            )

            // 未完了メッセージを失敗通知して状態をクリア
            failPendingMessages(
                for: deviceID,
                error: error
            )

        } else {

            // 未完了メッセージがなければ通常の初期化
            cleanupConnection(for: deviceID)
        }
        // 切断処理中の状態を解除
        disconnectingDevices.remove(deviceID)

        // PeripheralのDelegateを設定
        peripheral.delegate = self

        // 接続状態を更新
        connection.updateState(
            for: peripheral,
            to: .connected
        )

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

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let deviceID = peripheral.identifier
        
        // 接続失敗時は切断処理中の状態も解除
        disconnectingDevices.remove(deviceID)

        // 接続失敗時のエラーを用意
        let connectionError = error ?? NSError(
            domain: "BLEChatKit",
            code: 1004,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "BLE connection failed before sending completed."
            ]
        )

        // 未送信メッセージを失敗通知して通信状態を解放
        failPendingMessages(
            for: deviceID,
            error: connectionError
        )

        // 接続状態を切断済みに更新して失敗を通知
        connection.notifyFailure(
            for: peripheral,
            error: connectionError
        )
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

        // 切断したデバイスの分割受信バッファを破棄
        messageAssembler.reset(for: deviceID)

        print("[BLECentral] Disconnected:", deviceID)

        // 送信キューに残っているメッセージ
        let queuedMessageIDs =
            outgoingPacketQueue.messageIDs(for: deviceID)

        // ACK待機中のメッセージ
        let pendingACKMessageIDs =
            Set(pendingAcknowledgments[deviceID]?.keys.map { $0 } ?? [])

        // 未完了メッセージを重複なしで取得
        let pendingMessageIDs = Array(
            Set(queuedMessageIDs).union(pendingACKMessageIDs)
        )

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

            failPendingMessages(
                for: deviceID,
                error: disconnectError
            )

        } else {

            // 未完了メッセージがない場合のみ直接クリア
            cleanupConnection(for: deviceID)
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
    
    private func cleanupAllConnections(error: Error)
    {
        // 管理中のデバイスIDを収集
        let deviceIDs = Set(
            discoveredPeripherals.keys
        ).union(
            outgoingPacketQueue.allDeviceIDs
        ).union(
            writingDevices
        ).union(
            messageCharacteristics.keys
        ).union(
            writeTimeoutTasks.keys
        ).union(
            writeTimeoutIDs.keys
        ).union(
            disconnectingDevices
        ).union(
            subscribingNotificationDevices
        ).union(
            subscribingCharacteristics.keys
        ).union(
            discoveringServiceDevices
        ).union(
            pendingServiceRediscoveryDevices
        ).union(
            retryCounts.keys
        )

        // 失敗通知に必要な情報を先に退避
        // ACK待機中のデバイスも対象に含める
        let allDeviceIDs = deviceIDs.union(
            pendingAcknowledgments.keys
        )

        // 送信キューとACK待機中のメッセージを取得
        let pendingMessages = allDeviceIDs.map { deviceID in

            let queuedMessageIDs =
                outgoingPacketQueue.messageIDs(for: deviceID)

            let pendingACKMessageIDs =
                pendingAcknowledgments[deviceID]?.keys.map { $0 } ?? []

            // 重複を除去
            let messageIDs = Array(
                Set(queuedMessageIDs).union(pendingACKMessageIDs)
            )

            return (deviceID, messageIDs)
        }

        // Delegate通知より先に内部状態を解放
        for deviceID in allDeviceIDs
        {
            cleanupConnection(for: deviceID)
        }

        // 受信途中のデータを破棄
        messageAssembler.reset()

        // 切断処理中の管理情報を初期化
        disconnectingDevices.removeAll()

        // 全デバイスの接続状態を切断済みに更新
        connection.disconnectAll()

        // 失敗通知
        for (deviceID, messageIDs) in pendingMessages
        {
            for messageID in messageIDs
            {
                delegate?.centralDidFailToSend(
                    messageID: messageID,
                    to: deviceID,
                    error: error
                )
            }
        }
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
        
        subscribingCharacteristics.removeValue(forKey: deviceID)

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

                    disconnectingDevices.insert(deviceID)

                    connection.updateState(
                        for: peripheral,
                        to: peripheral.state == .disconnected
                            ? .disconnected
                            : .disconnecting
                    )

                    failPendingMessages(for: deviceID, error: error)

                    // 接続状態を更新して切断
                    if peripheral.state != .disconnected {
                        centralManager.cancelPeripheralConnection(peripheral)
                    } else {
                        disconnectingDevices.remove(deviceID)
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

            if packet.isLastChunk {

                // 最終チャンクの書き込み完了後、ACK待機を開始
                if pendingAcknowledgments[deviceID]?[packet.messageID] != nil {

                    startAcknowledgmentTimeout(
                        messageID: packet.messageID,
                        for: deviceID
                    )
                }
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
            delegate?.centralDidBecomeNotReady(deviceID: deviceID)
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
        
        guard services.contains(where: {
            $0.uuid == BLEUUID.service
        }) else {
            print("[BLECentral] BLEChatKit service not found:", deviceID)

            delegate?.centralDidBecomeNotReady(
                deviceID: deviceID
            )
            return
        }
        
        for service in services
        where service.uuid == BLEUUID.service
        {
            peripheral.discoverCharacteristics([BLEUUID.message],
                                               for: service)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil,
              let characteristics = service.characteristics
        else {
            delegate?.centralDidBecomeNotReady(
                deviceID: peripheral.identifier
            )
            return
        }

        let deviceID = peripheral.identifier
        guard characteristics.contains(where: {
            $0.uuid == BLEUUID.message
        }) else {
            print("[BLECentral] Message characteristic not found:", deviceID)

            delegate?.centralDidBecomeNotReady(
                deviceID: deviceID
            )
            return
        }

        for characteristic in characteristics
        where characteristic.uuid == BLEUUID.message {

            guard characteristic.properties.contains(.notify),
                  characteristic.properties.contains(.write)
            else {
                print("[BLECentral] Required properties not supported:", deviceID)
                delegate?.centralDidBecomeNotReady(deviceID: deviceID)
                continue
            }
            // 現在のCharacteristicを記録
            messageCharacteristics[deviceID] = characteristic

            // 通知購読中のCharacteristicを確認
            if subscribingNotificationDevices.contains(deviceID) {

                if let subscribingCharacteristic =
                    subscribingCharacteristics[deviceID] {

                    // 同じCharacteristicなら重複購読しない
                    if subscribingCharacteristic === characteristic {

                        print(
                            "[BLECentral] Notification subscription pending:",
                            deviceID
                        )

                        continue
                    }

                    // 別のCharacteristicに変更された
                    print(
                        "[BLECentral] Characteristic changed while subscribing:",
                        deviceID
                    )

                } else {

                    print(
                        "[BLECentral] Subscription state inconsistent:",
                        deviceID
                    )
                }

                // 古い購読待機状態を解除
                subscribingCharacteristics.removeValue(forKey: deviceID)
                subscribingNotificationDevices.remove(deviceID)
            }

            // すでに通知購読済みなら再要求しない
            guard !characteristic.isNotifying else {
                print(
                    "[BLECentral] Already notifying:",
                    deviceID
                )
                delegate?.centralDidBecomeReady(deviceID: deviceID)
                continue
            }

            // 通知購読処理中として登録
            subscribingNotificationDevices.insert(deviceID)

            // 購読対象のCharacteristicを記録
            subscribingCharacteristics[deviceID] = characteristic

            print("[BLECentral] setNotifyValue:", deviceID)

            // 通知購読開始
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
        
        guard let currentCharacteristic = messageCharacteristics[deviceID],
              currentCharacteristic === characteristic
        else {
            print(
                "[BLECentral] Ignoring stale notification callback:",
                deviceID
            )
            
            if let subscribingCharacteristic = subscribingCharacteristics[deviceID],
               subscribingCharacteristic === characteristic {
                
                subscribingCharacteristics.removeValue(forKey: deviceID)
                subscribingNotificationDevices.remove(deviceID)
                
                // 新しいCharacteristicが存在する場合は購読を開始
                if let currentCharacteristic = messageCharacteristics[deviceID],
                   !currentCharacteristic.isNotifying,
                   peripheral.state == .connected {
                    
                    subscribingNotificationDevices.insert(deviceID)
                    
                    subscribingCharacteristics[deviceID] = currentCharacteristic
                    
                    print(
                        "[BLECentral] Resubscribing to current characteristic:",
                        deviceID
                    )
                    
                    peripheral.setNotifyValue(
                        true,
                        for: currentCharacteristic
                    )
                }
            }
            
            return
        }
        
        // 現在のCharacteristicの購読完了
        // 購読待機中のCharacteristicと一致する場合だけ解除
        if let subscribingCharacteristic = subscribingCharacteristics[deviceID],
           subscribingCharacteristic === characteristic {

            subscribingCharacteristics.removeValue(forKey: deviceID)
            subscribingNotificationDevices.remove(deviceID)
        }

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
        
        delegate?.centralDidBecomeReady(deviceID: deviceID)
    }
    
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
            // ACKパケットを受信した場合
            if BLEAcknowledgmentPacket.isPacket(data) {
                let ack = try BLEAcknowledgmentPacket.decode(from: data)

                let deviceID = peripheral.identifier

                guard let pending =
                    pendingAcknowledgments[deviceID]?[ack.messageID]
                else {
                    print(
                        "[BLECentral] Unknown ACK:",
                        ack.messageID,
                        "from:",
                        deviceID
                    )
                    return
                }

                print(
                    "[BLECentral] ACK matched:",
                    pending.messageID,
                    "from:",
                    deviceID
                )
                
                cancelAcknowledgmentTimeout(
                    messageID: ack.messageID,
                    for: deviceID
                )
                
                // 現在書き込み中のパケットがACK対象か確認
                let isWritingAcknowledgedMessage =
                    writingDevices.contains(deviceID) &&
                    outgoingPacketQueue.peek(for: deviceID)?.messageID
                        == ack.messageID

                // ACK済みメッセージの未送信パケットを削除
                // 書き込み中の先頭パケットだけは保持する
                outgoingPacketQueue.removePackets(
                    messageID: ack.messageID,
                    for: deviceID,
                    preservingFirstPacket: isWritingAcknowledgedMessage
                )

                pendingAcknowledgments[deviceID]?
                    .removeValue(forKey: ack.messageID)

                if pendingAcknowledgments[deviceID]?.isEmpty == true {
                    pendingAcknowledgments.removeValue(forKey: deviceID)
                }
                
                // ACK受信をもって送信完了とする
                delegate?.centralDidFinishSending(
                    messageID: ack.messageID,
                    to: deviceID
                )

                // ACK済みパケットの削除後、
                // 書き込み中でなければ次のメッセージを送信
                sendNextPacket(to: deviceID)
                return
            }
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

                // デコード成功後に完成済みとして登録
                messageAssembler.markMessageCompleted(
                    messageID: packet.messageID,
                    from: peripheral.identifier
                )

                delegate?.centralDidReceiveMessage(
                    message,
                    from: peripheral.identifier
                )            }
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
