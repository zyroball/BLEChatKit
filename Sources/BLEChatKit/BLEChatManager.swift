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

    public func start() {
        shouldRun = true

        if isCentralReady {
            central.startScan()
        }

        if isPeripheralReady {
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

    public func send(
        _ message: String,
        to deviceID: UUID
    ) throws {
        try central.send(message, to: deviceID)
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

    public func centralDidDiscover(
        _ device: BLEDevice
    ) {
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

    public func peripheralDidStartAdvertising() {
        // 必要なら広告開始イベントを公開する
    }

    public func peripheralDidFailToAdvertise(
        error: Error
    ) {
        delegate?.chatManagerDidFail(error)
    }

    public func peripheralDidReceiveMessage(
        _ message: String
    ) {
        // 現状のPeripheral受信イベントには
        // 送信元Centralの識別子が含まれていない。
        // 次のSTEPで送信元IDを渡せるようにする。
        // ここでは誤ったUUIDを作って通知しない。
    }
}
