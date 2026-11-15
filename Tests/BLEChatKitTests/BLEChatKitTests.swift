//
//  BLEChatKitTests.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/15.
//

import XCTest
@testable import BLEChatKit

final class BLEChatKitTests: XCTestCase
{

    func testMessageChunking() {

        let message = "Hello BLEChatKit!"

        let data = Data(message.utf8)

        // 5バイトずつ分割
        let chunks = BLEMessageChunker.split(data,
                                             chunkSize: 5)

        print("分割数:", chunks.count)

        // 再構築
        let restoredData = BLEMessageChunker.combine(chunks)

        let restoredMessage = String(data: restoredData,encoding: .utf8)

        print("復元結果:", restoredMessage ?? "失敗")

        XCTAssertEqual(restoredMessage, message)
    }
    
    
    func testMessageAssembly()
    {
        let message = "Hello BLEChatKit! 分割通信テスト"

        let originalData = Data(message.utf8)

        let chunks = BLEMessageChunker.split(originalData,
                                             chunkSize: 5)

        let messageID = UUID()
        let assembler = BLEMessageAssembler()

        var restoredData: Data?

        for (index, chunk) in chunks.enumerated()
        {

            let packet = BLEMessagePacket(messageID: messageID,
                                          chunkIndex: index,
                                          totalChunks: chunks.count,
                                          payload: chunk)

            restoredData = assembler.append(packet)
        }

        XCTAssertEqual(restoredData, originalData)

        print(
            "復元結果:",
            String(data: restoredData ?? Data(), encoding: .utf8) ?? "失敗"
        )
    }
    
    
    func testPacketEncoding() throws
    {

        let original = BLEMessagePacket(messageID: UUID(),
                                        chunkIndex: 0,
                                        totalChunks: 3,
                                        payload: Data("Hello BLE".utf8)
        )

        // Dataへ変換
        let encodedData = try original.encode()

        // Dataから復元
        let decodedPacket = try BLEMessagePacket.decode(from: encodedData)

        XCTAssertEqual(decodedPacket.messageID,
                       original.messageID)

        XCTAssertEqual(decodedPacket.chunkIndex,
                       original.chunkIndex)

        XCTAssertEqual(decodedPacket.totalChunks,
                       original.totalChunks)

        XCTAssertEqual(decodedPacket.payload,
                       original.payload)

        print("Packet encode/decode 成功")
    }


}
