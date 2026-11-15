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
    private var messageCharacteristics:[UUID: CBCharacteristic] = [:]
    
    private var packetQueues: [UUID: [Data]] = [:]
    private var writingDevices: Set<UUID> = []

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

        // 仮のチャンクサイズ。
        // エンコード後のパケットサイズも考慮する。
        let chunkSize = max(1, maximumLength / 2)

        let packets = try BLEMessagePacketBuilder.build(
            message: message,
            chunkSize: chunkSize
        )

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
    
    
    private func sendNextPacket(to deviceID: UUID)
    {

        guard !writingDevices.contains(deviceID),
              let peripheral = discoveredPeripherals[deviceID],
              peripheral.state == .connected,
              let characteristic = messageCharacteristics[deviceID],
              let packet = packetQueues[deviceID]?.first
        else {
            return
        }

        writingDevices.insert(deviceID)

        peripheral.writeValue(packet,
                              for: characteristic,
                              type: .withResponse
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

    public func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        peripheral.delegate = self

        connection.updateState(
            for: peripheral,
            to: .connected
        )

        peripheral.discoverServices([
            BLEUUID.service
        ])
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
        messageCharacteristics.removeValue(
            forKey: peripheral.identifier
        )

        connection.updateState(for: peripheral,
                               to: .disconnected)

        if let error
        {
            connection.delegate?.connectionDidFail(deviceID: peripheral.identifier,
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

        let deviceID = peripheral.identifier

        guard writingDevices.contains(deviceID)
        else
        {
            return
        }

        writingDevices.remove(deviceID)

        if let error = error
        {
            print("BLE write failed:", error)

            packetQueues.removeValue(forKey: deviceID)
            return
        }

        guard packetQueues[deviceID]?.isEmpty == false
        else
        {
            return
        }

        packetQueues[deviceID]?.removeFirst()

        if packetQueues[deviceID]?.isEmpty == true
        {
            packetQueues.removeValue(forKey: deviceID)
            print("BLE chunked write completed")
            return
        }

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
            let message = try BLETransport.decode(data)

            delegate?.centralDidReceiveMessage(
                message,
                from: peripheral.identifier
            )

        }
        catch
        {
            print("BLE message decode error: \(error)")
        }
    }
}
