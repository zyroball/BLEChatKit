//
//  BLEMessagePacketBuilder.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/15.
//


import Foundation

public enum BLEMessagePacketBuilder
{
    public static func build(message: String,
                             chunkSize: Int,
                             messageID: UUID = UUID()) throws -> [BLEMessagePacket]
    {

        guard chunkSize > 0 else
        {
            throw BLETransportError.invalidMessage
        }

        let data = try BLETransport.encode(message)

        let chunks = BLEMessageChunker.split(data,
                                             chunkSize: chunkSize)

        return chunks.enumerated().map { index, chunk in

            BLEMessagePacket(messageID: messageID,
                             chunkIndex: index,
                             totalChunks: chunks.count,
                             payload: chunk)
        }
    }
}
