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
    public weak var delegate: BLEPeripheralDelegate?
    private var peripheralManager: CBPeripheralManager!
    private var messageCharacteristic: CBMutableCharacteristic?

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
    public func send(_ message: String) throws -> Bool
    {
        guard peripheralManager.state == .poweredOn,
              let characteristic = messageCharacteristic
        else
        {
            return false
        }

        let data = try BLETransport.encode(message)

        return peripheralManager.updateValue(data,
                                             for: characteristic,
                                             onSubscribedCentrals: nil)
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
            else
            {
                peripheral.respond(
                    to: request,
                    withResult: .invalidPdu
                )
                continue
            }

            do
            {
                let message = try BLETransport.decode(data)

                delegate?.peripheralDidReceiveMessage(message)

                peripheral.respond(to: request,
                                   withResult: .success)

            }
            catch
            {
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
}
