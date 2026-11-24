//
//  BLEMessagePacketBuilder.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/15.
//


import Foundation

public enum BLEMessagePacketBuilder
{
    public static func build(
        message: String,
        chunkSize: Int,
        messageID: UUID = UUID()
    ) throws -> [BLEMessagePacket] {

        guard chunkSize > 0 else {
            throw BLETransportError.invalidMessage
        }

        let data = try BLETransport.encode(message)

        // 受信側の最大容量と合わせる
        guard data.count <= 1_048_576 else {
            throw BLETransportError.messageTooLarge
        }

        // 分割前にチャンク数を確認
        let chunkCount =
            (data.count - 1) / chunkSize + 1

        guard chunkCount <= 10_000 else {
            throw BLETransportError.messageTooLarge
        }

        let chunks = BLEMessageChunker.split(
            data,
            chunkSize: chunkSize
        )

        return chunks.enumerated().map { index, chunk in

            BLEMessagePacket(
                messageID: messageID,
                chunkIndex: index,
                totalChunks: chunks.count,
                payload: chunk
            )
        }
    }
}
