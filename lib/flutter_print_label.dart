import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'src/printer_device.dart';

export 'src/printer_device.dart';

/// Bluetooth label printer plugin for Android and iOS.
///
/// Designed for TSPL label printers, including budget Chinese printers
/// (VOZY, Xprinter, Gprinter clones, ...) that advertise over BLE without a
/// device name and use non-standard write characteristics.
///
/// Typical flow:
///
/// ```dart
/// final printer = FlutterPrintLabel.instance;
///
/// // 1. Scan (iOS always scans BLE; on Android `isBle: false` returns the
/// //    paired-devices list and `isBle: true` performs a real BLE scan).
/// printer.scan(isBle: Platform.isIOS).listen((device) => print(device));
///
/// // 2. Connect and wait for `connected` on [connectionStatus].
/// await printer.connect(device);
///
/// // 3. Print a TSPL label.
/// await printer.printTspl(
///   'SIZE 100 mm,150 mm\r\nCLS\r\nTEXT 50,50,"3",0,1,1,"Hello"\r\nPRINT 1,1\r\n',
/// );
/// ```
class FlutterPrintLabel {
  FlutterPrintLabel._() {
    _init();
  }

  /// The shared plugin instance.
  static final FlutterPrintLabel instance = FlutterPrintLabel._();

  // Same channel names on both platforms — the package name is unique on
  // pub.dev, so it can be used directly as the namespace.
  static const MethodChannel _channel = MethodChannel('flutter_print_label');
  static const EventChannel _stateChannel =
      EventChannel('flutter_print_label/state');

  final StreamController<PrinterDevice> _scanResultsController =
      StreamController<PrinterDevice>.broadcast();
  final StreamController<PrinterConnectionStatus> _statusController =
      StreamController<PrinterConnectionStatus>.broadcast();
  final StreamController<bool> _bluetoothOnController =
      StreamController<bool>.broadcast();

  PrinterConnectionStatus _status = PrinterConnectionStatus.disconnected;
  bool _lastScanIsBle = false;
  PrinterDevice? _connectedDevice;

  /// Whether the Bluetooth radio is currently usable.
  ///
  /// `null` until the first [BluetoothState] event arrives (iOS reports this
  /// after the first [scan] call; Android handles radio state natively by
  /// showing the system "enable Bluetooth" dialog instead).
  bool? isBluetoothOn;

  /// Why Bluetooth is unusable when [isBluetoothOn] is `false`:
  /// `'poweredOff'`, `'unauthorized'` or `'unsupported'` (iOS only).
  String? bluetoothOffReason;

