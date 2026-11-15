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

public protocol BLEPeripheralDelegate: AnyObject
{
    func peripheralDidUpdateState(_ state: BLEPeripheralState)
    func peripheralDidStartAdvertising()
    func peripheralDidFailToAdvertise(error: Error)
}
