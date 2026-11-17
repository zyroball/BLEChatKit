//
//  BLEOutgoingPacketQueueTests.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/17.
//

import XCTest
@testable import BLEChatKit

final class BLEOutgoingPacketQueueTests: XCTestCase {

    func testEnqueuePackets() {

        let queue = BLEOutgoingPacketQueue()
        let deviceID = UUID()
        let messageID = UUID()

        let packets = [
            BLEOutgoingPacketQueue.OutgoingPacket(
                messageID: messageID,
                data: Data([0x01]),
                isLastChunk: false
            ),
            BLEOutgoingPacketQueue.OutgoingPacket(
                messageID: messageID,
                data: Data([0x02]),
                isLastChunk: true
            )
        ]

        queue.enqueue(packets, for: deviceID)

        XCTAssertEqual(queue.count(for: deviceID), 2)
    }
    
    func testPeekDoesNotRemovePacket() {

        let queue = BLEOutgoingPacketQueue()
        let deviceID = UUID()
        let messageID = UUID()

        let packet = BLEOutgoingPacketQueue.OutgoingPacket(
            messageID: messageID,
            data: Data([0x01]),
            isLastChunk: true
        )

        queue.enqueue([packet], for: deviceID)

        let firstPacket = queue.peek(for: deviceID)

        XCTAssertEqual(firstPacket?.messageID, messageID)
        XCTAssertEqual(firstPacket?.data, Data([0x01]))
        XCTAssertEqual(queue.count(for: deviceID), 1)
    }
    
    func testDequeueRemovesFirstPacket() {

        let queue = BLEOutgoingPacketQueue()
        let deviceID = UUID()
        let messageID = UUID()

        let firstPacket = BLEOutgoingPacketQueue.OutgoingPacket(
            messageID: messageID,
            data: Data([0x01]),
            isLastChunk: false
        )

        let secondPacket = BLEOutgoingPacketQueue.OutgoingPacket(
            messageID: messageID,
            data: Data([0x02]),
            isLastChunk: true
        )

        queue.enqueue(
            [firstPacket, secondPacket],
            for: deviceID
        )

        let removedPacket = queue.dequeue(for: deviceID)

        XCTAssertEqual(removedPacket?.data, Data([0x01]))
        XCTAssertEqual(queue.count(for: deviceID), 1)

        let remainingPacket = queue.peek(for: deviceID)

        XCTAssertEqual(remainingPacket?.data, Data([0x02]))
    }
    
    func testClearOnlyRemovesTargetDevicePackets() {

        let queue = BLEOutgoingPacketQueue()

        let deviceA = UUID()
        let deviceB = UUID()

        let packet = BLEOutgoingPacketQueue.OutgoingPacket(
            messageID: UUID(),
            data: Data([0x01]),
            isLastChunk: true
        )

        queue.enqueue([packet], for: deviceA)
        queue.enqueue([packet], for: deviceB)

        XCTAssertEqual(queue.count(for: deviceA), 1)
        XCTAssertEqual(queue.count(for: deviceB), 1)

        queue.clear(for: deviceA)

        XCTAssertEqual(queue.count(for: deviceA), 0)
        XCTAssertNil(queue.peek(for: deviceA))

        XCTAssertEqual(queue.count(for: deviceB), 1)
        XCTAssertNotNil(queue.peek(for: deviceB))
    }
    
    func testEmptyQueueReturnsNil() {

        let queue = BLEOutgoingPacketQueue()
        let deviceID = UUID()

        XCTAssertNil(queue.peek(for: deviceID))
        XCTAssertNil(queue.dequeue(for: deviceID))

        XCTAssertEqual(queue.count(for: deviceID), 0)
    }
}
