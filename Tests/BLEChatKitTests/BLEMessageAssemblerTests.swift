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
    
    // MARK: - 1MB境界値テスト

    func testExactMaximumMessageSize() {

        let assembler = BLEMessageAssembler()
        let deviceID = UUID()
        let messageID = UUID()

        let data = Data(
            repeating: 0x41,
            count: 1_048_576
        )

        let packet = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 0,
            totalChunks: 1,
            payload: data
        )

        let result = assembler.append(
            packet,
            from: deviceID
        )

        XCTAssertEqual(result, data)
    }
    
    // MARK: - サイズ超過後の復旧テスト

    func testRecoveryAfterOversizedMessage() {

        let assembler = BLEMessageAssembler()
        let deviceID = UUID()

        // 1MBを超えるメッセージ
        let oversizedPacket = BLEMessagePacket(
            messageID: UUID(),
            chunkIndex: 0,
            totalChunks: 1,
            payload: Data(repeating: 0x41, count: 1_048_577)
        )

        XCTAssertNil(
            assembler.append(oversizedPacket, from: deviceID)
        )

        // 超過後に正常なメッセージを受信
        let recoveryPacket = BLEMessagePacket(
            messageID: UUID(),
            chunkIndex: 0,
            totalChunks: 1,
            payload: Data("Recovery OK".utf8)
        )

        let result = assembler.append(
            recoveryPacket,
            from: deviceID
        )

        XCTAssertEqual(
            result,
            Data("Recovery OK".utf8)
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
    
    // MARK: - バッファ上限超過後の復旧テスト

    func testRecoveryAfterBufferOverflow() {

        let assembler = BLEMessageAssembler()
        let deviceID = UUID()
        let payload = Data(repeating: 0x41, count: 1_048_576)

        var messageIDs: [UUID] = []

        // 10MB分の未完成メッセージを蓄積
        for _ in 0..<10 {
            let messageID = UUID()
            messageIDs.append(messageID)

            let packet = BLEMessagePacket(
                messageID: messageID,
                chunkIndex: 0,
                totalChunks: 2,
                payload: payload
            )

            XCTAssertNil(assembler.append(packet, from: deviceID))
        }

        XCTAssertEqual(assembler.bufferedByteCount, 10_485_760)

        // 11件目はバッファ上限で拒否される
        let overflowID = UUID()
        let overflowPacket = BLEMessagePacket(
            messageID: overflowID,
            chunkIndex: 0,
            totalChunks: 2,
            payload: Data("Extra".utf8)
        )

        XCTAssertNil(assembler.append(overflowPacket, from: deviceID))
        XCTAssertEqual(assembler.pendingMessageCount, 10)
        
        // 拒否された11件目の後半チャンク
        let overflowLastPacket = BLEMessagePacket(
            messageID: overflowID,
            chunkIndex: 1,
            totalChunks: 2,
            payload: Data("End".utf8)
        )

        XCTAssertNil(
            assembler.append(overflowLastPacket, from: deviceID)
        )

        XCTAssertEqual(
            assembler.pendingMessageCount,
            10
        )

        // 既存10件のメッセージを完成させる
        var restoredCount = 0

        for messageID in messageIDs {
            let packet = BLEMessagePacket(
                messageID: messageID,
                chunkIndex: 1,
                totalChunks: 2,
                payload: Data()
            )

            if let result = assembler.append(packet, from: deviceID),
               result == payload {
                restoredCount += 1
            }
        }

        XCTAssertEqual(restoredCount, 10)
        XCTAssertEqual(assembler.bufferedByteCount, 0)
        XCTAssertEqual(assembler.pendingMessageCount, 0)
    }
    
    // MARK: - 保留メッセージ上限からの復旧

    func testRecoveryAfterMaxPendingMessages() {

        let assembler = BLEMessageAssembler()
        let deviceID = UUID()

        var messageIDs: [UUID] = []

        // 未完成メッセージを100件登録
        for _ in 0..<100 {
            let messageID = UUID()
            messageIDs.append(messageID)

            let packet = BLEMessagePacket(
                messageID: messageID,
                chunkIndex: 0,
                totalChunks: 2,
                payload: Data("Hello".utf8)
            )

            XCTAssertNil(assembler.append(packet, from: deviceID))
        }

        XCTAssertEqual(assembler.pendingMessageCount, 100)

        // 100件のうち1件を完成させる
        let completedPacket = BLEMessagePacket(
            messageID: messageIDs[0],
            chunkIndex: 1,
            totalChunks: 2,
            payload: Data("World".utf8)
        )

        let completed = assembler.append(
            completedPacket,
            from: deviceID
        )

        XCTAssertEqual(completed, Data("HelloWorld".utf8))
        XCTAssertEqual(assembler.pendingMessageCount, 99)

        // 空きができたので新しいメッセージを受信
        let newMessageID = UUID()

        let firstPacket = BLEMessagePacket(
            messageID: newMessageID,
            chunkIndex: 0,
            totalChunks: 2,
            payload: Data("New".utf8)
        )

        let secondPacket = BLEMessagePacket(
            messageID: newMessageID,
            chunkIndex: 1,
            totalChunks: 2,
            payload: Data("Message".utf8)
        )

        XCTAssertNil(assembler.append(firstPacket, from: deviceID))

        let result = assembler.append(secondPacket, from: deviceID)

        XCTAssertEqual(result, Data("NewMessage".utf8))
        XCTAssertEqual(assembler.pendingMessageCount, 99)
    }
    
    // MARK: - 保留上限で拒否されたメッセージの再送

    func testRetryAfterMaxPendingMessages() {

        let assembler = BLEMessageAssembler()
        let deviceID = UUID()
        var messageIDs: [UUID] = []

        // 100件の未完成メッセージを登録
        for _ in 0..<100 {
            let messageID = UUID()
            messageIDs.append(messageID)

            let packet = BLEMessagePacket(
                messageID: messageID,
                chunkIndex: 0,
                totalChunks: 2,
                payload: Data("Hello".utf8)
            )

            XCTAssertNil(assembler.append(packet, from: deviceID))
        }

        XCTAssertEqual(assembler.pendingMessageCount, 100)

        // 101件目の最初のチャンク
        let retryMessageID = UUID()

        let retryPacket0 = BLEMessagePacket(
            messageID: retryMessageID,
            chunkIndex: 0,
            totalChunks: 2,
            payload: Data("Retry".utf8)
        )

        XCTAssertNil(assembler.append(retryPacket0, from: deviceID))
        XCTAssertEqual(assembler.pendingMessageCount, 100)

        // 既存の1件を完成させて空きを作る
        let completionPacket = BLEMessagePacket(
            messageID: messageIDs[0],
            chunkIndex: 1,
            totalChunks: 2,
            payload: Data("World".utf8)
        )

        XCTAssertEqual(
            assembler.append(completionPacket, from: deviceID),
            Data("HelloWorld".utf8)
        )

        XCTAssertEqual(assembler.pendingMessageCount, 99)

        // 拒否された101件目を最初から再送
        XCTAssertNil(assembler.append(retryPacket0, from: deviceID))

        let retryPacket1 = BLEMessagePacket(
            messageID: retryMessageID,
            chunkIndex: 1,
            totalChunks: 2,
            payload: Data("Success".utf8)
        )

        XCTAssertEqual(
            assembler.append(retryPacket1, from: deviceID),
            Data("RetrySuccess".utf8)
        )
    }
    
    // MARK: - 完成済みメッセージの重複防止

    func testCompletedMessageDuplicate() {

        let assembler = BLEMessageAssembler()
        let deviceID = UUID()
        let messageID = UUID()

        let packet = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 0,
            totalChunks: 1,
            payload: Data("Hello".utf8)
        )

        // 1回目は正常に復元
        XCTAssertEqual(
            assembler.append(packet, from: deviceID),
            Data("Hello".utf8)
        )

        // 完成済みMessage IDを登録
        assembler.markMessageCompleted(
            messageID: messageID,
            from: deviceID
        )
        
        // 同じメッセージを再受信
        XCTAssertNil(
            assembler.append(packet, from: deviceID)
        )

        // 不要なバッファが作られていないことも確認
        XCTAssertEqual(assembler.pendingMessageCount, 0)
        XCTAssertEqual(assembler.bufferedByteCount, 0)
    }
    
    // MARK: - 完成済みメッセージのタイムアウト

    func testCompletedMessageTimeout() {

        let assembler = BLEMessageAssembler()

        let deviceID = UUID()
        let messageID = UUID()

        let startDate = Date(timeIntervalSince1970: 1_000_000)
        var currentDate = startDate

        assembler.nowProvider = { currentDate }

        let packet = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 0,
            totalChunks: 1,
            payload: Data("Hello".utf8)
        )

        // 最初の受信
        XCTAssertEqual(
            assembler.append(packet, from: deviceID),
            Data("Hello".utf8)
        )

        // 完成済みMessage IDを登録
        assembler.markMessageCompleted(
            messageID: messageID,
            from: deviceID
        )

        // 299秒後：重複受信を拒否
        currentDate = startDate.addingTimeInterval(299)

        XCTAssertNil(
            assembler.append(packet, from: deviceID)
        )

        // 300秒後：保持期限に到達
        currentDate = startDate.addingTimeInterval(300)

        assembler.removeExpiredMessages()

        // 完成済み履歴が削除され、再び復元できる
        XCTAssertEqual(
            assembler.append(packet, from: deviceID),
            Data("Hello".utf8)
        )
    }
    
    // MARK: - 不正な分割数の拒否

    func testInvalidTotalChunks() {

        let assembler = BLEMessageAssembler()
        let deviceID = UUID()

        // 分割数が0
        let zeroPacket = BLEMessagePacket(
            messageID: UUID(),
            chunkIndex: 0,
            totalChunks: 0,
            payload: Data("Hello".utf8)
        )

        XCTAssertNil(assembler.append(zeroPacket, from: deviceID))

        // 上限10,000を超える
        let oversizedPacket = BLEMessagePacket(
            messageID: UUID(),
            chunkIndex: 0,
            totalChunks: 10_001,
            payload: Data("Hello".utf8)
        )

        XCTAssertNil(assembler.append(oversizedPacket, from: deviceID))

        // 不正なデータがバッファに残らないこと
        XCTAssertEqual(assembler.pendingMessageCount, 0)
        XCTAssertEqual(assembler.bufferedByteCount, 0)
    }
    
    
    func testInconsistentTotalChunks() {

        let assembler = BLEMessageAssembler()
        let deviceID = UUID()
        let messageID = UUID()

        let first = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 0,
            totalChunks: 3,
            payload: Data("Hello".utf8)
        )

        let invalid = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 1,
            totalChunks: 2,
            payload: Data("World".utf8)
        )

        XCTAssertNil(assembler.append(first, from: deviceID))

        XCTAssertEqual(assembler.pendingMessageCount, 1)

        // 同じmessageIDなのに分割数が異なる
        XCTAssertNil(assembler.append(invalid, from: deviceID))

        // 不正なパケットによって既存バッファが増えない
        XCTAssertEqual(assembler.pendingMessageCount, 1)
        XCTAssertEqual(assembler.bufferedByteCount, 5)
    }

}
