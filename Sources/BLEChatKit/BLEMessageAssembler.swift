//
//  BLEMessageAssembler.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/15.
//


import Foundation

public final class BLEMessageAssembler
{
    private struct MessageBuffer
    {
        let totalChunks: Int
        let createdAt: Date
        var chunks: [Int: Data] = [:]
    }
    
    // 1メッセージの最大サイズ：1MB
    private let maxMessageSize = 1_048_576

    // 全受信バッファの最大サイズ：10MB
    private let maxTotalBufferSize = 10_485_760
    
    private let maxPendingMessages = 100
    
    private let timeout: TimeInterval = 30
    
    internal var nowProvider: () -> Date = {
        Date()
    }

    private struct MessageKey: Hashable
    {
        let deviceID: UUID
        let messageID: UUID
    }

    private var buffers: [MessageKey: MessageBuffer] = [:]
    private let lock = NSLock()
    
    // テストから受信バッファの状態を確認する
    internal var bufferedByteCount: Int
    {
        lock.lock()
        defer { lock.unlock() }

        return currentBufferSize()
    }

    internal var pendingMessageCount: Int
    {
        lock.lock()
        defer { lock.unlock() }

        return buffers.count
    }

    public init() {}
    
    @discardableResult
    public func append(_ packet: BLEMessagePacket,
                       from deviceID: UUID) -> Data?
    {

        lock.lock()
        defer
        {
            lock.unlock()
        }

        removeExpiredMessagesLocked()

        guard packet.totalChunks > 0,
              packet.chunkIndex >= 0,
              packet.chunkIndex < packet.totalChunks
        else {
            return nil
        }

        let key = MessageKey(
            deviceID: deviceID,
            messageID: packet.messageID
        )

        if buffers[key] == nil
        {
            guard buffers.count < maxPendingMessages
            else
            {
                return nil
            }

            buffers[key] = MessageBuffer(
                totalChunks: packet.totalChunks,
                createdAt: nowProvider()
            )
        }

        guard var buffer = buffers[key],
              buffer.totalChunks == packet.totalChunks
        else {
            return nil
        }
        
        // 受信済みのチャンクは上書きしない
        if buffer.chunks[packet.chunkIndex] != nil
        {
            return nil
        }

        // 同じチャンクを再受信した場合のサイズも考慮
        let previousSize = buffer.chunks[packet.chunkIndex]?.count ?? 0

        let currentMessageSize = buffer.chunks.values.reduce(0) {
            $0 + $1.count
        }

        let newMessageSize =
            currentMessageSize + packet.payload.count

        let newTotalSize =
            currentBufferSize() + packet.payload.count

        // 1メッセージの上限を確認
        guard newMessageSize <= maxMessageSize
        else
        {
            buffers.removeValue(forKey: key)
            return nil
        }

        guard newTotalSize <= maxTotalBufferSize
        else
        {
            buffers.removeValue(forKey: key)
            return nil
        }

        // サイズに問題がなければ保存
        buffer.chunks[packet.chunkIndex] = packet.payload
        buffers[key] = buffer

        guard buffer.chunks.count == buffer.totalChunks
        else
        {
            return nil
        }

        var result = Data()

        for index in 0..<buffer.totalChunks
        {
            guard let chunk = buffer.chunks[index]
            else
            {
                return nil
            }

            result.append(chunk)
        }

        buffers.removeValue(forKey: key)

        return result
    }

    public func removeExpiredMessages()
    {
        lock.lock()
        defer { lock.unlock() }

        removeExpiredMessagesLocked()
    }

    private func removeExpiredMessagesLocked() {

        let now = nowProvider()

        buffers = buffers.filter { _, buffer in
            now.timeIntervalSince(buffer.createdAt) < timeout
        }
    }
    
    public func reset()
    {
        lock.lock()
        defer
        {
            lock.unlock()
        }
        buffers.removeAll()
    }
    
    
    public func reset(for deviceID: UUID)
    {
        lock.lock()
        defer
        {
            lock.unlock()
        }
        buffers = buffers.filter { key, _ in
            key.deviceID != deviceID
        }
    }
    
    private func currentBufferSize() -> Int
    {
        buffers.values.reduce(0)
        {
            total, buffer in
            total + buffer.chunks.values.reduce(0)
            {
                $0 + $1.count
            }
        }
    }

}
