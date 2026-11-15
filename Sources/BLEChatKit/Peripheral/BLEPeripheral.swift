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
    public weak var delegate: BLEPeripheralDelegate?
    private var peripheralManager: CBPeripheralManager!
    private var messageCharacteristic: CBMutableCharacteristic?
    private var subscribedCentrals: [UUID: CBCentral] = [:]


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
    
    
    private func handleReceivedPacket(_ data: Data,
                                      from central: CBCentral)
    {
        do
        {
            let packet = try BLEMessagePacket.decode(
                from: data
            )

            guard let restoredData = messageAssembler.append(packet)
            else
            {
                // まだ全チャンクが揃っていない
                return
            }

            let message = try BLETransport.decode(restoredData)

            print("BLE message restored:", message)

            // ここで既存の受信通知処理を呼び出す

        }
        catch
        {
            print("BLE packet decode failed:", error)
        }
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

    
    public func peripheralManagerIsReady(
        toUpdateSubscribers peripheral: CBPeripheralManager
    )
    {
        // 次のSTEPで送信待ちキューを処理する
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
                // 分割パケットとしてデコードを試す
                if let packet = try? BLEMessagePacket.decode(from: data)
                {
                    if let restoredData = messageAssembler.append(packet)
                    {
                        let message = try BLETransport.decode(restoredData)

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

                    delegate?.peripheralDidReceiveMessage(message,
                                                          from: request.central.identifier
                    )
                }

                peripheral.respond(to: request,
                                   withResult: .success)

            }
            catch
            {
                peripheral.respond(to: request,
                                   withResult: .unlikelyError)
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
    
    
    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        guard characteristic.uuid == BLEUUID.message else {
            return
        }
        
        delegate?.peripheralDidSubscribe(
            centralID: central.identifier
        )

        subscribedCentrals[central.identifier] = central
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        guard characteristic.uuid == BLEUUID.message else {
            return
        }
        
        delegate?.peripheralDidUnsubscribe(
            centralID: central.identifier
        )

        subscribedCentrals.removeValue(
            forKey: central.identifier
        )
    }

}
