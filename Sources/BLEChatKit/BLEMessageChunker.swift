//
//  BLEMessageChunker.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/15.
//


import Foundation

public enum BLEMessageChunker
{
    public static func split(_ data: Data,
                             chunkSize: Int) -> [Data]
    {
        guard chunkSize > 0 else
        {
            return []
        }

        return stride(from: 0,
                      to: data.count,
                      by: chunkSize).map {
            offset in

            let end = min(offset + chunkSize,data.count)

            return data.subdata(in: offset..<end)
        }
    }

    public static func combine(_ chunks: [Data]) -> Data
    {
        var result = Data()

        for chunk in chunks
        {
            result.append(chunk)
        }

        return result
    }
}
