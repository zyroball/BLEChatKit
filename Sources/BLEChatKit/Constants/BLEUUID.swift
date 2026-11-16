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
            string: "0000"
        )
    }

    public static var message: CBUUID {
        CBUUID(
            string: "0001"
        )
    }
}
