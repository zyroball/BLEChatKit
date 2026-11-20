//
//  BLEMessageAssembler.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/15.
//


import Foundation

public final class BLEMessageAssembler
{
    private struct MessageBuffer {

        let totalChunks: Int

        let createdAt: Date

        var lastReceivedAt: Date

        var chunks: [Int: Data] = [:]
    }
    // 1メッセージの最大サイズ：1MB
    private let maxMessageSize = 1_048_576

    // 全受信バッファの最大サイズ：10MB
    private let maxTotalBufferSize = 10_485_760
    
    private let maxPendingMessages = 100
    private let maxChunksPerMessage = 10_000
    private let maxCompletedMessages = 1_000
    private let completedMessageRetention: TimeInterval = 300
    
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
    private var completedMessages: [MessageKey: Date] = [:]
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
              packet.totalChunks <= maxChunksPerMessage,
              packet.chunkIndex >= 0,
              packet.chunkIndex < packet.totalChunks
        else {
            return nil
        }

        let key = MessageKey(
            deviceID: deviceID,
            messageID: packet.messageID
        )
        
        
        if completedMessages[key] != nil {
            return nil
        }

        if buffers[key] == nil
        {
            guard buffers.count < maxPendingMessages
            else
            {
                return nil
            }

            buffers[key] = MessageBuffer(
                totalChunks: packet.totalChunks,
                createdAt: nowProvider(),
                lastReceivedAt: nowProvider()
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
        buffer.lastReceivedAt = nowProvider()
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
    
    public func isMessageCompleted(
        messageID: UUID,
        from deviceID: UUID
    ) -> Bool {
        lock.lock()
        defer {
            lock.unlock()
        }

        removeExpiredMessagesLocked()

        let key = MessageKey(
            deviceID: deviceID,
            messageID: messageID
        )

        return completedMessages[key] != nil
    }

    public func removeExpiredMessages()
    {
        lock.lock()
        defer { lock.unlock() }

        removeExpiredMessagesLocked()
    }

    
    private func removeExpiredMessagesLocked() {
        let now = nowProvider()

        // 未完成メッセージの期限切れ処理
        buffers = buffers.filter { _, buffer in
            now.timeIntervalSince(buffer.lastReceivedAt) < timeout
        }

        // 完成済みメッセージの期限切れ処理
        completedMessages = completedMessages.filter { _, date in
            now.timeIntervalSince(date) < completedMessageRetention
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
        completedMessages.removeAll()
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
        completedMessages = completedMessages.filter
        {
            key, _ in
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

    public func markMessageCompleted(
        messageID: UUID,
        from deviceID: UUID
    ) {
        lock.lock()
        defer {
            lock.unlock()
        }

        removeExpiredMessagesLocked()

        let key = MessageKey(
            deviceID: deviceID,
            messageID: messageID
        )

        completedMessages[key] = nowProvider()

        if completedMessages.count > maxCompletedMessages {
            if let oldestKey = completedMessages.min(
                by: { $0.value < $1.value }
            )?.key {
                completedMessages.removeValue(forKey: oldestKey)
            }
        }
    }
    
    public func resetPendingMessages(for deviceID: UUID) {
        lock.lock()
        defer {
            lock.unlock()
        }

        // 未完成の受信バッファだけ削除
        buffers = buffers.filter { key, _ in
            key.deviceID != deviceID
        }

        // 完成済みMessage IDは保持する
        // completedMessagesは変更しない
    }
    
    public func resetAllPendingMessages() {
        lock.lock()
        defer {
            lock.unlock()
        }

        // 未完成メッセージだけを破棄
        buffers.removeAll()

        // 完成済みMessage IDは保持
    }
}
