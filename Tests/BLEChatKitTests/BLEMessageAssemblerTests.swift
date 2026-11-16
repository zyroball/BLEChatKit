//
//  BLEMessageAssemblerTests.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/16.
//

import Foundation
import XCTest
@testable import BLEChatKit

final class BLEMessageAssemblerTests: XCTestCase
{

    // MARK: - 1. 正常な分割受信
    func testAssembleTwoChunks()
    {
        let assembler = BLEMessageAssembler()
        let deviceID = UUID()
        let messageID = UUID()

        let packet0 = makePacket(
            messageID: messageID,
            index: 0,
            total: 2,
            text: "Hello "
        )

        let packet1 = makePacket(
            messageID: messageID,
            index: 1,
            total: 2,
            text: "World"
        )

        XCTAssertNil(
            assembler.append(packet0, from: deviceID)
        )

        let result = assembler.append(
            packet1,
            from: deviceID
        )

        XCTAssertEqual(
            String(data: result ?? Data(), encoding: .utf8),
            "Hello World"
        )
    }

    // MARK: - 2. 順不同チャンクの受信

    func testOutOfOrderChunks()
    {
        let assembler = BLEMessageAssembler()
        let deviceID = UUID()
        let messageID = UUID()

        let packet1 = makePacket(
            messageID: messageID,
            index: 1,
            total: 2,
            text: "World"
        )

        let packet0 = makePacket(
            messageID: messageID,
            index: 0,
            total: 2,
            text: "Hello "
        )

        XCTAssertNil(
            assembler.append(packet1, from: deviceID)
        )

        let result = assembler.append(
            packet0,
            from: deviceID
        )

        XCTAssertEqual(
            String(data: result ?? Data(), encoding: .utf8),
            "Hello World"
        )
    }

    // MARK: - 3. 重複チャンクの無視

    func testDuplicateChunk()
    {

        let assembler = BLEMessageAssembler()
        let deviceID = UUID()
        let messageID = UUID()

        let packet0 = makePacket(
            messageID: messageID,
            index: 0,
            total: 2,
            text: "Hello "
        )

        let duplicate = makePacket(
            messageID: messageID,
            index: 0,
            total: 2,
            text: "Changed "
        )

        let packet1 = makePacket(
            messageID: messageID,
            index: 1,
            total: 2,
            text: "World"
        )

        XCTAssertNil(
            assembler.append(packet0, from: deviceID)
        )

        XCTAssertNil(
            assembler.append(duplicate, from: deviceID)
        )

        let result = assembler.append(
            packet1,
            from: deviceID
        )

        XCTAssertEqual(
            String(data: result ?? Data(), encoding: .utf8),
            "Hello World"
        )
    }

    // MARK: - 4. メッセージサイズ制限

    func testMessageSizeLimit()
    {
        let assembler = BLEMessageAssembler()
        let deviceID = UUID()
        let messageID = UUID()

        // 1MBを超えるデータ
        let oversizedData = Data(
            repeating: 0x41,
            count: 1_048_577
        )

        let packet = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 0,
            totalChunks: 1,
            payload: oversizedData
        )

