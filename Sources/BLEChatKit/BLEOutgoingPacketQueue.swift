//
//  BLEOutgoingPacketQueue.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/17.
//

import Foundation

final class BLEOutgoingPacketQueue {

    struct OutgoingPacket {
        let messageID: UUID
        let data: Data
        let isLastChunk: Bool
    }

    private var queues: [UUID: [OutgoingPacket]] = [:]
    // 送信待ちパケットが存在する全デバイスID
    var allDeviceIDs: [UUID] {
        Array(queues.keys)
    }
    
    // MARK: - パケット追加

    func enqueue(
        _ packets: [OutgoingPacket],
        for deviceID: UUID
    ) {
        queues[deviceID, default: []].append(
            contentsOf: packets
        )
    }
    
    // MARK: - 先頭パケット取得

    func peek(for deviceID: UUID) -> OutgoingPacket? {

        return queues[deviceID]?.first
    }
    
    // MARK: - 先頭パケット削除

    @discardableResult
    func dequeue(for deviceID: UUID) -> OutgoingPacket? {

        guard var queue = queues[deviceID],
              !queue.isEmpty
        else {
            return nil
        }

        let packet = queue.removeFirst()

        if queue.isEmpty {
            queues.removeValue(forKey: deviceID)
        } else {
            queues[deviceID] = queue
        }

        return packet
    }
    
    // MARK: - デバイス別キュー削除

    func clear(for deviceID: UUID) {

        queues.removeValue(forKey: deviceID)
    }
    
    // MARK: - パケット数取得

    func count(for deviceID: UUID) -> Int {

        return queues[deviceID]?.count ?? 0
    }
    
    // MARK: - 送信待ちメッセージID取得

    func messageIDs(for deviceID: UUID) -> [UUID] {

        let packets = queues[deviceID] ?? []

        var messageIDs: [UUID] = []
        var seenIDs: Set<UUID> = []

        for packet in packets {
            if seenIDs.insert(packet.messageID).inserted {
                messageIDs.append(packet.messageID)
            }
        }

        return messageIDs
    }
    
    // MARK: - メッセージの送信待ち確認
    func contains(
        messageID: UUID,
        for deviceID: UUID
    ) -> Bool {

        return queues[deviceID]?.contains {
            $0.messageID == messageID
        } ?? false
    }
    
    // MARK: - メッセージ単位のキュー削除

    func removePackets(
        messageID: UUID,
        for deviceID: UUID,
        preservingFirstPacket: Bool = false
    ) {
        guard let queue = queues[deviceID] else {
            return
        }

        let preservedPacket =
            preservingFirstPacket ? queue.first : nil

        var remainingPackets = queue.filter {
            $0.messageID != messageID
        }

        if let preservedPacket {
            remainingPackets.insert(preservedPacket, at: 0)
        }

        if remainingPackets.isEmpty {
            queues.removeValue(forKey: deviceID)
        } else {
            queues[deviceID] = remainingPackets
        }
    }
}
