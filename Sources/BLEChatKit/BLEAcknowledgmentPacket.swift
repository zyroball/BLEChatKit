//
//  BLEAcknowledgmentPacket.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/18.
//

import Foundation

struct BLEAcknowledgmentPacket {

    let messageID: UUID

    static let packetSize = 18

    func encode() -> Data {
        var data = Data([0xBC, 0x02])

        var uuid = messageID.uuid

        withUnsafeBytes(of: &uuid) {
            data.append(contentsOf: $0)
        }

        return data
    }

    static func isPacket(_ data: Data) -> Bool {
        guard data.count >= 2 else {
            return false
        }

        return data[data.startIndex] == 0xBC &&
               data[data.startIndex + 1] == 0x02
    }

    static func decode(from data: Data) throws -> Self {
        guard data.count == packetSize,
              isPacket(data)
        else {
            throw BLETransportError.invalidMessage
        }

        let bytes = [UInt8](data)

        let uuid = UUID(uuid: (
            bytes[2], bytes[3], bytes[4], bytes[5],
            bytes[6], bytes[7], bytes[8], bytes[9],
            bytes[10], bytes[11], bytes[12], bytes[13],
            bytes[14], bytes[15], bytes[16], bytes[17]
        ))

        return Self(messageID: uuid)
    }
}
