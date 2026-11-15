//
//  BLEDevice.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/15.
//


import Foundation

public struct BLEDevice: Identifiable, Equatable
{
    public let id: UUID
    public let name: String?
    public let rssi: Int

    public init(id: UUID,
                name: String?,
                rssi: Int)
    {
        self.id = id
        self.name = name
        self.rssi = rssi
    }
}
