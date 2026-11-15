//
//  BLEChatManager.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/15.
//


import Foundation

public final class BLEChatManager
{

    public weak var delegate: BLEChatManagerDelegate?

    private let central: BLECentral
    private let peripheral: BLEPeripheral
    
    private var centralDeviceIDs = Set<UUID>()
    private var peripheralCentralIDs = Set<UUID>()

    private var shouldRun = false
    private var isCentralReady = false
    private var isPeripheralReady = false

    public init() {
        central = BLECentral()
        peripheral = BLEPeripheral()

        central.delegate = self
        central.connection.delegate = self
        peripheral.delegate = self
    }

    public func start()
    {
        shouldRun = true

        if isCentralReady
        {
            central.startScan()
        }

        if isPeripheralReady
        {
            peripheral.startAdvertising()
        }
    }

    public func stop() {
        shouldRun = false

        central.stopScan()
        peripheral.stopAdvertising()
    }

    public func connect(to deviceID: UUID) {
        central.connect(to: deviceID)
    }

    public func disconnect(from deviceID: UUID) {
        central.disconnect(from: deviceID)
    }

    
    @discardableResult
    public func send(_ message: String,
                     to deviceID: UUID) throws -> Bool
    {
        if peripheralCentralIDs.contains(deviceID)
        {
            try peripheral.sendChunked(message,
                                       to: deviceID)

            return true
        }

        if centralDeviceIDs.contains(deviceID)
        {
            try central.sendChunked(message,
                                    to: deviceID)

            return true
        }

        return false
    }
}


extension BLEChatManager: BLECentralDelegate {

    public func centralDidUpdateState(
        _ state: BLECentralState
    ) {
        isCentralReady = (state == .poweredOn)

        delegate?.chatManagerDidUpdateBluetoothState(state)

        if shouldRun && isCentralReady {
            central.startScan()
        }
    }
    
    public func centralDidFailToSend(to deviceID: UUID,
                                     error: Error)
    {
        // 必要な場合だけ実装する
    }
    
    public func centralDidDiscover(
        _ device: BLEDevice
    ) {
        centralDeviceIDs.insert(device.id)

        delegate?.chatManagerDidDiscover(device)
    }


    public func centralDidReceiveMessage(
        _ message: String,
        from deviceID: UUID
    ) {
        delegate?.chatManagerDidReceiveMessage(
            message,
            from: deviceID
        )
    }

    public func centralDidBecomeReady(
        deviceID: UUID
    ) {
        delegate?.chatManagerDidBecomeReady(
            deviceID: deviceID
        )
    }
}


extension BLEChatManager: BLEConnectionDelegate {

    public func connectionDidChangeState(
        deviceID: UUID,
        state: BLEConnectionState
    ) {
        delegate?.chatManagerDidChangeConnectionState(
            deviceID: deviceID,
            state: state
        )
    }

    public func connectionDidFail(
        deviceID: UUID,
        error: Error?
    ) {
        if let error {
            delegate?.chatManagerDidFail(error)
        }
    }
}


extension BLEChatManager: BLEPeripheralDelegate {

    public func peripheralDidUpdateState(
        _ state: BLEPeripheralState
    ) {
        isPeripheralReady = (state == .poweredOn)

        if shouldRun && isPeripheralReady {
            peripheral.startAdvertising()
        }
    }
    
    public func peripheralDidFailToSend(to centralID: UUID,
                                 error: Error)
    {
           // 必要な場合だけ実装する
    }
    
    public func peripheralDidSubscribe(
        centralID: UUID
    ) {
        peripheralCentralIDs.insert(centralID)
    }

    public func peripheralDidUnsubscribe(
        centralID: UUID
    ) {
        peripheralCentralIDs.remove(centralID)
    }

    public func peripheralDidStartAdvertising() {
        // 必要なら広告開始イベントを公開する
    }

    public func peripheralDidFailToAdvertise(
        error: Error
    ) {
        delegate?.chatManagerDidFail(error)
    }

    public func peripheralDidReceiveMessage(
        _ message: String,
        from centralID: UUID
    ) {
        delegate?.chatManagerDidReceiveMessage(
            message,
            from: centralID
        )
    }
}
