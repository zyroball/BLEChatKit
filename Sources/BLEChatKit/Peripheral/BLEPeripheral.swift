//
//  BLEPeripheral.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/15.
//


import Foundation
import CoreBluetooth

@MainActor
public final class BLEPeripheral: NSObject
{
    private enum NotificationKind {
        case message
        case acknowledgment
    }

    private struct NotificationItem {
        let messageID: UUID
        let data: Data
        let kind: NotificationKind
    }
    
    private let messageAssembler = BLEMessageAssembler()
    private var notificationQueues: [UUID: [NotificationItem]] = [:]
    private var sendingCentrals: Set<UUID> = []
    public weak var delegate: BLEPeripheralDelegate?
    private var peripheralManager: CBPeripheralManager!
    private var messageCharacteristic: CBMutableCharacteristic?
    private var subscribedCentrals: [UUID: CBCentral] = [:]
    private var notificationTimeoutTasks: [UUID: DispatchWorkItem] = [:]
    private let notificationTimeout: TimeInterval = 30
    private var notificationTimeoutIDs: [UUID: UUID] = [:]
    
    // 1デバイスあたりの送信待ちデータ上限：2MB
    private let maxNotificationQueueBytes = 2_097_152

    private var serviceRegistrationInProgress = false
    private var serviceReady = false
    private var advertisingRequested = false

    public override init()
    {
        super.init()

        peripheralManager = CBPeripheralManager(
            delegate: self,
            queue: nil
        )
    }

    public func startAdvertising()
    {
        advertisingRequested = true

        guard peripheralManager.state == .poweredOn
        else
        {
            return
        }

        if serviceReady
        {
            advertise()
        }
        else
        {
            setupService()
        }
    }

    public func stopAdvertising()
    {
        advertisingRequested = false
        peripheralManager.stopAdvertising()
    }

    private func setupService() {

        guard peripheralManager.state == .poweredOn,
              !serviceReady,
              !serviceRegistrationInProgress
        else {
            return
        }

        serviceRegistrationInProgress = true

        let characteristic = CBMutableCharacteristic(
            type: BLEUUID.message,
            properties: [.write, .notify],
            value: nil,
            permissions: [.writeable]
        )

        let service = CBMutableService(
            type: BLEUUID.service,
            primary: true
        )

        service.characteristics = [characteristic]

        messageCharacteristic = characteristic
        serviceReady = false

        print("[BLEPeripheral] Registering service:", service.uuid)
        peripheralManager.add(service)
    }