  void _init() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'ScanResult':
          final args = call.arguments;
          final name = args['name'] as String? ?? '';
          final address = args['address'] as String?;
          if (address == null) return;
          _scanResultsController.add(PrinterDevice(
            name: name,
            address: address,
            isBle: Platform.isIOS || _lastScanIsBle,
          ));
        case 'BluetoothState':
          // iOS only: adapter state changes (on/off/unauthorized).
          final on = call.arguments['on'] == true;
          isBluetoothOn = on;
          bluetoothOffReason =
              on ? null : call.arguments['reason'] as String?;
          _bluetoothOnController.add(on);
      }
    });

    _stateChannel.receiveBroadcastStream().listen((data) {
      if (data is! int) return;
      final status = switch (data) {
        2 => PrinterConnectionStatus.connected,
        1 => PrinterConnectionStatus.connecting,
        _ => PrinterConnectionStatus.disconnected,
      };
      _status = status;
      if (status == PrinterConnectionStatus.disconnected) {
        _connectedDevice = null;
      }
      _statusController.add(status);
    });
  }

  /// The latest known connection status.
  PrinterConnectionStatus get status => _status;

  /// The device passed to the most recent [connect] call, while the
  /// connection is being established or is alive. `null` after
  /// [disconnect] or when the connection drops.
  ///
  /// Note that a connected BLE device stops advertising, so it will never
  /// show up in live scan results — use this to keep it visible in your UI.
  PrinterDevice? get connectedDevice => _connectedDevice;

  /// Emits every connection status change.
  Stream<PrinterConnectionStatus> get connectionStatus =>
      _statusController.stream;

  /// iOS only: emits `true`/`false` when the Bluetooth radio is turned
  /// on/off, or when the app's Bluetooth permission changes.
  Stream<bool> get bluetoothOnStream => _bluetoothOnController.stream;

  /// Scans for printers and emits each device as it is found.
  ///
  /// * iOS: always a BLE scan. A connected printer stops advertising, so it
  ///   will not appear in scan results while connected.
  /// * Android with `isBle: false`: returns the Bluetooth Classic
  ///   paired-devices list (pair the printer in system settings first).
  /// * Android with `isBle: true`: performs a real BLE scan, so unpaired
  ///   printers can be found too.
  ///
  /// Unnamed devices are emitted with a generated name such as
  /// `Unknown (1A2B)`. The same address may be emitted a second time if the
  /// device's real name arrives later during the scan.
  ///
  /// A connected BLE device stops advertising and therefore never appears in
  /// live scan results. To keep it selectable, the currently connected
  /// device ([connectedDevice]) is injected as the **first** item of the
  /// stream and deduplicated against live results.
  ///
  /// The stream closes after [timeout].
  Stream<PrinterDevice> scan({
    bool isBle = false,
    Duration timeout = const Duration(seconds: 10),
  }) {
    _lastScanIsBle = isBle;
    final controller = StreamController<PrinterDevice>();
    final emittedNames = <String, String>{};

    // A connected printer will not be discovered (it stops advertising) —
    // emit it first so it never disappears from the caller's device list.
    final connected = _connectedDevice;
    if (connected != null && _status == PrinterConnectionStatus.connected) {
      emittedNames[connected.address] = connected.name;
      controller.add(connected);
    }

    final sub = _scanResultsController.stream.listen((device) {
      // Deduplicate by address, but let a name update through.
      if (emittedNames[device.address] == device.name) return;
      emittedNames[device.address] = device.name;
      controller.add(device);
    });

    Future<void>(() async {
      try {
        if (Platform.isAndroid) {
          await _channel
              .invokeMethod(isBle ? 'getBluetoothLeList' : 'getBluetoothList');
        } else if (Platform.isIOS) {
          await _channel.invokeMethod('startScan');
        }
      } catch (e, st) {
        if (!controller.isClosed) controller.addError(e, st);
      }
    });

    Timer(timeout, () async {
      await sub.cancel();
      if (Platform.isIOS) {
        try {
          await _channel.invokeMethod('stopScan');
        } catch (_) {}
      }
      if (!controller.isClosed) await controller.close();
    });

    controller.onCancel = sub.cancel;
    return controller.stream;
  }

  /// Connects to [device].
  ///
  /// The device must come from a recent [scan] (on iOS the underlying
  /// peripheral object must have been discovered in the current session).
  /// Completes when the request is dispatched; listen to [connectionStatus]
  /// and wait for [PrinterConnectionStatus.connected], which on iOS is only
  /// reported once a writable characteristic has been found — i.e. when the
  /// printer is actually ready to receive data.
  ///
  /// [autoConnect] (Android Classic only) automatically reconnects when the
  /// connection drops.
  Future<void> connect(PrinterDevice device, {bool autoConnect = false}) async {
    _connectedDevice = device;
    if (Platform.isAndroid) {
      await _channel.invokeMethod('onStartConnection', {
        'address': device.address,
        'isBle': device.isBle,
        'autoConnect': autoConnect,
      });
    } else if (Platform.isIOS) {
      await _channel.invokeMethod('connect', {
        'name': device.name,
        'address': device.address,
      });
    }
  }

  /// Disconnects from the current printer.
  ///
  /// After disconnecting, the printer resumes advertising within a few
  /// seconds and can be found by a new [scan].
  Future<void> disconnect() {
    _connectedDevice = null;
    return _channel.invokeMethod('disconnect');
  }

  /// Sends raw bytes to the connected printer.
  ///
  /// On iOS the bytes are written in MTU-sized chunks with a short delay
  /// between chunks, so large payloads (e.g. bitmap labels) do not overflow
  /// the printer's BLE buffer.
  Future<void> sendBytes(List<int> bytes) async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod('sendDataByte', {'bytes': bytes});
    } else if (Platform.isIOS) {
      await _channel
          .invokeMethod('writeData', {'bytes': bytes, 'length': bytes.length});
    }
  }

  /// Sends a TSPL command string to the connected printer.
  ///
  /// ```dart
  /// await FlutterPrintLabel.instance.printTspl(
  ///   'SIZE 100 mm,150 mm\r\n'
  ///   'GAP 3 mm,0 mm\r\n'
  ///   'CLS\r\n'
  ///   'TEXT 50,50,"3",0,1,1,"Hello label"\r\n'
  ///   'BARCODE 50,150,"128",100,1,0,2,2,"123456"\r\n'
  ///   'PRINT 1,1\r\n',
  /// );
  /// ```
  Future<void> printTspl(String tsplCommands) =>
      sendBytes(tsplCommands.codeUnits);

  /// Whether a printer is currently connected.
  Future<bool> isConnected() async {
    if (Platform.isIOS) {
      return await _channel.invokeMethod('isConnected') == true;
    }
    return _status == PrinterConnectionStatus.connected;
  }

  /// iOS only: asks which printer the native side is still connected to.
  ///
  /// Useful after a hot restart: Dart state is gone but the native
  /// connection may still be alive — and a connected printer stops
  /// advertising, so it cannot be rediscovered by scanning. Returns
  /// `{'address': ..., 'name': ...}` or `null` when not connected.
  Future<Map<String, String>?> getConnectedDevice() async {
    if (!Platform.isIOS) return null;
    try {
      final result = await _channel.invokeMethod('connectedDevice');
      if (result == null) return null;
      return {
        'address': result['address'] as String,
        'name': result['name'] as String,
      };
    } catch (_) {
      return null;
    }
  }

  /// iOS only: shows the system "Turn On Bluetooth..." alert, whose Settings
  /// button jumps directly to the Bluetooth settings page. Only appears while
  /// Bluetooth is off. (Apps cannot enable Bluetooth programmatically on
  /// iOS, and deep-linking to the Bluetooth settings page is a private API.)
  Future<void> showEnableBluetoothAlert() async {
    if (Platform.isIOS) {
      await _channel.invokeMethod('showBluetoothAlert');
    }
  }
}
