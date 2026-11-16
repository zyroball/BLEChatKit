//
//  BLEChatManagerDelegate.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/15.
//


import Foundation

import Foundation

@MainActor
public protocol BLEChatManagerDelegate: AnyObject
{
    /// Bluetoothの状態が変更された
    func chatManagerDidUpdateBluetoothState(_ state: BLECentralState)
    /// BLEデバイスを発見した
    func chatManagerDidDiscover(_ device: BLEDevice)
    /// 接続状態が変更された
    func chatManagerDidChangeConnectionState(deviceID: UUID,
                                             state: BLEConnectionState)
    /// 通信準備が完了した
    func chatManagerDidBecomeReady(deviceID: UUID)
    /// メッセージを受信した
    func chatManagerDidReceiveMessage(_ message: String,
                                      from deviceID: UUID)
    /// エラーが発生した
    func chatManagerDidFail(_ error: Error)
}
