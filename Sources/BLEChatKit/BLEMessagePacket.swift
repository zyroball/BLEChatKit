//
//  BLEMessagePacket.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/15.
//


import Foundation

public struct BLEMessagePacket: Codable
{
    public let messageID: UUID
    public let chunkIndex: Int
    public let totalChunks: Int
    public let payload: Data

    public init(messageID: UUID,
                chunkIndex: Int,
                totalChunks: Int,
                payload: Data)
    {
        self.messageID = messageID
        self.chunkIndex = chunkIndex
        self.totalChunks = totalChunks
        self.payload = payload
    }
}



public extension BLEMessagePacket
{
    func encode() throws -> Data
    {
        try JSONEncoder().encode(self)
    }

    static func decode(from data: Data) throws -> BLEMessagePacket
    {
        try JSONDecoder().decode(BLEMessagePacket.self,
                                 from: data)
    }
}
