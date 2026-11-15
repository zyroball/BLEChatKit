//
//  BLETransport.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/15.
//


import Foundation
import CoreBluetooth

public enum BLETransportError: Error
{
    case invalidMessage
    case messageTooLarge
}

public enum BLETransport
{
    public static func encode(_ message: String) throws -> Data
    {
        guard !message.isEmpty
        else
        {
            throw BLETransportError.invalidMessage
        }

        return Data(message.utf8)
    }

    public static func decode(_ data: Data) throws -> String
    {
        guard let message = String(data: data,
                                   encoding: .utf8)
        else
        {
            throw BLETransportError.invalidMessage
        }

        return message
    }
}