        XCTAssertNil(
            assembler.append(packet, from: deviceID)
        )
    }

    // MARK: - 5. 全バッファのリセット

    func testReset()
    {
        let assembler = BLEMessageAssembler()
        let deviceID = UUID()
        let messageID = UUID()

        let packet0 = makePacket(messageID: messageID,
                                 index: 0,
                                 total: 2,text: "Hello ")

        let packet1 = makePacket(messageID: messageID,
                                 index: 1,
                                 total: 2,
                                 text: "World")

        XCTAssertNil(assembler.append(packet0, from: deviceID))

        assembler.reset()

        // リセット後はチャンク1だけでは完成しない
        XCTAssertNil(assembler.append(packet1, from: deviceID))

        // 改めてチャンク0を受信すると完成
        let result = assembler.append(packet0,
                                      from: deviceID)

        XCTAssertEqual(String(data: result ?? Data(), encoding: .utf8),
                       "Hello World")
    }

    // MARK: - 6. デバイス単位のリセット

    func testResetForDevice() {

        let assembler = BLEMessageAssembler()

        let deviceA = UUID()
        let deviceB = UUID()
        let messageID = UUID()

        let packet0 = makePacket(messageID: messageID,
                                 index: 0,
                                 total: 2,
                                 text: "Hello ")

        let packet1 = makePacket(messageID: messageID,
                                 index: 1,
                                 total: 2,
                                 text: "World")

        XCTAssertNil(assembler.append(packet0, from: deviceA))

        XCTAssertNil(assembler.append(packet0, from: deviceB))

        assembler.reset(for: deviceA)

        // Aはリセットされたため完成しない
        XCTAssertNil(assembler.append(packet1, from: deviceA))

        // Bは影響を受けず完成する
        let resultB = assembler.append(packet1,from: deviceB)

        XCTAssertEqual(String(data: resultB ?? Data(), encoding: .utf8),
            "Hello World")
    }

    // MARK: - Helper

    private func makePacket(messageID: UUID,
                            index: Int,
                            total: Int,
                            text: String) -> BLEMessagePacket
    {
        BLEMessagePacket(messageID: messageID,
                         chunkIndex: index,
                         totalChunks: total,
                         payload: Data(text.utf8))
    }
    
    func testTotalBufferSizeLimit()
    {
        let assembler = BLEMessageAssembler()
        let deviceID = UUID()

        let payload = Data(
            repeating: 0x41,
            count: 1_048_576
        )

        // 10MBまで蓄積
        for _ in 0..<10
        {
            let packet = BLEMessagePacket(messageID: UUID(),
                                          chunkIndex: 0,
                                          totalChunks: 2,
                                          payload: payload)

            XCTAssertNil(assembler.append(packet, from: deviceID))
        }

        XCTAssertEqual(assembler.bufferedByteCount,
                       10_485_760)

        XCTAssertEqual(assembler.pendingMessageCount,
                       10)

        // 10MBを超える追加データ
        let extraPacket = BLEMessagePacket(messageID: UUID(),
                                           chunkIndex: 0,
                                           totalChunks: 2,
                                           payload: Data("Extra".utf8))

        XCTAssertNil(assembler.append(extraPacket, from: deviceID))

        // 拒否されたためサイズと件数は変わらない
        XCTAssertEqual(assembler.bufferedByteCount,10_485_760)

        XCTAssertEqual(assembler.pendingMessageCount,10)
    }
    
    func testMessageTimeout()
    {
        let assembler = BLEMessageAssembler()
        let deviceID = UUID()
        let messageID = UUID()

        let startDate = Date(timeIntervalSince1970: 1_000_000)

        var currentDate = startDate

        assembler.nowProvider = {
            currentDate
        }

        let packet0 = BLEMessagePacket(messageID: messageID,
                                       chunkIndex: 0,
                                       totalChunks: 2,
                                       payload: Data("Hello ".utf8))

        let packet1 = BLEMessagePacket(messageID: messageID,
                                       chunkIndex: 1,
                                       totalChunks: 2,
                                       payload: Data("World".utf8))

        // 最初のチャンクを受信
        XCTAssertNil(assembler.append(packet0, from: deviceID))

        XCTAssertEqual(assembler.pendingMessageCount,1)

        // 31秒経過させる
        currentDate = startDate.addingTimeInterval(31)

        assembler.removeExpiredMessages()

        // タイムアウトで削除されたことを確認
        XCTAssertEqual(assembler.pendingMessageCount,0)

        XCTAssertEqual(assembler.bufferedByteCount,0)

        // 後半だけ受信しても完成しない
        XCTAssertNil(assembler.append(packet1, from: deviceID))
    }
    
    func testConcurrentMessageAssembly()
    {

        let assembler = BLEMessageAssembler()

        let queue = DispatchQueue(
            label: "BLEChatKit.concurrentTest",
            attributes: .concurrent
        )

        let group = DispatchGroup()
        let resultLock = NSLock()

        let deviceID = UUID()

        var completedMessages: [String] = []

        // 20件のメッセージを同時に受信
        for index in 0..<20
        {

            group.enter()

            queue.async
            {
                let messageID = UUID()
                let expected = "Message \(index)"

                let packet0 = BLEMessagePacket(messageID: messageID,
                                               chunkIndex: 0,
                                               totalChunks: 2,
                                               payload: Data("Message ".utf8))

                let packet1 = BLEMessagePacket(messageID: messageID,
                                               chunkIndex: 1,
                                               totalChunks: 2,
                                               payload: Data("\(index)".utf8))

                _ = assembler.append(packet0,from: deviceID)

                let result = assembler.append(packet1,from: deviceID)

                if let result,
                   let text = String(
                       data: result,
                       encoding: .utf8
                   ) {

                    resultLock.lock()
                    completedMessages.append(text)
                    resultLock.unlock()
                }

                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5),.success)

        XCTAssertEqual(completedMessages.count,20)

        XCTAssertEqual(Set(completedMessages),Set((0..<20).map { "Message \($0)" }))
    }
    
    func testMaxPendingMessages()
    {
        let assembler = BLEMessageAssembler()
        let deviceID = UUID()

        // 100件の未完成メッセージを追加
        for _ in 0..<100
        {
            let packet = BLEMessagePacket(messageID: UUID(),
                                          chunkIndex: 0,
                                          totalChunks: 2,
                                          payload: Data("A".utf8))

            XCTAssertNil(assembler.append(packet, from: deviceID))
        }

        XCTAssertEqual(assembler.pendingMessageCount,100)

        XCTAssertEqual(assembler.bufferedByteCount,100)

        // 101件目
        let extraMessageID = UUID()

        let extraPacket = BLEMessagePacket(messageID: extraMessageID,
                                           chunkIndex: 0,
                                           totalChunks: 2,
                                           payload: Data("B".utf8))

        XCTAssertNil(assembler.append(extraPacket, from: deviceID))

        // 101件目が保存されていないことを確認
        XCTAssertEqual(assembler.pendingMessageCount,100)

        XCTAssertEqual(assembler.bufferedByteCount,100)

        // 全バッファを解放
        assembler.reset()

        XCTAssertEqual(assembler.pendingMessageCount,0)

        XCTAssertEqual(assembler.bufferedByteCount,0)
    }
}
