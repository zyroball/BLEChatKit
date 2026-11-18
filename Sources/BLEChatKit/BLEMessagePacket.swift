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
    static var headerSize: Int { 24 }
    func encode() throws -> Data {
        guard chunkIndex >= 0, totalChunks > 0, chunkIndex < totalChunks,
              chunkIndex <= Int(UInt16.max), totalChunks <= Int(UInt16.max), payload.count <= Int(UInt16.max)
        else
        {
            throw BLETransportError.invalidMessage
        }

        var data = Data([0xBC, 0x01])

        var uuid = messageID.uuid
        withUnsafeBytes(of: &uuid)
        {
            data.append(contentsOf: $0)
        }

        func appendUInt16(_ value: UInt16)
        {
            data.append(UInt8(value >> 8))
            data.append(UInt8(value & 0xFF))
        }

        appendUInt16(UInt16(chunkIndex))
        appendUInt16(UInt16(totalChunks))
        appendUInt16(UInt16(payload.count))

        data.append(payload)
        return data
    }

    static func decode(from data: Data) throws -> BLEMessagePacket
    {
        guard data.count >= headerSize,
              data[data.startIndex] == 0xBC,
              data[data.startIndex + 1] == 0x01
        else {
            throw BLETransportError.invalidMessage
        }

        let bytes = [UInt8](data)

        let uuidBytes = Array(bytes[2..<18])
        let uuid = UUID(uuid: (
            uuidBytes[0], uuidBytes[1],
            uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5],
            uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9],
            uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13],
            uuidBytes[14], uuidBytes[15]
        ))

        func readUInt16(_ offset: Int) -> Int {
            (Int(bytes[offset]) << 8) |
            Int(bytes[offset + 1])
        }

        let index = readUInt16(18)
        let total = readUInt16(20)
        let length = readUInt16(22)

        guard total > 0,
              index < total,
              bytes.count == headerSize + length
        else {
            throw BLETransportError.invalidMessage
        }

        return BLEMessagePacket(messageID: uuid,
                                chunkIndex: index,
                                totalChunks: total,
                                payload: Data(bytes[24...]))
    }
    
    static func isPacket(_ data: Data) -> Bool
    {
        guard data.count >= 2
        else
        {
            return false
        }
        return data[data.startIndex] == 0xBC &&
               data[data.startIndex + 1] == 0x01
    }
}
