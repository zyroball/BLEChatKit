//
//  BLEMessageAssemblerDuplicateTests.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/20.
//

import XCTest
@testable import BLEChatKit

final class BLEMessageAssemblerDuplicateTests: XCTestCase {

    func testDuplicateMessageIsNotDeliveredTwice() throws {

        let assembler = BLEMessageAssembler()

        let deviceID = UUID()
        let messageID = UUID()

        let packet = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 0,
            totalChunks: 1,
            payload: Data("HELLO".utf8)
        )

        // 1回目の受信
        let firstResult = assembler.append(
            packet,
            from: deviceID
        )

        XCTAssertEqual(
            firstResult,
            Data("HELLO".utf8)
        )

        // アプリへの配信後、完成済みとして登録
        assembler.markMessageCompleted(
            messageID: messageID,
            from: deviceID
        )

        XCTAssertTrue(
            assembler.isMessageCompleted(
                messageID: messageID,
                from: deviceID
            )
        )

        // 同じMessage IDのパケットを再受信
        let duplicateResult = assembler.append(
            packet,
            from: deviceID
        )

        // 重複メッセージは返されない
        XCTAssertNil(duplicateResult)
    }
    
    func testCompletedMessageSurvivesPendingReset() {

        let assembler = BLEMessageAssembler()

        let deviceID = UUID()
        let messageID = UUID()

        let packet = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 0,
            totalChunks: 1,
            payload: Data("HELLO".utf8)
        )

        // 初回受信
        XCTAssertEqual(
            assembler.append(packet, from: deviceID),
            Data("HELLO".utf8)
        )

        // 完成済みとして登録
        assembler.markMessageCompleted(
            messageID: messageID,
            from: deviceID
        )

        // BLE切断時を想定
        assembler.resetPendingMessages(for: deviceID)

        // 完成済み履歴は保持される
        XCTAssertTrue(
            assembler.isMessageCompleted(
                messageID: messageID,
                from: deviceID
            )
        )

        // 再接続後、同じMessage IDを受信
        XCTAssertNil(
            assembler.append(packet, from: deviceID)
        )
    }
    
    func testCompletedMessagesSurviveAllPendingReset() {

        let assembler = BLEMessageAssembler()

        let deviceA = UUID()
        let deviceB = UUID()

        let messageA = UUID()
        let messageB = UUID()

        let packetA = BLEMessagePacket(
            messageID: messageA,
            chunkIndex: 0,
            totalChunks: 1,
            payload: Data("Device A".utf8)
        )

        let packetB = BLEMessagePacket(
            messageID: messageB,
            chunkIndex: 0,
            totalChunks: 1,
            payload: Data("Device B".utf8)
        )

        // 両デバイスのメッセージを復元
        XCTAssertEqual(
            assembler.append(packetA, from: deviceA),
            Data("Device A".utf8)
        )

        XCTAssertEqual(
            assembler.append(packetB, from: deviceB),
            Data("Device B".utf8)
        )

        // 完成済みとして登録
        assembler.markMessageCompleted(
            messageID: messageA,
            from: deviceA
        )

        assembler.markMessageCompleted(
            messageID: messageB,
            from: deviceB
        )

        // 全接続の未完成バッファをリセット
        assembler.resetAllPendingMessages()

        // 完成済み履歴は両方とも保持される
        XCTAssertTrue(
            assembler.isMessageCompleted(
                messageID: messageA,
                from: deviceA
            )
        )

        XCTAssertTrue(
            assembler.isMessageCompleted(
                messageID: messageB,
                from: deviceB
            )
        )

        // 同じメッセージの重複復元を拒否
        XCTAssertNil(
            assembler.append(packetA, from: deviceA)
        )

        XCTAssertNil(
            assembler.append(packetB, from: deviceB)
        )
    }
    
    func testPendingResetClearsIncompleteMessage() {

        let assembler = BLEMessageAssembler()

        let deviceID = UUID()
        let messageID = UUID()

        let firstPacket = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 0,
            totalChunks: 2,
            payload: Data("HELLO".utf8)
        )

        let secondPacket = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 1,
            totalChunks: 2,
            payload: Data(" WORLD".utf8)
        )

        // 最初のチャンクを受信
        XCTAssertNil(
            assembler.append(firstPacket, from: deviceID)
        )

        XCTAssertEqual(assembler.pendingMessageCount, 1)

        // BLE切断を想定して未完成バッファを削除
        assembler.resetPendingMessages(for: deviceID)

        XCTAssertEqual(assembler.pendingMessageCount, 0)
        XCTAssertEqual(assembler.bufferedByteCount, 0)

        // 再接続後、2番目のチャンクだけ届いても
        // 古いチャンクと結合されない
        XCTAssertNil(
            assembler.append(secondPacket, from: deviceID)
        )

        // 最初のチャンクを再送すると復元できる
        XCTAssertEqual(
            assembler.append(firstPacket, from: deviceID),
            Data("HELLO WORLD".utf8)
        )
    }
    
    func testAllPendingResetClearsIncompleteMessages() {

        let assembler = BLEMessageAssembler()

        let deviceA = UUID()
        let deviceB = UUID()

        let packetA = BLEMessagePacket(
            messageID: UUID(),
            chunkIndex: 0,
            totalChunks: 2,
            payload: Data("Device A".utf8)
        )

        let packetB = BLEMessagePacket(
            messageID: UUID(),
            chunkIndex: 0,
            totalChunks: 2,
            payload: Data("Device B".utf8)
        )

        // 両デバイスで未完成メッセージを受信
        XCTAssertNil(
            assembler.append(packetA, from: deviceA)
        )

        XCTAssertNil(
            assembler.append(packetB, from: deviceB)
        )

        XCTAssertEqual(assembler.pendingMessageCount, 2)

        // 全接続の未完成バッファを削除
        assembler.resetAllPendingMessages()

        // 両デバイスのバッファが削除される
        XCTAssertEqual(assembler.pendingMessageCount, 0)
        XCTAssertEqual(assembler.bufferedByteCount, 0)
    }
}
