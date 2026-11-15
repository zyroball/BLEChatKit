//
//  BLEUUID.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/15.
//

import CoreBluetooth

public enum BLEUUID
{
    public static var service: CBUUID
    {
        CBUUID(
            string: "7F82A1D0-5B61-4A64-9B24-63D11B9E0001"
        )
    }

    public static var message: CBUUID {
        CBUUID(
            string: "7F82A1D0-5B61-4A64-9B24-63D11B9E0002"
        )
    }
}
