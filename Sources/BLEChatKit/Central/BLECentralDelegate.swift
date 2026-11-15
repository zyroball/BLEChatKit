//
//  BLECentralDelegate.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/15.
//


import Foundation

public protocol BLECentralDelegate: AnyObject
{
    func centralDidUpdateState(_ state: BLECentralState)
    func centralDidDiscover(_ device: BLEDevice)
    func centralDidReceiveMessage(_ message: String, from deviceID: UUID)
    func centralDidBecomeReady(deviceID: UUID)
}

public enum BLECentralState: Equatable
{
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn
}
