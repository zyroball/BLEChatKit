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
    func testPackageInitialization()
    {
        let central = BLECentral()
        XCTAssertNotNil(central)
    }
}
