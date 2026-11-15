//
//  BLEChatManagerDelegate.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/15.
//


import Foundation

public protocol BLEChatManagerDelegate: AnyObject
{
    func chatManagerDidUpdateBluetoothState(_ state: BLECentralState)
    func chatManagerDidDiscover(_ device: BLEDevice)
    func chatManagerDidChangeConnectionState(deviceID: UUID,state: BLEConnectionState)
    func chatManagerDidBecomeReady(deviceID: UUID)
    func chatManagerDidReceiveMessage(_ message: String,from deviceID: UUID)
    func chatManagerDidFail(_ error: Error)
}
