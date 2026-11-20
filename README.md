# BLEChatKit

BLEChatKit is a Swift Package for building Bluetooth Low Energy (BLE) communication features on iOS and macOS using Apple's CoreBluetooth framework.

## Features

- BLE Central and Peripheral communication
- Message chunking and reassembly
- Packet encoding and decoding
- Message size and buffer limits
- Connection state management
- Message send completion callbacks

## Message Delivery Semantics

BLEChatKit currently uses different send completion
semantics depending on the communication direction:

- **Central → Peripheral:** Send completion is reported
  after an acknowledgment (ACK) is received from the
  Peripheral.
- **Peripheral → Central:** Send completion is reported
  when all message packets have been enqueued for
  notification delivery. This does not guarantee that
  the Central has received or processed the message.

Applications requiring confirmed delivery in both
directions should implement additional application-level
acknowledgment handling.

## Requirements

- iOS 14.0+
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

BLEChatKit is released under the MIT License.
See [LICENSE](LICENSE) for details.
