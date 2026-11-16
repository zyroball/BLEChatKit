//
//  BLEMessagePacketTests.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/16.
//

import XCTest
@testable import BLEChatKit

final class BLEMessagePacketTests: XCTestCase {

    func testEncodeDecode() throws {

        let messageID = UUID()
        let original = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 1,
            totalChunks: 3,
            payload: Data("Hello BLEChatKit!".utf8)
        )

        let encoded = try original.encode()
        let decoded = try BLEMessagePacket.decode(from: encoded)

        XCTAssertEqual(decoded.messageID, original.messageID)
        XCTAssertEqual(decoded.chunkIndex, original.chunkIndex)
        XCTAssertEqual(decoded.totalChunks, original.totalChunks)
        XCTAssertEqual(decoded.payload, original.payload)

        XCTAssertEqual(
            encoded.count,
            BLEMessagePacket.headerSize + original.payload.count
        )
    }
    
    func testInvalidPacket() {

        let invalidData = Data([
            0x00, 0x00, 0x01, 0x02
        ])

        XCTAssertThrowsError(
            try BLEMessagePacket.decode(
                from: invalidData
            )
        )
    }
    
    func testInvalidChunkIndex() throws {

        let packet = BLEMessagePacket(
            messageID: UUID(),
            chunkIndex: 0,
            totalChunks: 3,
            payload: Data("Hello".utf8)
        )

        var encoded = try packet.encode()

        // chunkIndexを0から3に変更
        // totalChunksが3なら有効な番号は0, 1, 2
        encoded[18] = 0
        encoded[19] = 3

        XCTAssertThrowsError(
            try BLEMessagePacket.decode(from: encoded)
        )
    }
    
    func testInterleavedMessages() {

        let assembler = BLEMessageAssembler()
        let deviceID = UUID()

        let messageA = UUID()
        let messageB = UUID()

        func packet(
            _ id: UUID,
            _ index: Int,
            _ text: String
        ) -> BLEMessagePacket {
            BLEMessagePacket(
                messageID: id,
                chunkIndex: index,
                totalChunks: 2,
                payload: Data(text.utf8)
            )
        }

        // AとBの最初のチャンクを受信
        XCTAssertNil(
            assembler.append(
                packet(messageA, 0, "Hello "),
                from: deviceID
            )
        )

        XCTAssertNil(
            assembler.append(
                packet(messageB, 0, "Good "),
                from: deviceID
            )
        )

        // Bを先に完成させる
        let resultB = assembler.append(
            packet(messageB, 1, "Morning"),
            from: deviceID
        )

        XCTAssertEqual(
            String(data: resultB ?? Data(), encoding: .utf8),
            "Good Morning"
        )

        // Aを後から完成させる
        let resultA = assembler.append(
            packet(messageA, 1, "BLEChatKit"),
            from: deviceID
        )

        XCTAssertEqual(
            String(data: resultA ?? Data(), encoding: .utf8),
            "Hello BLEChatKit"
        )

        XCTAssertEqual(assembler.pendingMessageCount, 0)
    }
    
    func testInvalidPayloadLength() throws {
        let packet = BLEMessagePacket(
            messageID: UUID(),
            chunkIndex: 0,
            totalChunks: 1,
            payload: Data("Hello".utf8)
        )

        var encoded = try packet.encode()

        // ヘッダーのpayload長を5から100に変更
        encoded[22] = 0
        encoded[23] = 100

        XCTAssertThrowsError(
            try BLEMessagePacket.decode(from: encoded)
        )
    }
}
