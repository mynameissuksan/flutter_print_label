/// A Bluetooth printer (or any Bluetooth device) found during a scan.
class PrinterDevice {
  /// Human readable device name.
  ///
  /// Many budget Chinese label printers advertise over BLE without a name.
  /// For those devices the plugin generates a fallback name such as
  /// `Unknown (1A2B)` (iOS: from the peripheral UUID, Android: from the MAC
  /// address) so they can still be listed and selected.
  final String name;

  /// Platform specific device identifier.
  ///
  /// On Android this is the MAC address; on iOS it is the CoreBluetooth
  /// peripheral UUID (stable per device, per phone).
  final String address;

  /// Whether this device was found via a BLE scan (`true`) or taken from the
  /// Bluetooth Classic paired-devices list (`false`, Android only).
  final bool isBle;

  /// Creates a device description.
  const PrinterDevice({
    required this.name,
    required this.address,
    this.isBle = false,
  });

  @override
  String toString() => 'PrinterDevice($name, $address, isBle: $isBle)';
}

/// Connection state reported by [FlutterPrintLabel.connectionStatus].
enum PrinterConnectionStatus {
  /// Not connected to any printer.
  disconnected,

  /// Connection attempt in progress.
  connecting,

  /// Connected and ready to receive print data.
  connected,
}
