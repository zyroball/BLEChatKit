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
    private let messageAssembler = BLEMessageAssembler()
    private var notificationQueues: [UUID: [Data]] = [:]
    private var sendingCentrals: Set<UUID> = []
    public weak var delegate: BLEPeripheralDelegate?
    private var peripheralManager: CBPeripheralManager!
    private var messageCharacteristic: CBMutableCharacteristic?
    private var subscribedCentrals: [UUID: CBCentral] = [:]
    private var notificationTimeoutTasks: [UUID: DispatchWorkItem] = [:]
    private let notificationTimeout: TimeInterval = 30
    
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

        let encodedPackets = try packets.map
        {
            try $0.encode()
        }

        guard encodedPackets.allSatisfy({
            $0.count <= maximumLength
        }) else {
            throw BLETransportError.messageTooLarge
        }

        // 現在の送信待ちデータサイズ
        let currentSize = notificationQueueSize(for: centralID)

        // 今回追加するパケットの合計サイズ
        let additionalSize = encodedPackets.reduce(0)
        {
            $0 + $1.count
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


        sendNextNotification(to: centralID,
                             characteristic: characteristic)
    }

    
    
    private func sendNextNotification(to centralID: UUID,
                                      characteristic: CBMutableCharacteristic)
    {

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

        sendingCentrals.insert(centralID)

        defer
        {
            sendingCentrals.remove(centralID)
        }

        while let data = notificationQueues[centralID]?.first
        {

            let success = peripheralManager.updateValue(data,
                                                        for: characteristic,
                                                        onSubscribedCentrals: [central])

            guard success
            else
            {
                // 送信バッファが満杯
                break
            }

            notificationQueues[centralID]?.removeFirst()

            if notificationQueues[centralID]?.isEmpty == true
            {
                notificationQueues.removeValue(forKey: centralID)
            }
        }

        if notificationQueues[centralID]?.isEmpty != false
        {

            cancelNotificationTimeout(for: centralID)

        }
        else if notificationTimeoutTasks[centralID] == nil
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
        // 送信キューをすべて削除
        notificationQueues.removeAll()

        // タイムアウト監視をすべて解除
        for task in notificationTimeoutTasks.values
        {
            task.cancel()
        }

        notificationTimeoutTasks.removeAll()

        // 送信中フラグをすべて解除
        sendingCentrals.removeAll()

        // 受信途中の分割データを破棄
        for centralID in subscribedCentrals.keys
        {
            messageAssembler.reset(for: centralID)
        }

        // 購読デバイスをすべて削除
        subscribedCentrals.removeAll()

        print("BLE peripheral connections cleaned up")
    }
    
    private func notificationQueueSize(for centralID: UUID) -> Int
    {
        notificationQueues[centralID]?.reduce(0) { $0 + $1.count } ?? 0
    }
    
    private func cancelNotificationTimeout(for centralID: UUID)
    {
        notificationTimeoutTasks[centralID]?.cancel()
        notificationTimeoutTasks.removeValue(forKey: centralID)
    }
    
    private func startNotificationTimeout(for centralID: UUID)
    {
        cancelNotificationTimeout(for: centralID)

        let task = DispatchWorkItem { [weak self] in

            guard let self else { return }

            // 未送信パケットが残っているか確認
            guard self.notificationQueues[centralID]?.isEmpty == false
            else {
                self.cancelNotificationTimeout(for: centralID)
                return
            }

            print("BLE notification timeout:", centralID)

            // 通知前に送信キューを破棄
            self.notificationQueues.removeValue(
                forKey: centralID
            )

            // タイムアウト監視を解除
            self.cancelNotificationTimeout(for: centralID)

            // 状態をクリアした後にアプリへ通知
            self.delegate?.peripheralDidFailToSend(
                to: centralID,
                error: BLESendError.notificationTimeout
            )
        }

        notificationTimeoutTasks[centralID] = task

        DispatchQueue.main.asyncAfter(
            deadline: .now() + notificationTimeout,
            execute: task
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

        delegate?.peripheralDidUpdateState(state)

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
    }

    
    
    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager)
    {
        guard let characteristic = messageCharacteristic
        else
        {
            return
        }

        // 未送信パケットが残っているCentralへ送信再開
        for centralID in Array(notificationQueues.keys)
        {
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
                    
                    // 分割データを再構築
                    if let restoredData = messageAssembler.append(packet,
                                                                  from: request.central.identifier)
                    {
                        let message = try BLETransport.decode(
                            restoredData
                        )
                        
                        delegate?.peripheralDidReceiveMessage(
                            message,
                            from: request.central.identifier
                        )
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

        // 未送信キューを破棄
        notificationQueues.removeValue(forKey: centralID)

        // タイムアウト監視を解除
        cancelNotificationTimeout(for: centralID)

        // 送信中フラグを解除
        sendingCentrals.remove(centralID)

        // 受信途中の分割データを破棄
        messageAssembler.reset(for: centralID)
        
        // 購読解除をManagerへ通知
        delegate?.peripheralDidUnsubscribe(centralID: centralID)

        print("BLE central unsubscribed:", centralID)
    }
}
