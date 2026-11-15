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
    public weak var delegate: BLECentralDelegate?
    private var centralManager: CBCentralManager!
    private var discoveredPeripherals:[UUID: CBPeripheral] = [:]
    public let connection = BLEConnection()

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

        centralManager.scanForPeripherals(withServices: nil,
                                          options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
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
        connection.updateState(for: peripheral,
                               to: .connected)
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
        connection.updateState(for: peripheral,
                               to: .disconnected)

        if let error
        {
            connection.delegate?.connectionDidFail(deviceID: peripheral.identifier,
                                                   error: error)
        }
    }
}
