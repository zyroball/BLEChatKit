//
//  BLEPeripheral.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/15.
//


import Foundation
import CoreBluetooth

public final class BLEPeripheral: NSObject
{
    private let messageAssembler = BLEMessageAssembler()
    private var notificationQueues: [UUID: [Data]] = [:]
    public weak var delegate: BLEPeripheralDelegate?
    private var peripheralManager: CBPeripheralManager!
    private var messageCharacteristic: CBMutableCharacteristic?
    private var subscribedCentrals: [UUID: CBCentral] = [:]
    private var notificationTimeoutTasks: [UUID: DispatchWorkItem] = [:]
    private let notificationTimeout: TimeInterval = 30
    
    // 1デバイスあたりの送信待ちデータ上限：2MB
    private let maxNotificationQueueBytes = 2_097_152

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

    private func setupService()
    {
        guard peripheralManager.state == .poweredOn
        else
        {
            return
        }

        let characteristic = CBMutableCharacteristic(type: BLEUUID.message,
                                                     properties: [.write, .notify],
                                                     value: nil,
                                                     permissions: [.writeable])

        let service = CBMutableService(type: BLEUUID.service,
                                       primary: true)

        service.characteristics = [characteristic]

        messageCharacteristic = characteristic
        serviceReady = false

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
              let characteristic = messageCharacteristic,
              let central = subscribedCentrals[centralID]
        else {
            return false
        }

        let data = try BLETransport.encode(message)

        guard data.count <= central.maximumUpdateValueLength else {
            throw BLETransportError.messageTooLarge
        }

        return peripheralManager.updateValue(
            data,
            for: characteristic,
            onSubscribedCentrals: [central]
        )
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
        guard let central = subscribedCentrals[centralID],
              var queue = notificationQueues[centralID]
        else
        {
            return
        }

        while !queue.isEmpty
        {
            let data = queue[0]

            let success = peripheralManager.updateValue(data,
                                                        for: characteristic,
                                                        onSubscribedCentrals: [central])

            guard success
            else
            {
                // 送信バッファが満杯
                break
            }

            queue.removeFirst()
        }

        notificationQueues[centralID] = queue.isEmpty ? nil : queue

        if queue.isEmpty
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
            else
            {
                self.cancelNotificationTimeout(for: centralID)
                return
            }

            print("BLE notification timeout:", centralID)

            // ★ ここに追加！
            // アプリ側に送信失敗を通知
            self.delegate?.peripheralDidFailToSend(
                to: centralID,
                error: BLESendError.notificationTimeout
            )

            // 送信待ちキューを破棄
            self.notificationQueues.removeValue(
                forKey: centralID
            )

            // タイムアウト監視を解除
            self.cancelNotificationTimeout(for: centralID)
        }

        notificationTimeoutTasks[centralID] = task

        DispatchQueue.main.asyncAfter(
            deadline: .now() + notificationTimeout,
            execute: task
        )
    }

}

// MARK: - CBPeripheralManagerDelegate

extension BLEPeripheral: CBPeripheralManagerDelegate
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
            messageCharacteristic = nil
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
        if let error
        {
            serviceReady = false
            delegate?.peripheralDidFailToAdvertise(
                error: error
            )
            return
        }

        guard service.uuid == BLEUUID.service
        else
        {
            return
        }

        serviceReady = true
        advertise()
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
        
        delegate?.peripheralDidSubscribe(centralID: central.identifier)

        subscribedCentrals[central.identifier] = central
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

        let deviceID = central.identifier

        // 購読デバイスを削除
        subscribedCentrals.removeValue(forKey: deviceID)

        // 未送信パケットを破棄
        notificationQueues.removeValue(forKey: deviceID)
        
        cancelNotificationTimeout(for: deviceID)

        // このデバイスの受信途中データを破棄
        messageAssembler.reset(for: deviceID)

        print("BLE central unsubscribed:", deviceID)
    }


}
