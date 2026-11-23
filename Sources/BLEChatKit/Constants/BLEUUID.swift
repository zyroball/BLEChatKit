//
//  BLEUUID.swift
//  BLEChatKit
//
//  Created by Yuhei on 2026/11/15.
//

import CoreBluetooth

public enum BLEUUID
{
//    public static var service: CBUUID
//    {
//        CBUUID(
//            string: "0000"
//        )
//    }
//
//    public static var message: CBUUID {
//        CBUUID(
//            string: "0001"
//        )
//    }
    public static var service: CBUUID {
        CBUUID(
            string: "B7781459-FEC9-4C0F-8245-A9A07EF05A30"
        )
    }

    public static var message: CBUUID {
        CBUUID(
            string: "ABF9F206-3ED2-4B96-98E3-A22E9F823535"
        )
    }
}
