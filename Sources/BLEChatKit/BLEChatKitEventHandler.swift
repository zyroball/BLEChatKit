//
//  BLEChatKitEventHandler.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/20.
//

import Foundation
import BLEChatKit

@MainActor
final class BLEChatKitEventHandler: BLEChatManagerDelegate {

    func chatManagerDidUpdateBluetoothState(
        _ state: BLECentralState
    ) {
        print("[BLEChatKit] Bluetooth state: \(state)")
    }

    func chatManagerDidDiscover(
        _ device: BLEDevice
    ) {
        print("[BLEChatKit] Device discovered: \(device)")
    }

    func chatManagerDidChangeConnectionState(
        deviceID: UUID,
        state: BLEConnectionState
    ) {
        print("[BLEChatKit] Connection: \(deviceID), \(state)")
    }

    func chatManagerDidBecomeReady(deviceID: UUID) {
        print("[BLEChatKit] Ready: \(deviceID)")
    }

    func chatManagerDidBecomeNotReady(deviceID: UUID) {
        print("[BLEChatKit] Not ready: \(deviceID)")
    }

    func chatManagerDidReceiveMessage(
        _ message: String,
        from deviceID: UUID
    ) {
        print("[BLEChatKit] Received from \(deviceID): \(message)")
    }

    func chatManagerDidFail(_ error: Error) {
        print("[BLEChatKit] Error: \(error)")
    }
}
