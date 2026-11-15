//
//  BLEConnectionState.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/15.
//


import Foundation

public enum BLEConnectionState: Equatable
{
    case disconnected
    case connecting
    case connected
    case disconnecting
}
