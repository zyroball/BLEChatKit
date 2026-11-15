//
//  BLEMessageAssembler.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/15.
//


import Foundation

public final class BLEMessageAssembler
{
    private struct MessageBuffer
    {
        let totalChunks: Int
        var chunks: [Int: Data] = [:]
    }

    private var buffers: [UUID: MessageBuffer] = [:]

    public init() {}

    @discardableResult
    public func append(_ packet: BLEMessagePacket) -> Data?
    {
        guard packet.totalChunks > 0,
              packet.chunkIndex >= 0,
              packet.chunkIndex < packet.totalChunks
        else {
            return nil
        }

        let messageID = packet.messageID

        if buffers[messageID] == nil
        {
            buffers[messageID] = MessageBuffer(
                totalChunks: packet.totalChunks
            )
        }

        guard var buffer = buffers[messageID],
              buffer.totalChunks == packet.totalChunks
        else {
            return nil
        }

        buffer.chunks[packet.chunkIndex] = packet.payload
        buffers[messageID] = buffer

        guard buffer.chunks.count == buffer.totalChunks
        else
        {
            return nil
        }

        var result = Data()

        for index in 0..<buffer.totalChunks {
            guard let chunk = buffer.chunks[index]
            else
            {
                return nil
            }
            result.append(chunk)
        }

        buffers.removeValue(forKey: messageID)

        return result
    }

    public func reset()
    {
        buffers.removeAll()
    }
}
