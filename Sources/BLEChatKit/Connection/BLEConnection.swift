//
//  BLEConnection.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/15.
//


import Foundation
import CoreBluetooth

public protocol BLEConnectionDelegate: AnyObject
{
    func connectionDidChangeState(deviceID: UUID, state: BLEConnectionState)
    func connectionDidFail(deviceID: UUID, error: Error?)
}

public final class BLEConnection
{
    public weak var delegate: BLEConnectionDelegate?

    private(set) var states: [UUID: BLEConnectionState] = [:]

    public init() {}

    public func state(for deviceID: UUID) -> BLEConnectionState
    {
        states[deviceID] ?? .disconnected
    }

    func updateState(for peripheral: CBPeripheral,
                     to state: BLEConnectionState)
    {
        states[peripheral.identifier] = state

        delegate?.connectionDidChangeState(
            deviceID: peripheral.identifier,
            state: state
        )
    }

    func notifyFailure(for peripheral: CBPeripheral,
                       error: Error?)
    {
        updateState(for: peripheral,
                    to: .disconnected)

        delegate?.connectionDidFail(deviceID: peripheral.identifier,
                                    error: error)
    }
}
