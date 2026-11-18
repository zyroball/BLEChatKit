//
//  BLEConnection.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/15.
//


import Foundation
import CoreBluetooth

@MainActor
public protocol BLEConnectionDelegate: AnyObject
{
    func connectionDidChangeState(deviceID: UUID, state: BLEConnectionState)
    func connectionDidFail(deviceID: UUID, error: Error?)
}

@MainActor
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
        let deviceID = peripheral.identifier

        // 前回と同じ状態なら通知しない
        if (states[deviceID] ?? .disconnected) == state {
            return
        }

        if state == .disconnected {
            states.removeValue(forKey: deviceID)
        } else {
            states[deviceID] = state
        }

        delegate?.connectionDidChangeState(
            deviceID: deviceID,
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
    
    func disconnectAll()
    {
        let activeDeviceIDs = states.compactMap { deviceID, state in
            state != .disconnected ? deviceID : nil
        }

        states.removeAll()

        for deviceID in activeDeviceIDs {
            delegate?.connectionDidChangeState(
                deviceID: deviceID,
                state: .disconnected
            )
        }
    }
}
