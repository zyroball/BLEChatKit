//
//  BLEPeripheralDelegate.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/15.
//


import Foundation

public enum BLEPeripheralState: Equatable
{
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn
}

@MainActor
public protocol BLEPeripheralDelegate: AnyObject
{
    func peripheralDidUpdateState(_ state: BLEPeripheralState)
    func peripheralDidStartAdvertising()
    func peripheralDidFailToAdvertise(error: Error)
    func peripheralDidReceiveMessage(_ message: String,from centralID: UUID)
    func peripheralDidSubscribe(centralID: UUID)
    func peripheralDidUnsubscribe(centralID: UUID)
    func peripheralDidFailToSend(to centralID: UUID, error: Error)
    func peripheralDidFinishEnqueuing(to centralID: UUID)
    func peripheralDidFinishEnqueuing(messageID: UUID, to centralID: UUID)
}
