# BLEChatKit

BLEChatKit is a Swift Package for building Bluetooth Low Energy (BLE) communication features on iOS and macOS using Apple's CoreBluetooth framework.

## Features

- BLE Central and Peripheral communication
- Message chunking and reassembly
- Packet encoding and decoding
- Message size and buffer limits
- Connection state management
- Message send completion callbacks

## Requirements

- iOS 15.0+
- macOS 12.0+
- Swift 6.0 toolchain or later

## Installation

Add BLEChatKit to your project using Swift Package Manager.

Repository:

`https://github.com/zyroball/BLEChatKit`

Then import the package:

```swift
import BLEChatKit
```

## Testing

BLEChatKit includes unit tests covering packet encoding, message assembly, invalid packets, timeouts, and buffer limits.

## Status

BLEChatKit is under active development. Public APIs and compatibility may change before the first stable release.

## License

License terms have not yet been finalized.
