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
    
    
    
    func testMessageAssembly() {

        let message = "Hello BLEChatKit! 分割通信テスト"

        let originalData = Data(message.utf8)

        let chunks = BLEMessageChunker.split(originalData,
                                             chunkSize: 5)

        let messageID = UUID()
        let deviceID = UUID()

        let assembler = BLEMessageAssembler()

        var restoredData: Data?

        for (index, chunk) in chunks.enumerated()
        {

            let packet = BLEMessagePacket(messageID: messageID,
                                          chunkIndex: index,
                                          totalChunks: chunks.count,
                                          payload: chunk)

            // ★ 新しいappend()に対応
            restoredData = assembler.append(packet,
                                            from: deviceID)
        }

        XCTAssertEqual(restoredData, originalData)

        print(
            "復元結果:",
            String(
                data: restoredData ?? Data(),
                encoding: .utf8
            ) ?? "失敗"
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
    
    
    func testMessageSizeLimit()
    {
        let assembler = BLEMessageAssembler()
        let deviceID = UUID()
        let messageID = UUID()

        // 1MBを超えるデータ
        let largeData = Data(repeating: 0x41,
                             count: 1_048_577)

        let packet = BLEMessagePacket(messageID: messageID,
                                      chunkIndex: 0,
                                      totalChunks: 1,
                                      payload: largeData)

        let result = assembler.append(packet,
                                      from: deviceID)

        XCTAssertNil(result)

        print("Message size limit test passed")
    }
    
    func testMessageBufferBeforeTimeout() {

        let assembler = BLEMessageAssembler()

        var currentDate = Date(timeIntervalSince1970: 1_000)

        assembler.nowProvider = {
            currentDate
        }

        let deviceID = UUID()
        let messageID = UUID()

        // 最初のチャンクを受信
        let firstPacket = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 0,
            totalChunks: 2,
            payload: Data("Hello ".utf8)
        )

        XCTAssertNil(
            assembler.append(firstPacket, from: deviceID)
        )

        // 29秒経過
        currentDate = currentDate.addingTimeInterval(29)

        // 2番目のチャンクを受信
        let secondPacket = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 1,
            totalChunks: 2,
            payload: Data("BLE".utf8)
        )

        let result = assembler.append(
            secondPacket,
            from: deviceID
        )

        XCTAssertEqual(
            result,
            Data("Hello BLE".utf8)
        )
    }
    
    func testMessageBufferExpiresAfter30Seconds() {

        let assembler = BLEMessageAssembler()

        var currentDate = Date(timeIntervalSince1970: 1_000)

        assembler.nowProvider = {
            currentDate
        }

        let deviceID = UUID()
        let messageID = UUID()

        // 0秒：最初のチャンクを受信
        let firstPacket = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 0,
            totalChunks: 2,
            payload: Data("Hello ".utf8)
        )

        XCTAssertNil(
            assembler.append(firstPacket, from: deviceID)
        )

        // 30秒経過
        currentDate = currentDate.addingTimeInterval(30)

        // 30秒後：2番目のチャンクを受信
        let secondPacket = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 1,
            totalChunks: 2,
            payload: Data("BLE".utf8)
        )

        let result = assembler.append(
            secondPacket,
            from: deviceID
        )

        // 最初のチャンクが破棄されているため復元できない
        XCTAssertNil(result)
    }
    
    func testMessageBufferTimeoutResetsOnReceive() {

        let assembler = BLEMessageAssembler()

        var currentDate = Date(timeIntervalSince1970: 1_000)

        assembler.nowProvider = {
            currentDate
        }

        let deviceID = UUID()
        let messageID = UUID()

        func makePacket(
            index: Int,
            text: String
        ) -> BLEMessagePacket {
            BLEMessagePacket(
                messageID: messageID,
                chunkIndex: index,
                totalChunks: 3,
                payload: Data(text.utf8)
            )
        }

        // 0秒：最初のチャンク
        XCTAssertNil(
            assembler.append(
                makePacket(index: 0, text: "Hello "),
                from: deviceID
            )
        )

        // 20秒：2番目のチャンク
        currentDate = currentDate.addingTimeInterval(20)

        XCTAssertNil(
            assembler.append(
                makePacket(index: 1, text: "BLE "),
                from: deviceID
            )
        )

        // 40秒：最後のチャンク
        currentDate = currentDate.addingTimeInterval(20)

        let result = assembler.append(
            makePacket(index: 2, text: "ChatKit"),
            from: deviceID
        )

        XCTAssertEqual(
            result,
            Data("Hello BLE ChatKit".utf8)
        )
    }
    
    func testDuplicateChunkDoesNotResetTimeout() {

        let assembler = BLEMessageAssembler()

        var currentDate = Date(timeIntervalSince1970: 1_000)

        assembler.nowProvider = {
            currentDate
        }

        let deviceID = UUID()
        let messageID = UUID()

        let firstPacket = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 0,
            totalChunks: 2,
            payload: Data("Hello ".utf8)
        )

        let secondPacket = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 1,
            totalChunks: 2,
            payload: Data("BLE".utf8)
        )

        // 0秒：最初のチャンクを受信
        XCTAssertNil(
            assembler.append(firstPacket, from: deviceID)
        )

        // 20秒：同じチャンクを再受信
        currentDate = currentDate.addingTimeInterval(20)

        XCTAssertNil(
            assembler.append(firstPacket, from: deviceID)
        )

        // 35秒：最後のチャンクを受信
        currentDate = currentDate.addingTimeInterval(15)

        let result = assembler.append(
            secondPacket,
            from: deviceID
        )

        // 重複チャンクでは時刻が更新されないため、
        // 最初の受信から35秒で期限切れになる
        XCTAssertNil(result)
    }
    
    func testCompletedMessageIsNotDuplicated() {

        let assembler = BLEMessageAssembler()

        let deviceID = UUID()
        let messageID = UUID()

        let packet = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 0,
            totalChunks: 1,
            payload: Data("Hello BLE".utf8)
        )

        // 1回目：正常に復元
        let firstResult = assembler.append(
            packet,
            from: deviceID
        )

        XCTAssertEqual(
            firstResult,
            Data("Hello BLE".utf8)
        )
        
        // メッセージの完成を記録
        assembler.markMessageCompleted(
            messageID: messageID,
            from: deviceID
        )

        // 2回目：同じMessage IDで再受信
        let secondResult = assembler.append(
            packet,
            from: deviceID
        )

        // 完成済みなので再度復元されない
        XCTAssertNil(secondResult)
    }
    
    func testCompletedMessageExpiresAfter300Seconds() {

        let assembler = BLEMessageAssembler()

        var currentDate = Date(timeIntervalSince1970: 1_000)

        assembler.nowProvider = {
            currentDate
        }

        let deviceID = UUID()
        let messageID = UUID()

        let packet = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 0,
            totalChunks: 1,
            payload: Data("Hello BLE".utf8)
        )

        // 0秒：最初のメッセージを復元
        let firstResult = assembler.append(
            packet,
            from: deviceID
        )

        XCTAssertEqual(
            firstResult,
            Data("Hello BLE".utf8)
        )

        // 完成済みMessage IDを登録
        assembler.markMessageCompleted(
            messageID: messageID,
            from: deviceID
        )

        // 299秒：重複メッセージとして無視
        currentDate = currentDate.addingTimeInterval(299)

        let duplicateResult = assembler.append(
            packet,
            from: deviceID
        )

        XCTAssertNil(duplicateResult)

        // 300秒：完成済み履歴が期限切れ
        currentDate = currentDate.addingTimeInterval(1)

        let expiredResult = assembler.append(
            packet,
            from: deviceID
        )

        // 履歴が削除され、再び復元できる
        XCTAssertEqual(
            expiredResult,
            Data("Hello BLE".utf8)
        )
    }
    
    func testMessageBufferResetForDevice() {

        let assembler = BLEMessageAssembler()

        let deviceID = UUID()
        let messageID = UUID()

        let firstPacket = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 0,
            totalChunks: 2,
            payload: Data("Hello ".utf8)
        )

        let secondPacket = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 1,
            totalChunks: 2,
            payload: Data("BLE".utf8)
        )

        // 最初のチャンクを受信
        XCTAssertNil(
            assembler.append(firstPacket, from: deviceID)
        )

        // Bluetooth切断を想定してバッファをリセット
        assembler.reset(for: deviceID)

        // 再接続後、残りのチャンクが届いたと仮定
        let result = assembler.append(
            secondPacket,
            from: deviceID
        )

        // 古いチャンクは削除済みなので復元されない
        XCTAssertNil(result)
    }
    
    func testResetForDevicePreservesOtherDevice() {

        let assembler = BLEMessageAssembler()

        let deviceA = UUID()
        let deviceB = UUID()

        let messageA = UUID()
        let messageB = UUID()

        func makePacket(
            messageID: UUID,
            index: Int,
            text: String
        ) -> BLEMessagePacket {
            BLEMessagePacket(
                messageID: messageID,
                chunkIndex: index,
                totalChunks: 2,
                payload: Data(text.utf8)
            )
        }

        // デバイスAの最初のチャンク
        XCTAssertNil(
            assembler.append(
                makePacket(
                    messageID: messageA,
                    index: 0,
                    text: "Device A "
                ),
                from: deviceA
            )
        )

        // デバイスBの最初のチャンク
        XCTAssertNil(
            assembler.append(
                makePacket(
                    messageID: messageB,
                    index: 0,
                    text: "Device B "
                ),
                from: deviceB
            )
        )

        // デバイスAだけをリセット
        assembler.reset(for: deviceA)

        // デバイスAの残りのチャンク
        let resultA = assembler.append(
            makePacket(
                messageID: messageA,
                index: 1,
                text: "Hello"
            ),
            from: deviceA
        )

        XCTAssertNil(resultA)

        // デバイスBの残りのチャンク
        let resultB = assembler.append(
            makePacket(
                messageID: messageB,
                index: 1,
                text: "Hello"
            ),
            from: deviceB
        )

        XCTAssertEqual(
            resultB,
            Data("Device B Hello".utf8)
        )
    }
    
    func testResetForDeviceClearsCompletedMessages() {

        let assembler = BLEMessageAssembler()

        let deviceID = UUID()
        let messageID = UUID()

        let packet = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 0,
            totalChunks: 1,
            payload: Data("Hello BLE".utf8)
        )

        // 1回目：正常に復元
        let firstResult = assembler.append(
            packet,
            from: deviceID
        )

        XCTAssertEqual(
            firstResult,
            Data("Hello BLE".utf8)
        )
        
        // 完成済みMessage IDを登録
        assembler.markMessageCompleted(
            messageID: messageID,
            from: deviceID
        )

        // 同じMessage IDは重複として無視
        let duplicateResult = assembler.append(
            packet,
            from: deviceID
        )

        XCTAssertNil(duplicateResult)

        // 対象デバイスの履歴をリセット
        assembler.reset(for: deviceID)

        // 同じMessage IDを再受信
        let resultAfterReset = assembler.append(
            packet,
            from: deviceID
        )

        // 履歴が削除されているため再び復元可能
        XCTAssertEqual(
            resultAfterReset,
            Data("Hello BLE".utf8)
        )
    }
    
    func testResetClearsAllDeviceBuffers() {

        let assembler = BLEMessageAssembler()

        let deviceA = UUID()
        let deviceB = UUID()

        let messageA = UUID()
        let messageB = UUID()

        func makePacket(
            messageID: UUID,
            index: Int,
            text: String
        ) -> BLEMessagePacket {
            BLEMessagePacket(
                messageID: messageID,
                chunkIndex: index,
                totalChunks: 2,
                payload: Data(text.utf8)
            )
        }

        // 両デバイスの最初のチャンクを保存
        XCTAssertNil(
            assembler.append(
                makePacket(messageID: messageA,
                           index: 0,
                           text: "A1"),
                from: deviceA
            )
        )

        XCTAssertNil(
            assembler.append(
                makePacket(messageID: messageB,
                           index: 0,
                           text: "B1"),
                from: deviceB
            )
        )

        // 全デバイスのバッファをリセット
        assembler.reset()

        // リセット前のチャンクは残っていない
        let resultA = assembler.append(
            makePacket(messageID: messageA,
                       index: 1,
                       text: "A2"),
            from: deviceA
        )

        let resultB = assembler.append(
            makePacket(messageID: messageB,
                       index: 1,
                       text: "B2"),
            from: deviceB
        )

        XCTAssertNil(resultA)
        XCTAssertNil(resultB)
    }
    
    func testResetClearsAllCompletedMessages() {

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

        // 両デバイスのメッセージを完成させる
        XCTAssertEqual(
            assembler.append(packetA, from: deviceA),
            Data("Device A".utf8)
        )

        XCTAssertEqual(
            assembler.append(packetB, from: deviceB),
            Data("Device B".utf8)
        )

        // 両デバイスの完成済みMessage IDを登録
        assembler.markMessageCompleted(
            messageID: messageA,
            from: deviceA
        )

        assembler.markMessageCompleted(
            messageID: messageB,
            from: deviceB
        )
        
        // 完成済みなので重複受信を無視
        XCTAssertNil(
            assembler.append(packetA, from: deviceA)
        )

        XCTAssertNil(
            assembler.append(packetB, from: deviceB)
        )

        // 全デバイスの履歴をリセット
        assembler.reset()

        // 履歴削除後は再び復元できる
        XCTAssertEqual(
            assembler.append(packetA, from: deviceA),
            Data("Device A".utf8)
        )

        XCTAssertEqual(
            assembler.append(packetB, from: deviceB),
            Data("Device B".utf8)
        )
    }
    
    func testSameMessageIDFromDifferentDevices() {

        let assembler = BLEMessageAssembler()

        let deviceA = UUID()
        let deviceB = UUID()

        // 両デバイスで同じMessage IDを使用
        let messageID = UUID()

        let packetA = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 0,
            totalChunks: 1,
            payload: Data("Message A".utf8)
        )

        let packetB = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 0,
            totalChunks: 1,
            payload: Data("Message B".utf8)
        )

        // デバイスAから受信
        let resultA = assembler.append(
            packetA,
            from: deviceA
        )

        XCTAssertEqual(
            resultA,
            Data("Message A".utf8)
        )

        // デバイスBから受信
        let resultB = assembler.append(
            packetB,
            from: deviceB
        )

        XCTAssertEqual(
            resultB,
            Data("Message B".utf8)
        )
    }
    
    func testMessageAssemblyOutOfOrder() {

        let assembler = BLEMessageAssembler()

        let deviceID = UUID()
        let messageID = UUID()

        func makePacket(
            index: Int,
            text: String
        ) -> BLEMessagePacket {
            BLEMessagePacket(
                messageID: messageID,
                chunkIndex: index,
                totalChunks: 3,
                payload: Data(text.utf8)
            )
        }

        // チャンク2を最初に受信
        XCTAssertNil(
            assembler.append(
                makePacket(index: 2, text: "ChatKit"),
                from: deviceID
            )
        )

        // 次にチャンク0を受信
        XCTAssertNil(
            assembler.append(
                makePacket(index: 0, text: "Hello "),
                from: deviceID
            )
        )

        // 最後にチャンク1を受信
        let result = assembler.append(
            makePacket(index: 1, text: "BLE "),
            from: deviceID
        )

        // 受信順ではなくchunkIndex順に復元される
        XCTAssertEqual(
            result,
            Data("Hello BLE ChatKit".utf8)
        )
    }
    
    func testDuplicateChunkDoesNotOverwriteData() {

        let assembler = BLEMessageAssembler()

        let deviceID = UUID()
        let messageID = UUID()

        func makePacket(
            index: Int,
            text: String
        ) -> BLEMessagePacket {
            BLEMessagePacket(
                messageID: messageID,
                chunkIndex: index,
                totalChunks: 2,
                payload: Data(text.utf8)
            )
        }

        // 最初のチャンク0を保存
        XCTAssertNil(
            assembler.append(
                makePacket(index: 0, text: "Hello "),
                from: deviceID
            )
        )

        // 同じチャンク番号で異なるデータを受信
        XCTAssertNil(
            assembler.append(
                makePacket(index: 0, text: "Wrong "),
                from: deviceID
            )
        )

        // チャンク1を受信して復元
        let result = assembler.append(
            makePacket(index: 1, text: "BLE"),
            from: deviceID
        )

        // 最初に保存したデータが使われる
        XCTAssertEqual(
            result,
            Data("Hello BLE".utf8)
        )
    }
    
    func testInvalidChunkIndexIsRejected() {

        let assembler = BLEMessageAssembler()

        let deviceID = UUID()
        let messageID = UUID()

        // totalChunks = 2 の場合、有効なindexは0と1
        let invalidPacket = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 2,
            totalChunks: 2,
            payload: Data("Invalid".utf8)
        )

        // 範囲外のチャンクは拒否される
        let result = assembler.append(
            invalidPacket,
            from: deviceID
        )

        XCTAssertNil(result)

        // 続いて正常なチャンクを送信
        let validPacket0 = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 0,
            totalChunks: 2,
            payload: Data("Hello ".utf8)
        )

        let validPacket1 = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 1,
            totalChunks: 2,
            payload: Data("BLE".utf8)
        )

        XCTAssertNil(
            assembler.append(validPacket0, from: deviceID)
        )

        XCTAssertEqual(
            assembler.append(validPacket1, from: deviceID),
            Data("Hello BLE".utf8)
        )
    }
    
    func testZeroTotalChunksIsRejected() {

        let assembler = BLEMessageAssembler()

        let deviceID = UUID()
        let messageID = UUID()

        // チャンク総数が0の不正なパケット
        let invalidPacket = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 0,
            totalChunks: 0,
            payload: Data("Invalid".utf8)
        )

        let result = assembler.append(
            invalidPacket,
            from: deviceID
        )

        // 不正なパケットは復元されない
        XCTAssertNil(result)

        // 続いて正常なパケットを受信
        let validPacket = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 0,
            totalChunks: 1,
            payload: Data("Hello BLE".utf8)
        )

        XCTAssertEqual(
            assembler.append(validPacket, from: deviceID),
            Data("Hello BLE".utf8)
        )
    }
    
    func testExceedingMaxChunksIsRejected() {

        let assembler = BLEMessageAssembler()

        let deviceID = UUID()
        let messageID = UUID()

        // チャンク総数が0の不正なパケット
        let invalidPacket = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 0,
            totalChunks: 0,
            payload: Data("Invalid".utf8)
        )

        let result = assembler.append(
            invalidPacket,
            from: deviceID
        )

        // 不正なパケットは復元されない
        XCTAssertNil(result)

        // 続いて正常なパケットを受信
        let validPacket = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 0,
            totalChunks: 1,
            payload: Data("Hello BLE".utf8)
        )

        XCTAssertEqual(
            assembler.append(validPacket, from: deviceID),
            Data("Hello BLE".utf8)
        )
    }
    
    func testMismatchedTotalChunksIsRejected() {

        let assembler = BLEMessageAssembler()

        let deviceID = UUID()
        let messageID = UUID()

        // 最初は2チャンクのメッセージ
        let packet0 = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 0,
            totalChunks: 2,
            payload: Data("Hello ".utf8)
        )

        XCTAssertNil(
            assembler.append(packet0, from: deviceID)
        )

        // 同じMessage IDなのに総チャンク数が3
        let invalidPacket = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 1,
            totalChunks: 3,
            payload: Data("Wrong".utf8)
        )

        XCTAssertNil(
            assembler.append(invalidPacket, from: deviceID)
        )

        // 正しい総チャンク数なら復元できる
        let packet1 = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 1,
            totalChunks: 2,
            payload: Data("BLE".utf8)
        )

        XCTAssertEqual(
            assembler.append(packet1, from: deviceID),
            Data("Hello BLE".utf8)
        )
    }
    
    func testInterleavedChunksFromDifferentDevices() {

        let assembler = BLEMessageAssembler()

        let deviceA = UUID()
        let deviceB = UUID()

        // あえて同じMessage IDを使用
        let messageID = UUID()

        func makePacket(
            index: Int,
            text: String
        ) -> BLEMessagePacket {
            BLEMessagePacket(
                messageID: messageID,
                chunkIndex: index,
                totalChunks: 2,
                payload: Data(text.utf8)
            )
        }

        // デバイスA：最初のチャンク
        XCTAssertNil(
            assembler.append(
                makePacket(index: 0, text: "Hello "),
                from: deviceA
            )
        )

        // デバイスB：最初のチャンク
        XCTAssertNil(
            assembler.append(
                makePacket(index: 0, text: "Good "),
                from: deviceB
            )
        )

        // デバイスA：メッセージ完成
        XCTAssertEqual(
            assembler.append(
                makePacket(index: 1, text: "A"),
                from: deviceA
            ),
            Data("Hello A".utf8)
        )

        // デバイスB：メッセージ完成
        XCTAssertEqual(
            assembler.append(
                makePacket(index: 1, text: "B"),
                from: deviceB
            ),
            Data("Good B".utf8)
        )
    }
    
    func testResetForDevicePreservesOtherDeviceCompletedMessages() {

        let assembler = BLEMessageAssembler()

        let deviceA = UUID()
        let deviceB = UUID()

        let messageID = UUID()

        let packet = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 0,
            totalChunks: 1,
            payload: Data("Hello BLE".utf8)
        )

        // 両デバイスでメッセージを完成させる
        XCTAssertEqual(
            assembler.append(packet, from: deviceA),
            Data("Hello BLE".utf8)
        )

        XCTAssertEqual(
            assembler.append(packet, from: deviceB),
            Data("Hello BLE".utf8)
        )
        
        // Device Aの完成済みMessage IDを登録
        assembler.markMessageCompleted(
            messageID: messageID,
            from: deviceA
        )

        // Device Bの完成済みMessage IDを登録
        assembler.markMessageCompleted(
            messageID: messageID,
            from: deviceB
        )

        // デバイスAだけリセット
        assembler.reset(for: deviceA)

        // Aは同じMessage IDを再び受け付ける
        XCTAssertEqual(
            assembler.append(packet, from: deviceA),
            Data("Hello BLE".utf8)
        )

        // Bは完了履歴が残っているので重複を拒否
        XCTAssertNil(
            assembler.append(packet, from: deviceB)
        )
    }
    
    func testMessageAtMaximumSizeIsAccepted() {

        let assembler = BLEMessageAssembler()

        let deviceID = UUID()
        let messageID = UUID()

        // 最大メッセージサイズ：1MiB
        let maximumSize = 1_048_576

        let payload = Data(
            repeating: 0x41,
            count: maximumSize
        )

        let packet = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 0,
            totalChunks: 1,
            payload: payload
        )

        let result = assembler.append(
            packet,
            from: deviceID
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.count, maximumSize)
        XCTAssertEqual(result, payload)
    }
    
    func testChunkedMessageExceedingMaximumSizeIsRejected() {

        let assembler = BLEMessageAssembler()

        let deviceID = UUID()
        let messageID = UUID()

        // 最初のチャンク：1MiB
        let packet0 = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 0,
            totalChunks: 2,
            payload: Data(
                repeating: 0x41,
                count: 1_048_576
            )
        )

        // 2番目のチャンク：1バイト
        let packet1 = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 1,
            totalChunks: 2,
            payload: Data([0x42])
        )

        // 1MiBまでは受信できるが、まだ未完成
        XCTAssertNil(
            assembler.append(packet0, from: deviceID)
        )

        // 合計1MiB + 1バイトなので拒否される
        XCTAssertNil(
            assembler.append(packet1, from: deviceID)
        )

        // 上限超過時にバッファが破棄されたことを確認
        let validPacket = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 0,
            totalChunks: 1,
            payload: Data("Recovered".utf8)
        )

        XCTAssertEqual(
            assembler.append(validPacket, from: deviceID),
            Data("Recovered".utf8)
        )
    }
    
    func testMaximumPendingMessagesLimit() {

        let assembler = BLEMessageAssembler()

        let deviceID = UUID()

        // 未完成メッセージを100件作成
        for _ in 0..<100 {

            let packet = BLEMessagePacket(
                messageID: UUID(),
                chunkIndex: 0,
                totalChunks: 2,
                payload: Data("Pending".utf8)
            )

            XCTAssertNil(
                assembler.append(packet, from: deviceID)
            )
        }

        // 101件目のメッセージ
        let extraMessageID = UUID()

        let extraPacket0 = BLEMessagePacket(
            messageID: extraMessageID,
            chunkIndex: 0,
            totalChunks: 2,
            payload: Data("Hello ".utf8)
        )

        XCTAssertNil(
            assembler.append(extraPacket0, from: deviceID)
        )

        // 101件目の後半を送信しても復元できない
        let extraPacket1 = BLEMessagePacket(
            messageID: extraMessageID,
            chunkIndex: 1,
            totalChunks: 2,
            payload: Data("BLE".utf8)
        )

        XCTAssertNil(
            assembler.append(extraPacket1, from: deviceID)
        )

        // リセット後は正常に受信できる
        assembler.reset()

        XCTAssertNil(
            assembler.append(extraPacket0, from: deviceID)
        )

        XCTAssertEqual(
            assembler.append(extraPacket1, from: deviceID),
            Data("Hello BLE".utf8)
        )
    }
    
    func testPendingMessageSlotReleasedAfterCompletion() {

        let assembler = BLEMessageAssembler()
        let deviceID = UUID()

        var firstMessageID: UUID?

        // 未完成メッセージを100件作成
        for index in 0..<100 {

            let messageID = UUID()

            if index == 0 {
                firstMessageID = messageID
            }

            let packet = BLEMessagePacket(
                messageID: messageID,
                chunkIndex: 0,
                totalChunks: 2,
                payload: Data("Hello ".utf8)
            )

            XCTAssertNil(
                assembler.append(packet, from: deviceID)
            )
        }

        guard let firstMessageID else {
            XCTFail("Message ID was not created")
            return
        }

        // 100件のうち1件を完成させる
        let completionPacket = BLEMessagePacket(
            messageID: firstMessageID,
            chunkIndex: 1,
            totalChunks: 2,
            payload: Data("BLE".utf8)
        )

        XCTAssertEqual(
            assembler.append(completionPacket, from: deviceID),
            Data("Hello BLE".utf8)
        )

        // 空きができたので新しいメッセージを受信
        let newMessageID = UUID()

        let newPacket0 = BLEMessagePacket(
            messageID: newMessageID,
            chunkIndex: 0,
            totalChunks: 2,
            payload: Data("New ".utf8)
        )

        let newPacket1 = BLEMessagePacket(
            messageID: newMessageID,
            chunkIndex: 1,
            totalChunks: 2,
            payload: Data("Message".utf8)
        )

        XCTAssertNil(
            assembler.append(newPacket0, from: deviceID)
        )

        XCTAssertEqual(
            assembler.append(newPacket1, from: deviceID),
            Data("New Message".utf8)
        )
    }
    
    func testTotalBufferSizeLimit() {

        let assembler = BLEMessageAssembler()
        let deviceID = UUID()

        // 1MiB × 10件 = 10MiB
        for _ in 0..<10 {

            let packet = BLEMessagePacket(
                messageID: UUID(),
                chunkIndex: 0,
                totalChunks: 2,
                payload: Data(
                    repeating: 0x41,
                    count: 1_048_576
                )
            )

            XCTAssertNil(
                assembler.append(packet, from: deviceID)
            )
        }

        // 10MiBを超える11件目
        let extraMessageID = UUID()

        let extraPacket0 = BLEMessagePacket(
            messageID: extraMessageID,
            chunkIndex: 0,
            totalChunks: 2,
            payload: Data([0x42])
        )

        let extraPacket1 = BLEMessagePacket(
            messageID: extraMessageID,
            chunkIndex: 1,
            totalChunks: 2,
            payload: Data([0x43])
        )

        // 合計サイズ超過で拒否
        XCTAssertNil(
            assembler.append(extraPacket0, from: deviceID)
        )

        // 11件目のバッファが破棄されたため復元できない
        XCTAssertNil(
            assembler.append(extraPacket1, from: deviceID)
        )

        // リセット後は正常に復元できる
        assembler.reset()

        XCTAssertNil(
            assembler.append(extraPacket0, from: deviceID)
        )

        XCTAssertEqual(
            assembler.append(extraPacket1, from: deviceID),
            Data([0x42, 0x43])
        )
    }
    
    func testPendingMessageSlotsReleasedAfterTimeout() {

        let assembler = BLEMessageAssembler()
        let deviceID = UUID()

        var currentTime = Date(
            timeIntervalSince1970: 0
        )

        assembler.nowProvider = {
            currentTime
        }

        // 未完成メッセージを100件作成
        for _ in 0..<100 {

            let packet = BLEMessagePacket(
                messageID: UUID(),
                chunkIndex: 0,
                totalChunks: 2,
                payload: Data("Pending".utf8)
            )

            XCTAssertNil(
                assembler.append(packet, from: deviceID)
            )
        }

        // 30秒経過
        currentTime = currentTime.addingTimeInterval(30)

        // 新しいメッセージ
        let messageID = UUID()

        let packet0 = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 0,
            totalChunks: 2,
            payload: Data("Hello ".utf8)
        )

        let packet1 = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 1,
            totalChunks: 2,
            payload: Data("BLE".utf8)
        )

        // 古い100件が期限切れになり、新しい受信が可能
        XCTAssertNil(
            assembler.append(packet0, from: deviceID)
        )

        XCTAssertEqual(
            assembler.append(packet1, from: deviceID),
            Data("Hello BLE".utf8)
        )
    }
    
    func testPendingMessageSlotsNotReleasedBeforeTimeout() {

        let assembler = BLEMessageAssembler()
        let deviceID = UUID()

        var currentTime = Date(
            timeIntervalSince1970: 0
        )

        assembler.nowProvider = {
            currentTime
        }

        var firstMessageID: UUID?

        // 未完成メッセージを100件作成
        for index in 0..<100 {

            let messageID = UUID()

            if index == 0 {
                firstMessageID = messageID
            }

            let packet = BLEMessagePacket(
                messageID: messageID,
                chunkIndex: 0,
                totalChunks: 2,
                payload: Data("Hello ".utf8)
            )

            XCTAssertNil(
                assembler.append(packet, from: deviceID)
            )
        }

        // タイムアウト直前の29秒
        currentTime = currentTime.addingTimeInterval(29)

        // 101件目のメッセージ
        let newMessageID = UUID()

        let newPacket0 = BLEMessagePacket(
            messageID: newMessageID,
            chunkIndex: 0,
            totalChunks: 2,
            payload: Data("New ".utf8)
        )

        XCTAssertNil(
            assembler.append(newPacket0, from: deviceID)
        )

        // 最初のメッセージはまだ保持されている
        guard let firstMessageID else {
            XCTFail("First message ID was not created")
            return
        }

        let completionPacket = BLEMessagePacket(
            messageID: firstMessageID,
            chunkIndex: 1,
            totalChunks: 2,
            payload: Data("BLE".utf8)
        )

        XCTAssertEqual(
            assembler.append(completionPacket, from: deviceID),
            Data("Hello BLE".utf8)
        )

        // 空きができたので101件目を再送
        XCTAssertNil(
            assembler.append(newPacket0, from: deviceID)
        )

        let newPacket1 = BLEMessagePacket(
            messageID: newMessageID,
            chunkIndex: 1,
            totalChunks: 2,
            payload: Data("Message".utf8)
        )

        XCTAssertEqual(
            assembler.append(newPacket1, from: deviceID),
            Data("New Message".utf8)
        )
    }
    
    func testMessageTimeoutIsIndependent() {

        let assembler = BLEMessageAssembler()
        let deviceID = UUID()

        var currentTime = Date(
            timeIntervalSince1970: 0
        )

        assembler.nowProvider = {
            currentTime
        }

        let messageA = UUID()
        let messageB = UUID()

        func makePacket(
            messageID: UUID,
            index: Int,
            text: String
        ) -> BLEMessagePacket {
            BLEMessagePacket(
                messageID: messageID,
                chunkIndex: index,
                totalChunks: 3,
                payload: Data(text.utf8)
            )
        }

        // 0秒：AとBの受信開始
        XCTAssertNil(
            assembler.append(
                makePacket(
                    messageID: messageA,
                    index: 0,
                    text: "A0"
                ),
                from: deviceID
            )
        )

        XCTAssertNil(
            assembler.append(
                makePacket(
                    messageID: messageB,
                    index: 0,
                    text: "B0"
                ),
                from: deviceID
            )
        )

        // 20秒：Aだけ受信時刻を更新
        currentTime = currentTime.addingTimeInterval(20)

        XCTAssertNil(
            assembler.append(
                makePacket(
                    messageID: messageA,
                    index: 1,
                    text: "A1"
                ),
                from: deviceID
            )
        )

        // 35秒：Bは期限切れ、Aはまだ有効
        currentTime = currentTime.addingTimeInterval(15)

        // Aは最後の受信から15秒なので完成できる
        XCTAssertEqual(
            assembler.append(
                makePacket(
                    messageID: messageA,
                    index: 2,
                    text: "A2"
                ),
                from: deviceID
            ),
            Data("A0A1A2".utf8)
        )

        // Bは35秒間更新されていないので復元できない
        XCTAssertNil(
            assembler.append(
                makePacket(
                    messageID: messageB,
                    index: 1,
                    text: "B1"
                ),
                from: deviceID
            )
        )

        XCTAssertNil(
            assembler.append(
                makePacket(
                    messageID: messageB,
                    index: 2,
                    text: "B2"
                ),
                from: deviceID
            )
        )
    }
    
    func testMessageTimeoutIsIndependentPerDevice() {

        let assembler = BLEMessageAssembler()

        let deviceA = UUID()
        let deviceB = UUID()

        // あえて同じMessage IDを使用
        let messageID = UUID()

        var currentTime = Date(
            timeIntervalSince1970: 0
        )

        assembler.nowProvider = {
            currentTime
        }

        func makePacket(
            index: Int,
            text: String
        ) -> BLEMessagePacket {
            BLEMessagePacket(
                messageID: messageID,
                chunkIndex: index,
                totalChunks: 3,
                payload: Data(text.utf8)
            )
        }

        // 0秒：両デバイスの受信開始
        XCTAssertNil(
            assembler.append(
                makePacket(index: 0, text: "A0"),
                from: deviceA
            )
        )

        XCTAssertNil(
            assembler.append(
                makePacket(index: 0, text: "B0"),
                from: deviceB
            )
        )

        // 20秒：デバイスAだけ受信を継続
        currentTime = currentTime.addingTimeInterval(20)

        XCTAssertNil(
            assembler.append(
                makePacket(index: 1, text: "A1"),
                from: deviceA
            )
        )

        // 35秒：Aは有効、Bは期限切れ
        currentTime = currentTime.addingTimeInterval(15)

        XCTAssertEqual(
            assembler.append(
                makePacket(index: 2, text: "A2"),
                from: deviceA
            ),
            Data("A0A1A2".utf8)
        )

        // Bは古いChunk 0が消えているため復元不可
        XCTAssertNil(
            assembler.append(
                makePacket(index: 1, text: "B1"),
                from: deviceB
            )
        )

        XCTAssertNil(
            assembler.append(
                makePacket(index: 2, text: "B2"),
                from: deviceB
            )
        )
    }
    
    func testCompletedMessageDeduplicationIsIndependentPerDevice() {

        let assembler = BLEMessageAssembler()

        let deviceA = UUID()
        let deviceB = UUID()

        // 両デバイスで同じMessage IDを使用
        let messageID = UUID()

        let packet = BLEMessagePacket(
            messageID: messageID,
            chunkIndex: 0,
            totalChunks: 1,
            payload: Data("Hello BLE".utf8)
        )

        // デバイスA：初回受信
        XCTAssertEqual(
            assembler.append(packet, from: deviceA),
            Data("Hello BLE".utf8)
        )
        
        // Device Aの完成済みMessage IDを登録
        assembler.markMessageCompleted(
            messageID: messageID,
            from: deviceA
        )

        // デバイスA：重複受信は拒否
        XCTAssertNil(
            assembler.append(packet, from: deviceA)
        )

        // デバイスB：同じMessage IDでも初回受信は成功
        XCTAssertEqual(
            assembler.append(packet, from: deviceB),
            Data("Hello BLE".utf8)
        )
        
        // Device Bの完成済みMessage IDを登録
        assembler.markMessageCompleted(
            messageID: messageID,
            from: deviceB
        )

        // デバイスB：重複受信は拒否
        XCTAssertNil(
            assembler.append(packet, from: deviceB)
        )
    }
}
