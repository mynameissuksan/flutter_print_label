## 0.1.1

- Add screenshots to the pub.dev gallery (sample printed label and printer photo).
- Example app now prints a complete shipping-label layout (barcode, divider
  lines, label specs, footer and QR code) matching the sample image.
- README: add label/printer images and extend the TSPL quick reference
  (`QRCODE`, `BAR`).

## 0.1.0

Initial release.

- Scan for Bluetooth label printers on Android (Classic paired list + real BLE
  scan) and iOS (BLE).
- Unnamed BLE printers are reported with a generated fallback name instead of
  being skipped.
- Connect / disconnect with reliable state reporting; `connected` is emitted
  only when the printer is ready to receive data.
- Send raw bytes or TSPL command strings; iOS writes are chunked to the MTU
  with pacing to avoid printer buffer overflows.
- iOS: pure CoreBluetooth implementation (no vendor SDK), automatic write
  characteristic discovery preferring well-known printer services.
- iOS: Bluetooth radio state stream, system enable-Bluetooth alert helper,
  and `getConnectedDevice()` to restore a live connection after hot restart.
- Android: automatic runtime permission requests and system enable-Bluetooth
  dialog.
