//
//  BLESendError.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/15.
//


import Foundation

public enum BLESendError: Error
{
    case writeFailed
    case writeTimeout
    case notificationTimeout
    case acknowledgmentTimeout
    case queueFull
    case disconnected
}
