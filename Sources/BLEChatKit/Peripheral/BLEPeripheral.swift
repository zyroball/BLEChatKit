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
        let chunkIndex: Int?
        let totalChunks: Int?

        init(
            messageID: UUID,
            data: Data,
            kind: NotificationKind,
            chunkIndex: Int? = nil,
            totalChunks: Int? = nil
        ) {
            self.messageID = messageID
            self.data = data
            self.kind = kind
            self.chunkIndex = chunkIndex
            self.totalChunks = totalChunks
        }
    }
    
    /// メッセージの送信進捗通知
    var onSendProgress: ((
        _ messageID: UUID,
        _ deviceID: UUID,
        _ sentChunks: Int,
        _ totalChunks: Int
    ) -> Void)?
    
#if DEBUG
private var debugAcknowledgmentEnabled = true
#endif
    
    private let messageAssembler = BLEMessageAssembler()
    private var peripheralManager: CBPeripheralManager!
    private var messageCharacteristic: CBMutableCharacteristic?
    private var notificationQueues: [UUID: [NotificationItem]] = [:]
    // CentralごとのACK待機中messageID
    private var pendingOutgoingAcknowledgments: [UUID: Set<UUID>] = [:]
    // ACK未着時の再送用パケットを保持
    // Central ID → Message ID → 分割パケット
    private var outgoingRetryPackets: [UUID: [UUID: [NotificationItem]]] = [:]
    // Central・messageIDごとの再送回数
    private var outgoingRetryCounts: [UUID: [UUID: Int]] = [:]
    // ACK未着時の最大再送回数
    private let maxOutgoingRetryCount = 3
    // Central・messageIDごとのACKタイムアウトタスク
    private var outgoingAcknowledgmentTimeoutTasks: [UUID: [UUID: DispatchWorkItem]] = [:]
    private var sendingCentrals: Set<UUID> = []
    public weak var delegate: BLEPeripheralDelegate?
    private var subscribedCentrals: [UUID: CBCentral] = [:]
    private var notificationTimeoutTasks: [UUID: DispatchWorkItem] = [:]
    private let notificationTimeout: TimeInterval = 30
    private var notificationTimeoutIDs: [UUID: UUID] = [:]
    
    // 1デバイスあたりの送信待ちデータ上限：2MB
    private let maxNotificationQueueBytes = 2_097_152

    private var serviceRegistrationInProgress = false
    private var cancelledServiceRegistrationPending = false

    private var serviceReady = false
    private var advertisingRequested = false
    private var advertisementLocalName: String?
    private var isAdvertisingStartPending = false
    private var advertisingLocalNameAtStart: String?
    
    public func setAdvertisementLocalName(_ name: String?) {

        guard advertisementLocalName != name else {
            return
        }

        advertisementLocalName = name

        guard !isAdvertisingStartPending,
              advertisingRequested,
              serviceReady,
              peripheralManager.state == .poweredOn
        else {
            return
        }

        if peripheralManager.isAdvertising {
            peripheralManager.stopAdvertising()
        }

        advertise()
    }

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

        guard !isAdvertisingStartPending else {
            return
        }

        advertisingLocalNameAtStart = nil

        peripheralManager.stopAdvertising()
    }

    private func setupService()
    {
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
              !peripheralManager.isAdvertising,
              !isAdvertisingStartPending
        else {
            return
        }

        var advertisementData: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [
                BLEUUID.service
            ]
        ]

        if let localName = advertisementLocalName,
           !localName.isEmpty {
            advertisementData[CBAdvertisementDataLocalNameKey] = localName
        }

        advertisingLocalNameAtStart = advertisementLocalName
        isAdvertisingStartPending = true

        peripheralManager.startAdvertising(advertisementData)
    }
    
    
    @discardableResult
    public func send(_ message: String,
                     to centralID: UUID,
                     messageID: UUID = UUID()) throws -> Bool
    {
        guard peripheralManager.state == .poweredOn,
              messageCharacteristic != nil,
              subscribedCentrals[centralID] != nil
        else {
            return false
        }

        // 通常メッセージも分割送信処理へ統一
        try sendChunked(
            message,
            to: centralID,
            messageID: messageID
        )

        return true
    }

    public func sendChunked(_ message: String,
                            to centralID: UUID,
                            messageID: UUID = UUID()) throws
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

        let packets = try BLEMessagePacketBuilder.build(
            message: message,
            chunkSize: chunkSize,
            messageID: messageID
        )
        
        guard let messageID = packets.first?.messageID else {
            throw BLETransportError.invalidMessage
        }

        print(
            "[BLEPeripheral] Sending messageID:",
            messageID
        )

        let encodedPackets = try packets.enumerated().map { index, packet in

            NotificationItem(
                messageID: packet.messageID,
                data: try packet.encode(),
                kind: .message,
                chunkIndex: index,
                totalChunks: packets.count
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

        // ACK未着時の再送用パケットを保存
        outgoingRetryPackets[centralID,
                             default: [:]][messageID] = encodedPackets
        
        // 初回送信なので再送回数は0
        outgoingRetryCounts[
            centralID,
            default: [:]
        ][messageID] = 0


        print("[BLEPeripheral] Retry packets saved:",
              messageID,
              "count:",
              encodedPackets.count)
        
        // ACK待機対象として登録
        pendingOutgoingAcknowledgments[
            centralID,
            default: []
        ].insert(messageID)

        print(
            "[BLEPeripheral] Waiting for ACK:",
            messageID,
            "from:",
            centralID
        )

        // 上限以内ならキューに追加
        notificationQueues[centralID, default: []].append(
            contentsOf: encodedPackets
        )

        // 送信処理を開始
        sendNextNotification(
            to: centralID,
            characteristic: characteristic
        )
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
            
            // メッセージの送信進捗を通知
            if item.kind == .message,
               let chunkIndex = item.chunkIndex,
               let totalChunks = item.totalChunks,
               pendingOutgoingAcknowledgments[centralID]?
                   .contains(item.messageID) == true {

                onSendProgress?(
                    item.messageID,
                    centralID,
                    chunkIndex + 1,
                    totalChunks
                )
            }

            let nextMessageID = notificationQueues[centralID]?.first?.messageID

            if nextMessageID != item.messageID,
               item.kind == .message {

                print(
                    "[BLEPeripheral] Message enqueue completed:",
                    item.messageID
                )
                
                startOutgoingAcknowledgmentTimeout(
                    messageID: item.messageID,
                    for: centralID
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
        // 失敗通知対象のメッセージをまとめる
        var pendingMessages: [UUID: Set<UUID>] = [:]

        // Notificationキュー内の未送信メッセージ
        for (centralID, items) in notificationQueues {

            let messageIDs = Set(
                items
                    .filter { $0.kind == .message }
                    .map { $0.messageID }
            )

            pendingMessages[
                centralID,
                default: []
            ].formUnion(messageIDs)
        }

        // ACK待機中のメッセージも失敗対象に追加
        for (centralID, messageIDs) in pendingOutgoingAcknowledgments {

            pendingMessages[
                centralID,
                default: []
            ].formUnion(messageIDs)
        }

        // ACK待機状態をすべて削除
        pendingOutgoingAcknowledgments.removeAll()
        
        // 再送用パケットをすべて削除
        outgoingRetryPackets.removeAll()
        
        // 再送回数をすべて削除
        outgoingRetryCounts.removeAll()

        // 送信キューをすべて削除
        notificationQueues.removeAll()

        // タイムアウト監視をすべて解除
        for task in notificationTimeoutTasks.values
        {
            task.cancel()
        }

        notificationTimeoutTasks.removeAll()
        notificationTimeoutIDs.removeAll()
        
        // ACKタイムアウト監視をすべて解除
        for tasks in outgoingAcknowledgmentTimeoutTasks.values {
            for task in tasks.values {
                task.cancel()
            }
        }

        // ACKタイマー管理情報を初期化
        outgoingAcknowledgmentTimeoutTasks.removeAll()


        // 送信中フラグをすべて解除
        sendingCentrals.removeAll()

        // 受信状態を初期化
        messageAssembler.resetAllPendingMessages()

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
            
            // 送信失敗したメッセージをACK待機対象から削除
            if var pending = self.pendingOutgoingAcknowledgments[centralID] {

                pending.subtract(messageIDs)

                if pending.isEmpty {
                    self.pendingOutgoingAcknowledgments.removeValue(
                        forKey: centralID
                    )
                } else {
                    self.pendingOutgoingAcknowledgments[centralID] = pending
                }
            }
            
            // Notification送信失敗したメッセージの再送データを削除
            if var retryPackets = self.outgoingRetryPackets[centralID] {

                for messageID in messageIDs {
                    retryPackets.removeValue(forKey: messageID)
                }

                if retryPackets.isEmpty {
                    self.outgoingRetryPackets.removeValue(
                        forKey: centralID
                    )
                } else {
                    self.outgoingRetryPackets[centralID] = retryPackets
                }
            }
            
            // Notification送信失敗したメッセージの再送回数を削除
            if var retryCounts = self.outgoingRetryCounts[centralID] {

                for messageID in messageIDs {
                    retryCounts.removeValue(forKey: messageID)
                }

                if retryCounts.isEmpty {
                    self.outgoingRetryCounts.removeValue(
                        forKey: centralID
                    )
                } else {
                    self.outgoingRetryCounts[centralID] = retryCounts
                }
            }


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
    
    private func enqueueOutgoingRetry(messageID: UUID,
                                      for centralID: UUID) -> Bool
    {
        // ACK待機中で、再送可能な接続か確認
        guard pendingOutgoingAcknowledgments[centralID]?
            .contains(messageID) == true,
              subscribedCentrals[centralID] != nil,
              let characteristic = messageCharacteristic,
              let packets = outgoingRetryPackets[centralID]?[messageID],
              !packets.isEmpty
        else {
            return false
        }

        // 同じメッセージが既にキューにないか確認
        let alreadyQueued = notificationQueues[centralID]?
            .contains(where: {
                $0.messageID == messageID && $0.kind == .message
            }) ?? false

        guard !alreadyQueued else {
            return false
        }

        // 再送パケットの合計サイズ
        let additionalSize = packets.reduce(0) {
            $0 + $1.data.count
        }

        let currentSize = notificationQueueSize(for: centralID)

        // Notificationキューの上限を確認
        guard additionalSize <= maxNotificationQueueBytes,
              currentSize <= maxNotificationQueueBytes - additionalSize
        else {
            return false
        }

        // 保存済みパケットを再送キューへ追加
        notificationQueues[centralID, default: []].append(
            contentsOf: packets
        )

        print(
            "[BLEPeripheral] Retry enqueued:",
            messageID,
            "packets:",
            packets.count
        )

        // 再送開始
        sendNextNotification(
            to: centralID,
            characteristic: characteristic
        )

        return true
    }

    
#if DEBUG
public func debugSetAcknowledgmentEnabled(_ enabled: Bool) {
    debugAcknowledgmentEnabled = enabled

    print(
        "[BLEPeripheral] DEBUG ACK enabled:",
        enabled
    )
}
#endif
    
    func sendAcknowledgment(messageID: UUID,
                            to centralID: UUID) throws
    {
#if DEBUG
guard debugAcknowledgmentEnabled else {
    print("[BLEPeripheral] DEBUG ACK suppressed:", messageID)
    return
}
#endif
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
    
    private func cancelOutgoingAcknowledgmentTimeout(
        messageID: UUID,
        for centralID: UUID
    ) {
        guard var tasks = outgoingAcknowledgmentTimeoutTasks[centralID]
        else {
            return
        }

        // 対象メッセージのタイマーを解除
        tasks.removeValue(forKey: messageID)?.cancel()

        // 残りのタイマーを管理
        if tasks.isEmpty {
            outgoingAcknowledgmentTimeoutTasks.removeValue(
                forKey: centralID
            )
        } else {
            outgoingAcknowledgmentTimeoutTasks[centralID] = tasks
        }
    }
    
    
    private func startOutgoingAcknowledgmentTimeout(
        messageID: UUID,
        for centralID: UUID
    ) {
        guard pendingOutgoingAcknowledgments[centralID]?
            .contains(messageID) == true
        else {
            return
        }

        // 既存タイマーがあれば解除
        cancelOutgoingAcknowledgmentTimeout(
            messageID: messageID,
            for: centralID
        )

        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }

            // まだACK待機中か確認
            guard self.pendingOutgoingAcknowledgments[centralID]?
                .contains(messageID) == true
            else {
                return
            }

            print(
                "[BLEPeripheral] ACK timeout:",
                messageID,
                "from:",
                centralID
            )

            self.cancelOutgoingAcknowledgmentTimeout(
                messageID: messageID,
                for: centralID
            )
            
            // 再送可能なら同じmessageIDで再送する
            if let attempt = self.nextOutgoingRetryAttempt(
                messageID: messageID,
                for: centralID
            ) {
                if self.enqueueOutgoingRetry(
                    messageID: messageID,
                    for: centralID
                ) {
                    print(
                        "[BLEPeripheral] ACK retry:",
                        messageID,
                        "attempt:",
                        attempt
                    )

                    // 再送を開始できたので失敗通知しない
                    return
                }

                print(
                    "[BLEPeripheral] ACK retry enqueue failed:",
                    messageID
                )
            }
            
            // 送信失敗が確定したため再送用データを削除
            self.outgoingRetryPackets[centralID]?
                .removeValue(forKey: messageID)

            if self.outgoingRetryPackets[centralID]?.isEmpty == true {
                self.outgoingRetryPackets.removeValue(forKey: centralID)
            }

            // 再送回数も削除
            self.outgoingRetryCounts[centralID]?
                .removeValue(forKey: messageID)

            if self.outgoingRetryCounts[centralID]?.isEmpty == true {
                self.outgoingRetryCounts.removeValue(forKey: centralID)
            }


            // ACK待機情報から対象メッセージを削除
            if var pending = self.pendingOutgoingAcknowledgments[centralID],
               pending.remove(messageID) != nil {

                if pending.isEmpty {
                    self.pendingOutgoingAcknowledgments.removeValue(
                        forKey: centralID
                    )
                } else {
                    self.pendingOutgoingAcknowledgments[centralID] = pending
                }

                // ACKタイムアウトによる送信失敗を通知
                self.delegate?.peripheralDidFailToSend(
                    messageID: messageID,
                    to: centralID,
                    error: BLESendError.acknowledgmentTimeout
                )
            }
        }

        outgoingAcknowledgmentTimeoutTasks[
            centralID,
            default: [:]
        ][messageID] = task

        // 暫定15秒でACKを監視
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 15,
            execute: task
        )
    }

    
    public func stopAndRemoveServices() {

        // Advertisingの自動再開を抑制
        advertisingRequested = false
        
        // サービス登録中に停止したことを記録
        cancelledServiceRegistrationPending =
            serviceRegistrationInProgress

        // Advertising停止
        peripheralManager.stopAdvertising()

        // GATTサービス削除
        if peripheralManager.state == .poweredOn {
            peripheralManager.removeAllServices()

            print("[BLEPeripheral] GATT service removal requested")
        }

        // サービス登録状態を初期化
        serviceReady = false
        messageCharacteristic = nil

        // 通信状態を初期化
        cleanupAllConnections()

        print("[BLEPeripheral] Stop and cleanup requested")
    }
    
    
    private func nextOutgoingRetryAttempt(messageID: UUID,
                                          for centralID: UUID) -> Int?
    {
        // 再送データと現在の再送回数を確認
        guard outgoingRetryPackets[centralID]?[messageID] != nil,
              let currentCount = outgoingRetryCounts[centralID]?[messageID],
              currentCount < maxOutgoingRetryCount
        else {
            return nil
        }

        // 再送回数を1回増やす
        let nextCount = currentCount + 1

        outgoingRetryCounts[
            centralID,
            default: [:]
        ][messageID] = nextCount

        return nextCount
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
            isAdvertisingStartPending = false
            advertisingLocalNameAtStart = nil

            // Bluetoothが使用できない場合は通信状態を破棄
            cleanupAllConnections()
        }
        
        delegate?.peripheralDidUpdateState(state)
    }
    
    public func peripheralManagerIsReady(toUpdateSubscribers
                                         peripheral: CBPeripheralManager)
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
                
                if BLEAcknowledgmentPacket.isPacket(data) {

                    let ack = try BLEAcknowledgmentPacket.decode(
                        from: data
                    )

                    let centralID = request.central.identifier

                    // 送信待ちのmessageIDと照合
                    if var pending = pendingOutgoingAcknowledgments[centralID],
                       pending.remove(ack.messageID) != nil {

                        // ACK待機状態を更新
                        if pending.isEmpty {
                            pendingOutgoingAcknowledgments.removeValue(
                                forKey: centralID
                            )
                        } else {
                            pendingOutgoingAcknowledgments[centralID] = pending
                        }

                        print(
                            "[BLEPeripheral] ACK matched:",
                            ack.messageID,
                            "from:",
                            centralID
                        )
                        
                        // ACK受信済みメッセージの再送データを削除
                        if var retryPackets = outgoingRetryPackets[centralID] {

                            retryPackets.removeValue(forKey: ack.messageID)

                            if retryPackets.isEmpty {
                                outgoingRetryPackets.removeValue(
                                    forKey: centralID
                                )
                            } else {
                                outgoingRetryPackets[centralID] = retryPackets
                            }
                        }
                        
                        // ACK受信済みメッセージの再送回数を削除
                        if var retryCounts = outgoingRetryCounts[centralID] {

                            retryCounts.removeValue(forKey: ack.messageID)

                            if retryCounts.isEmpty {
                                outgoingRetryCounts.removeValue(
                                    forKey: centralID
                                )
                            } else {
                                outgoingRetryCounts[centralID] = retryCounts
                            }
                        }
                        
                        cancelOutgoingAcknowledgmentTimeout(
                            messageID: ack.messageID,
                            for: centralID
                        )

                        delegate?.peripheralDidReceiveAcknowledgment(
                            messageID: ack.messageID,
                            from: centralID
                        )
                    } else {

                        print(
                            "[BLEPeripheral] Unknown ACK:",
                            ack.messageID,
                            "from:",
                            centralID
                        )
                    }

                    peripheral.respond(
                        to: request,
                        withResult: .success
                    )

                    continue
                }


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
        
        if cancelledServiceRegistrationPending {

            // 停止前のサービス登録完了通知を処理
            cancelledServiceRegistrationPending = false
            serviceRegistrationInProgress = false

            serviceReady = false
            messageCharacteristic = nil

            // 遅れて登録されたサービスも削除
            if peripheralManager.state == .poweredOn {
                peripheralManager.removeAllServices()
            }

            print(
                "[BLEPeripheral] Cancelled service registration callback handled"
            )

            // 停止後に再起動要求があった場合は再登録
            if advertisingRequested,
               peripheralManager.state == .poweredOn {

                setupService()
            }

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

    public func peripheralManagerDidStartAdvertising(
        _ peripheral: CBPeripheralManager,
        error: Error?
    ) {
        isAdvertisingStartPending = false

        guard advertisingRequested,
              serviceReady,
              peripheral.state == .poweredOn
        else {
            if peripheral.state == .poweredOn,
               peripheral.isAdvertising {
                peripheral.stopAdvertising()
            }
            return
        }

        if let error {
            delegate?.peripheralDidFailToAdvertise(
                error: error
            )
            return
        }

        if advertisingLocalNameAtStart != advertisementLocalName {

            peripheral.stopAdvertising()

            advertise()

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
        // ACK待機中のメッセージIDを取得して削除
        let awaitingAckMessageIDs =
            pendingOutgoingAcknowledgments.removeValue(
                forKey: centralID
            ) ?? []

        // 未送信メッセージIDを取得
        let queuedMessageIDs = Set(
            pendingItems
                .filter { $0.kind == .message }
                .map { $0.messageID }
        )

        // 未送信とACK待機中のIDを統合
        let pendingMessageIDs =
            queuedMessageIDs.union(awaitingAckMessageIDs)
        
        // 購読解除したCentralの再送用パケットを削除
        outgoingRetryPackets.removeValue(forKey: centralID)
        print(
            "[BLEPeripheral] Unsubscribed pending messages:",
            pendingMessageIDs.count
        )
        
        // 購読解除したCentralの再送回数を削除
        outgoingRetryCounts.removeValue(forKey: centralID)

        // タイムアウト監視を解除
        cancelNotificationTimeout(for: centralID)
        
        // このCentralのACKタイムアウトをすべて解除
        if let tasks = outgoingAcknowledgmentTimeoutTasks.removeValue(
            forKey: centralID
        ) {
            for task in tasks.values {
                task.cancel()
            }
        }

        // 送信中フラグを解除
        sendingCentrals.remove(centralID)

        messageAssembler.resetPendingMessages(for: centralID)
        
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