    private func advertise()
    {
        guard advertisingRequested,
              serviceReady,
              peripheralManager.state == .poweredOn,
              !peripheralManager.isAdvertising
        else
        {
            return
        }

        peripheralManager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [
                BLEUUID.service
            ]
        ])
    }
    
    
    @discardableResult
    public func send(_ message: String,
                     to centralID: UUID) throws -> Bool
    {
        guard peripheralManager.state == .poweredOn,
              messageCharacteristic != nil,
              subscribedCentrals[centralID] != nil
        else {
            return false
        }

        // 通常メッセージも分割送信処理へ統一
        try sendChunked(message,
                        to: centralID)

        return true
    }

    public func sendChunked(_ message: String,
                            to centralID: UUID) throws
    {
        guard let central = subscribedCentrals[centralID],
              let characteristic = messageCharacteristic
        else {
            throw BLETransportError.invalidMessage
        }

        let maximumLength = central.maximumUpdateValueLength

        // ★ ここを変更
        let chunkSize = min(maximumLength - BLEMessagePacket.headerSize,
                            Int(UInt16.max))

        guard chunkSize > 0
        else
        {
            throw BLETransportError.messageTooLarge
        }

        let packets = try BLEMessagePacketBuilder.build(message: message,
                                                        chunkSize: chunkSize
        )
        
        guard let messageID = packets.first?.messageID else {
            throw BLETransportError.invalidMessage
        }

        print(
            "[BLEPeripheral] Sending messageID:",
            messageID
        )

        let encodedPackets = try packets.map { packet in
            NotificationItem(
                messageID: packet.messageID,
                data: try packet.encode(),
                kind: .message
            )
        }

        guard encodedPackets.allSatisfy({
            $0.data.count <= maximumLength
        }) else {
            throw BLETransportError.messageTooLarge
        }

        // 現在の送信待ちデータサイズ
        let currentSize = notificationQueueSize(for: centralID)

        // 今回追加するパケットの合計サイズ
        let additionalSize = encodedPackets.reduce(0) {
            $0 + $1.data.count
        }

        // 送信キューの上限を確認
        guard additionalSize <= maxNotificationQueueBytes,
              currentSize <= maxNotificationQueueBytes - additionalSize
        else
        {
            throw BLETransportError.messageTooLarge
        }

        // 上限以内ならキューに追加
        notificationQueues[centralID, default: []].append(
            contentsOf: encodedPackets
        )

        // 送信処理を開始
        sendNextNotification(to: centralID,
                             characteristic: characteristic)
    }
    
    private func sendNextNotification(to centralID: UUID,
                                      characteristic: CBMutableCharacteristic)
    {
        print(
               "[BLEPeripheral] sendNextNotification called:",
               centralID,
               "queue:",
               notificationQueues[centralID]?.count ?? 0
           )
        // 同じCentralへの送信処理が実行中なら終了
        guard !sendingCentrals.contains(centralID)
        else
        {
            return
        }

        guard let central = subscribedCentrals[centralID]
        else
        {
            return
        }

        // 送信待ちパケットがなければ処理しない
        guard notificationQueues[centralID]?.isEmpty == false
        else {
            return
        }
        
        sendingCentrals.insert(centralID)

        defer
        {
            sendingCentrals.remove(centralID)
        }

        var didSendPacket = false
        while let item = notificationQueues[centralID]?.first {

            let success = peripheralManager.updateValue(
                item.data,
                for: characteristic,
                onSubscribedCentrals: [central]
            )
            
            guard success else {
                print(
                    "[BLEPeripheral] Backpressure detected:",
                    centralID
                )

                print(
                    "[BLEPeripheral] Remaining packets:",
                    notificationQueues[centralID]?.count ?? 0
                )

                break
            }

            notificationQueues[centralID]?.removeFirst()
            didSendPacket = true

            let nextMessageID = notificationQueues[centralID]?.first?.messageID

            if nextMessageID != item.messageID,
               item.kind == .message {

                print(
                    "[BLEPeripheral] Message enqueue completed:",
                    item.messageID
                )

                delegate?.peripheralDidFinishEnqueuing(
                    messageID: item.messageID,
                    to: centralID
                )
            }

            if notificationQueues[centralID]?.isEmpty == true {
                notificationQueues.removeValue(forKey: centralID)
            }
        }

        if notificationQueues[centralID]?.isEmpty != false {

            cancelNotificationTimeout(for: centralID)

            print(
                "[BLEPeripheral] Notification queue drained:",
                centralID
            )

            delegate?.peripheralDidFinishEnqueuing(
                to: centralID
            )
        }
        else if didSendPacket ||
                notificationTimeoutTasks[centralID] == nil
        {

            startNotificationTimeout(for: centralID)
        }
    }
    
    private func handleReceivedPacket(_ data: Data,
                                      from central: CBCentral)
    {
        do
        {
            let packet = try BLEMessagePacket.decode(
                from: data
            )

            guard let restoredData = messageAssembler.append(
                packet,
                from: central.identifier
            )
            else
            {
                // まだ全チャンクが揃っていない
                return
            }

            let message = try BLETransport.decode(
                restoredData
            )

            delegate?.peripheralDidReceiveMessage(
                message,
                from: central.identifier
            )

        }
        catch
        {
            print("BLE packet decode failed: \(error)")
        }
    }
    
    
    private func cleanupAllConnections()
    {
        // 失敗通知に必要な情報を退避
        let pendingMessages = notificationQueues.map {
            (centralID, items) in

            (
                centralID,
                Set(items.map { $0.messageID })
            )
        }

        // 送信キューをすべて削除
        notificationQueues.removeAll()

        // タイムアウト監視をすべて解除
        for task in notificationTimeoutTasks.values
        {
            task.cancel()
        }

        notificationTimeoutTasks.removeAll()
        notificationTimeoutIDs.removeAll()

        // 送信中フラグをすべて解除
        sendingCentrals.removeAll()

        // 受信状態を初期化
        messageAssembler.reset()

        // 購読デバイスをすべて削除
        subscribedCentrals.removeAll()

        // 内部状態を初期化した後で失敗通知
        for (centralID, messageIDs) in pendingMessages
        {
            for messageID in messageIDs
            {
                delegate?.peripheralDidFailToSend(
                    messageID: messageID,
                    to: centralID,
                    error: BLESendError.disconnected
                )
            }
        }

        print("BLE peripheral connections cleaned up")
    }
    
    private func notificationQueueSize(for centralID: UUID) -> Int
    {
        notificationQueues[centralID]?.reduce(0) {
            $0 + $1.data.count
        } ?? 0
    }
    
    private func cancelNotificationTimeout(for centralID: UUID)
    {
        notificationTimeoutTasks[centralID]?.cancel()
        notificationTimeoutTasks.removeValue(forKey: centralID)
        notificationTimeoutIDs.removeValue(forKey: centralID)
    }
    
    private func startNotificationTimeout(for centralID: UUID)
    {
        print(
                "[BLEPeripheral] Starting notification timeout:",
                centralID
            )
        cancelNotificationTimeout(for: centralID)

        let timeoutID = UUID()

        notificationTimeoutIDs[centralID] = timeoutID

        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }

            guard self.notificationTimeoutIDs[centralID] == timeoutID else {
                return
            }
            
            // 未送信パケットが残っているか確認
            guard self.notificationQueues[centralID]?.isEmpty == false
            else {
                self.cancelNotificationTimeout(for: centralID)
                return
            }

            print("BLE notification timeout:", centralID)

            let failedItems = self.notificationQueues.removeValue(
                forKey: centralID
            ) ?? []

            self.cancelNotificationTimeout(for: centralID)
            self.sendingCentrals.remove(centralID)

            let messageIDs = Set(
                failedItems
                    .filter { $0.kind == .message }
                    .map { $0.messageID }
            )

            for messageID in messageIDs {
                self.delegate?.peripheralDidFailToSend(
                    messageID: messageID,
                    to: centralID,
                    error: BLESendError.notificationTimeout
                )
            }
        }

        notificationTimeoutTasks[centralID] = task

        DispatchQueue.main.asyncAfter(
            deadline: .now() + notificationTimeout,
            execute: task
        )
    }
    
    func sendAcknowledgment(
        messageID: UUID,
        to centralID: UUID
    ) throws {
        guard let central = subscribedCentrals[centralID],
              let characteristic = messageCharacteristic
        else {
            throw BLETransportError.invalidMessage
        }

        let packet = BLEAcknowledgmentPacket(
            messageID: messageID
        )

        let data = packet.encode()

        guard data.count <= central.maximumUpdateValueLength else {
            throw BLETransportError.messageTooLarge
        }

        let currentSize = notificationQueueSize(for: centralID)

        guard data.count <= maxNotificationQueueBytes,
              currentSize <= maxNotificationQueueBytes - data.count
        else {
            throw BLETransportError.messageTooLarge
        }

        let item = NotificationItem(
            messageID: messageID,
            data: data,
            kind: .acknowledgment
        )

        notificationQueues[centralID, default: []].append(item)

        sendNextNotification(
            to: centralID,
            characteristic: characteristic
        )
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BLEPeripheral: @preconcurrency CBPeripheralManagerDelegate
{
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager)
    {
        let state: BLEPeripheralState

        switch peripheral.state
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

        if peripheral.state == .poweredOn
        {
            if advertisingRequested
            {
                if serviceReady
                {
                    advertise()
                } else {
                    setupService()
                }
            }
        }
        else
        {
            serviceReady = false
            serviceRegistrationInProgress = false
            messageCharacteristic = nil
            // Bluetoothが使用できない場合は通信状態を破棄
            cleanupAllConnections()
        }
        
        delegate?.peripheralDidUpdateState(state)
    }
    
    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager)
    {
        guard let characteristic = messageCharacteristic
        else
        {
            return
        }
        
        // 未送信パケットが残っているCentralへ送信再開
        for centralID in Array(notificationQueues.keys) {

            print(
                "[BLEPeripheral] Resuming notifications:",
                centralID,
                "remaining:",
                notificationQueues[centralID]?.count ?? 0
            )

            sendNextNotification(
                to: centralID,
                characteristic: characteristic
            )
        }
    }


    public func peripheralManager(_ peripheral: CBPeripheralManager,
                                  didReceiveWrite requests: [CBATTRequest])
    {
        for request in requests
        {
            
            guard request.characteristic.uuid == BLEUUID.message,
                  request.offset == 0,
                  let data = request.value
            else {
                peripheral.respond(
                    to: request,
                    withResult: .invalidPdu
                )
                continue
            }
            do
            {
                // 分割パケットかどうか判定
                if BLEMessagePacket.isPacket(data)
                {
                    // 分割パケットをデコード
                    let packet = try BLEMessagePacket.decode(from: data)
                    
                    if messageAssembler.isMessageCompleted(
                        messageID: packet.messageID,
                        from: request.central.identifier
                    ) {
                        if packet.chunkIndex == packet.totalChunks - 1 {
                            do {
                                try sendAcknowledgment(
                                    messageID: packet.messageID,
                                    to: request.central.identifier
                                )
                            } catch {
                                print(
                                    "[BLEPeripheral] Duplicate ACK enqueue failed:",
                                    error
                                )
                            }
                        }

                        peripheral.respond(
                            to: request,
                            withResult: .success
                        )
                        continue
                    }
                    
                    if let restoredData = messageAssembler.append(
                        packet,
                        from: request.central.identifier
                    ) {
                        let message = try BLETransport.decode(
                            restoredData
                        )

                        messageAssembler.markMessageCompleted(
                            messageID: packet.messageID,
                            from: request.central.identifier
                        )

                        delegate?.peripheralDidReceiveMessage(
                            message,
                            from: request.central.identifier
                        )

                        // 受信完了ACKを送信
                        do {
                            try sendAcknowledgment(
                                messageID: packet.messageID,
                                to: request.central.identifier
                            )
                        } catch {
                            print("[BLEPeripheral] ACK enqueue failed:", error)
                        }
                    }
                }
                else
                {
                    // 従来の通常メッセージ
                    let message = try BLETransport.decode(data)
                    
                    delegate?.peripheralDidReceiveMessage(
                        message,
                        from: request.central.identifier
                    )
                }
                
                peripheral.respond(to: request,
                                   withResult: .success)
            }
            catch
            {
                print("BLE receive error: \(error)")
                
                peripheral.respond(
                    to: request,
                    withResult: .unlikelyError
                )
            }
        }
    }
    
    public func peripheralManager(_ peripheral: CBPeripheralManager,
                                  didAdd service: CBService,
                                  error: Error?)
    {
        guard service.uuid == BLEUUID.service else {
            return
        }

        serviceRegistrationInProgress = false

        if let error {
            serviceReady = false

            delegate?.peripheralDidFailToAdvertise(
                error: error
            )
            return
        }

        serviceReady = true
        print("[BLEPeripheral] Service registered:", service.uuid)

        if advertisingRequested {
            advertise()
        }
    }

    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager,
                                                     error: Error?)
    {
        if let error
        {
            delegate?.peripheralDidFailToAdvertise(
                error: error
            )
            return
        }

        delegate?.peripheralDidStartAdvertising()
    }
    
    public func peripheralManager(_ peripheral: CBPeripheralManager,
                                  central: CBCentral,
                                  didSubscribeTo characteristic: CBCharacteristic)
    {
        guard characteristic.uuid == BLEUUID.message
        else
        {
            return
        }

        let centralID = central.identifier

        // 先に購読デバイスを登録
        subscribedCentrals[centralID] = central
        
        print("[BLEPeripheral] Notification subscribed:", centralID)

        // 登録完了後にアプリ側へ通知
        delegate?.peripheralDidSubscribe(centralID: centralID)
    }
    
    
    public func peripheralManager(_ peripheral: CBPeripheralManager,
                                  central: CBCentral,
                                  didUnsubscribeFrom characteristic: CBCharacteristic)
    {
        guard characteristic.uuid == BLEUUID.message
        else
        {
            return
        }

        let centralID = central.identifier

        // 購読デバイスを削除
        subscribedCentrals.removeValue(forKey: centralID)

        // 未送信キューを取得して破棄
        let pendingItems = notificationQueues.removeValue(
            forKey: centralID
        ) ?? []

        // 未送信メッセージIDを取得
        let pendingMessageIDs = Set(
            pendingItems.map { $0.messageID }
        )
        
        print(
            "[BLEPeripheral] Unsubscribed pending messages:",
            pendingMessageIDs.count
        )

        // タイムアウト監視を解除
        cancelNotificationTimeout(for: centralID)

        // 送信中フラグを解除
        sendingCentrals.remove(centralID)

        messageAssembler.reset(for: centralID)
        
        // 内部状態の初期化後に失敗通知
        for messageID in pendingMessageIDs {
            delegate?.peripheralDidFailToSend(
                messageID: messageID,
                to: centralID,
                error: BLESendError.disconnected
            )
        }

        print("[BLEPeripheral] Message assembler reset:", centralID)
        
        // 購読解除をManagerへ通知
        delegate?.peripheralDidUnsubscribe(centralID: centralID)

        print("BLE central unsubscribed:", centralID)
    }
}
