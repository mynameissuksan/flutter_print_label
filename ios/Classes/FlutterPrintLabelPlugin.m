#import "FlutterPrintLabelPlugin.h"

// Pure CoreBluetooth implementation.
//
// Many budget Chinese label printers (VOZY, Xprinter, Gprinter clones, ...)
// advertise over BLE without a device name and expose non-standard write
// services, so this plugin:
//   1. never filters out unnamed peripherals during a scan (a fallback name
//      is generated instead),
//   2. discovers every service/characteristic after connecting and picks the
//      first writable characteristic, preferring well-known printer services,
//   3. writes data in MTU-sized chunks with a small delay between chunks so
//      the printer's tiny BLE buffer does not overflow.
//
// A single CBCentralManager instance is used for the whole app lifetime
// (scan + connect + write). It is never destroyed, which keeps repeated
// connect/disconnect cycles stable.

@interface FlutterPrintLabelPlugin ()
@property(nonatomic, retain) NSObject<FlutterPluginRegistrar> *registrar;
@property(nonatomic, retain) FlutterMethodChannel *channel;
@property(nonatomic, retain) BluetoothPrintStreamHandler *stateStreamHandler;
@property(nonatomic) NSMutableDictionary<NSString *, CBPeripheral *> *scannedPeripherals;
@property(nonatomic) NSMutableDictionary<NSString *, NSString *> *sentDeviceNames;
@property(nonatomic, strong) CBCentralManager *powerAlertManager;
@property(nonatomic, strong) CBCentralManager *central;
@property(nonatomic, strong) CBPeripheral *connectedPeripheral;
@property(nonatomic, strong) CBCharacteristic *writeCharacteristic;
@property(nonatomic, assign) BOOL pendingScan;
@property(nonatomic, assign) BOOL reportedConnected;
// งานเขียนที่กำลังทยอยส่งอยู่ (ใช้ flow control ของ CoreBluetooth แทนการหน่วงตายตัว)
@property(nonatomic, strong) NSData *pendingWriteData;
@property(nonatomic, assign) NSUInteger pendingWriteOffset;
@property(nonatomic, assign) NSUInteger pendingWriteMtu;
@property(nonatomic, assign) CBCharacteristicWriteType pendingWriteType;
@property(nonatomic, copy) FlutterResult pendingWriteResult;
@end

@implementation FlutterPrintLabelPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterMethodChannel *channel = [FlutterMethodChannel
      methodChannelWithName:NAMESPACE @"/methods"
            binaryMessenger:[registrar messenger]];
  FlutterEventChannel *stateChannel =
      [FlutterEventChannel eventChannelWithName:NAMESPACE @"/state"
                                binaryMessenger:[registrar messenger]];
  FlutterPrintLabelPlugin *instance = [[FlutterPrintLabelPlugin alloc] init];

  instance.channel = channel;
  instance.scannedPeripherals = [NSMutableDictionary new];
  instance.sentDeviceNames = [NSMutableDictionary new];

  BluetoothPrintStreamHandler *stateStreamHandler = [[BluetoothPrintStreamHandler alloc] init];
  [stateChannel setStreamHandler:stateStreamHandler];
  instance.stateStreamHandler = stateStreamHandler;

  [registrar addMethodCallDelegate:instance channel:channel];
}

// Single central manager reused for the whole app lifetime (scan/connect/write).
// Never destroyed — repeatedly recreating central managers is a common source
// of crashes and stale-connection bugs.
- (CBCentralManager *)ensureCentral {
    if (self.central == nil) {
        self.central = [[CBCentralManager alloc]
            initWithDelegate:self
                       queue:nil
                     options:@{CBCentralManagerOptionShowPowerAlertKey: @NO}];
    }
    return self.central;
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  if ([@"state" isEqualToString:call.method]) {
    result(nil);
  } else if ([@"isAvailable" isEqualToString:call.method]) {
    result(@(YES));
  } else if ([@"isConnected" isEqualToString:call.method]) {
    result(@(self.connectedPeripheral != nil &&
             self.connectedPeripheral.state == CBPeripheralStateConnected));
  } else if ([@"isOn" isEqualToString:call.method]) {
    result(@(self.central != nil && self.central.state == CBManagerStatePoweredOn));
  } else if ([@"connectedDevice" isEqualToString:call.method]) {
    // Lets the Dart side ask which printer is currently connected. Useful
    // after a hot restart: Dart state is gone but the native connection may
    // still be alive (and a connected printer stops advertising, so it can
    // not be rediscovered by scanning).
    if (self.connectedPeripheral != nil &&
        self.connectedPeripheral.state == CBPeripheralStateConnected &&
        self.writeCharacteristic != nil) {
        NSString *uuidString = [[self.connectedPeripheral identifier] UUIDString];
        NSString *name = self.connectedPeripheral.name;
        if (name == nil || name.length == 0) {
            name = [self.sentDeviceNames objectForKey:uuidString];
        }
        if (name == nil || name.length == 0) {
            NSString *shortId = uuidString.length >= 4 ? [uuidString substringToIndex:4] : uuidString;
            name = [NSString stringWithFormat:@"Printer (%@)", shortId];
        }
        result(@{@"address": uuidString, @"name": name});
    } else {
        result(nil);
    }
  } else if ([@"startScan" isEqualToString:call.method]) {
      [self.sentDeviceNames removeAllObjects];
      // Keep the connected peripheral in the lookup table, drop the rest.
      NSString *connectedKey = self.connectedPeripheral == nil
          ? nil : [[self.connectedPeripheral identifier] UUIDString];
      NSArray *keys = [self.scannedPeripherals allKeys];
      for (NSString *key in keys) {
          if (connectedKey == nil || ![key isEqualToString:connectedKey]) {
              [self.scannedPeripherals removeObjectForKey:key];
          }
      }

      CBCentralManager *central = [self ensureCentral];
      if (central.state == CBManagerStatePoweredOn) {
          [self startScan];
      } else {
          // Not ready yet (just created / Bluetooth off) — scan on poweredOn.
          self.pendingScan = YES;
      }
      result(nil);
  } else if ([@"stopScan" isEqualToString:call.method]) {
    self.pendingScan = NO;
    if (self.central != nil) [self.central stopScan];
    result(nil);
  } else if ([@"showBluetoothAlert" isEqualToString:call.method]) {
    // Apps cannot enable Bluetooth themselves, and deep-linking into the
    // Bluetooth settings page is a private API. Creating a fresh
    // CBCentralManager with ShowPowerAlert=YES makes the system present its
    // own "Turn On Bluetooth..." alert, which has a Settings button that
    // jumps straight to the Bluetooth settings page.
    self.powerAlertManager = [[CBCentralManager alloc]
        initWithDelegate:self
                   queue:nil
                 options:@{CBCentralManagerOptionShowPowerAlertKey: @YES}];
    result(nil);
  } else if ([@"connect" isEqualToString:call.method]) {
    NSDictionary *device = [call arguments];
    NSString *address = [device objectForKey:@"address"];
    CBPeripheral *peripheral = [self.scannedPeripherals objectForKey:address];

    if (peripheral == nil) {
        // Peripheral not present in the current scan results (e.g. a stale
        // list entry). Report failure immediately, otherwise the Dart side
        // would wait forever.
        NSLog(@"connect failed: peripheral not in scan results, rescan needed");
        [self updateConnectState:CONNECT_STATE_FAILT];
        result(nil);
        return;
    }

    // If another printer is still connected, drop that link first.
    if (self.connectedPeripheral != nil && self.connectedPeripheral != peripheral) {
        [[self ensureCentral] cancelPeripheralConnection:self.connectedPeripheral];
    }

    self.connectedPeripheral = peripheral;
    self.writeCharacteristic = nil;
    self.reportedConnected = NO;
    [self updateConnectState:CONNECT_STATE_CONNECTING];
    [[self ensureCentral] connectPeripheral:peripheral options:nil];
    result(nil);
  } else if ([@"disconnect" isEqualToString:call.method]) {
    if (self.connectedPeripheral != nil && self.central != nil) {
        [self.central cancelPeripheralConnection:self.connectedPeripheral];
        // The disconnected state is reported from didDisconnectPeripheral.
    } else {
        [self updateConnectState:CONNECT_STATE_DISCONNECT];
    }
    result(nil);
  } else if ([@"writeData" isEqualToString:call.method]) {
       @try {
           NSDictionary *args = [call arguments];

           NSMutableArray *bytes = [args objectForKey:@"bytes"];

           NSNumber *lenBuf = [args objectForKey:@"length"];
           int len = [lenBuf intValue];
           char cArray[len];

           for (int i = 0; i < len; ++i) {
               cArray[i] = [bytes[i] charValue];
           }
           NSData *data = [NSData dataWithBytes:cArray length:sizeof(cArray)];
           // คืนค่าเมื่อเขียนครบจริง เพื่อให้ Dart await ได้และงานไม่ซ้อนกัน
           [self sendData:data result:result];
       } @catch (FlutterError *e) {
           result(e);
       }
  } else {
    result(FlutterMethodNotImplemented);
  }
}

// ===== Adapter (Bluetooth radio) state =====

/// Notifies the Dart side whether Bluetooth is usable, with a reason when not:
/// 'poweredOn' | 'poweredOff' | 'unauthorized' | 'unsupported'.
- (void)notifyBluetoothOn:(BOOL)on reason:(NSString *)reason {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_channel invokeMethod:@"BluetoothState"
                           arguments:@{@"on": @(on), @"reason": reason}];
    });
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    // Both the main central and the (short-lived) power-alert central report
    // here; they carry the same information so no filtering is needed.
    switch (central.state) {
        case CBManagerStatePoweredOn:
            [self notifyBluetoothOn:YES reason:@"poweredOn"];
            if (central == self.central && self.pendingScan) {
                self.pendingScan = NO;
                [self startScan];
            }
            break;
        case CBManagerStatePoweredOff:
            [self notifyBluetoothOn:NO reason:@"poweredOff"];
            if (central == self.central) [self handleLinkLost];
            break;
        case CBManagerStateUnauthorized:
            [self notifyBluetoothOn:NO reason:@"unauthorized"];
            break;
        case CBManagerStateUnsupported:
            [self notifyBluetoothOn:NO reason:@"unsupported"];
            break;
        default:
            // unknown / resetting are transient states — do not report them.
            break;
    }
}

- (void)handleLinkLost {
    if (self.connectedPeripheral != nil) {
        self.connectedPeripheral = nil;
        self.writeCharacteristic = nil;
        self.reportedConnected = NO;
        [self updateConnectState:CONNECT_STATE_DISCONNECT];
    }
}

// ===== Scanning =====

/// Service UUIDs commonly advertised by thermal/label printers
/// (ISSC/Microchip transparent UART, Gprinter, generic ESC/POS-over-BLE).
+ (NSArray<CBUUID *> *)knownPrinterServiceUUIDs {
    static NSArray<CBUUID *> *uuids = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        uuids = @[
            [CBUUID UUIDWithString:@"49535343-FE7D-4AE5-8FA9-9FAFD205E455"],
            [CBUUID UUIDWithString:@"E7810A71-73AE-499D-8C15-FAA9AEF0C3F2"],
            [CBUUID UUIDWithString:@"FF00"],
            [CBUUID UUIDWithString:@"FFE0"],
            [CBUUID UUIDWithString:@"FF12"],
            [CBUUID UUIDWithString:@"18F0"],
        ];
    });
    return uuids;
}

- (void)startScan {
    [self.central scanForPeripheralsWithServices:nil options:nil];
}

- (void)centralManager:(CBCentralManager *)central
 didDiscoverPeripheral:(CBPeripheral *)peripheral
     advertisementData:(NSDictionary<NSString *, id> *)advertisementData
                  RSSI:(NSNumber *)RSSI {
    if (central != self.central || peripheral == nil) return;

    NSString *uuidString = [[peripheral identifier] UUIDString];
    [self.scannedPeripherals setObject:peripheral forKey:uuidString];

    // Many Chinese printers advertise without a name. Never drop them —
    // fall back to the advertised local name, then to a generated name.
    NSString *name = peripheral.name;
    if (name == nil || name.length == 0) {
        name = [advertisementData objectForKey:CBAdvertisementDataLocalNameKey];
    }
    if (name == nil || name.length == 0) {
        BOOL looksLikePrinter = NO;
        NSArray *advServices = [advertisementData objectForKey:CBAdvertisementDataServiceUUIDsKey];
        for (CBUUID *svc in advServices) {
            if ([[FlutterPrintLabelPlugin knownPrinterServiceUUIDs] containsObject:svc]) {
                looksLikePrinter = YES;
                break;
            }
        }
        NSString *shortId = uuidString.length >= 4 ? [uuidString substringToIndex:4] : uuidString;
        name = [NSString stringWithFormat:@"%@ (%@)",
                looksLikePrinter ? @"Printer" : @"Unknown", shortId];
    }

    // Re-emit only when the name changed (e.g. the real name arrived later
    // in a scan response packet).
    NSString *sentName = [self.sentDeviceNames objectForKey:uuidString];
    if (sentName != nil && [sentName isEqualToString:name]) return;
    [self.sentDeviceNames setObject:name forKey:uuidString];

    NSDictionary *device = [NSDictionary dictionaryWithObjectsAndKeys:uuidString, @"address", name, @"name", nil, @"type", nil];
    [self->_channel invokeMethod:@"ScanResult" arguments:device];
}

// ===== Connection =====

- (void)centralManager:(CBCentralManager *)central didConnectPeripheral:(CBPeripheral *)peripheral {
    if (central != self.central) return;
    peripheral.delegate = self;
    [peripheral discoverServices:nil];
}

- (void)centralManager:(CBCentralManager *)central
didFailToConnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error {
    if (central != self.central) return;
    NSLog(@"connect failed: %@", error);
    if (peripheral == self.connectedPeripheral) {
        self.connectedPeripheral = nil;
    }
    [self updateConnectState:CONNECT_STATE_FAILT];
}

- (void)centralManager:(CBCentralManager *)central
didDisconnectPeripheral:(CBPeripheral *)peripheral
                 error:(NSError *)error {
    if (central != self.central) return;
    if (peripheral == self.connectedPeripheral) {
        self.connectedPeripheral = nil;
        self.writeCharacteristic = nil;
        self.reportedConnected = NO;
    }
    [self updateConnectState:CONNECT_STATE_DISCONNECT];
}

- (void)peripheral:(CBPeripheral *)peripheral didDiscoverServices:(NSError *)error {
    if (peripheral != self.connectedPeripheral) return;
    if (error != nil) {
        NSLog(@"discover services error: %@", error);
        [self updateConnectState:CONNECT_STATE_FAILT];
        return;
    }
    for (CBService *service in peripheral.services) {
        [peripheral discoverCharacteristics:nil forService:service];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
didDiscoverCharacteristicsForService:(CBService *)service
             error:(NSError *)error {
    if (peripheral != self.connectedPeripheral || error != nil) return;

    // Pick the write characteristic: prefer characteristics in well-known
    // printer services; otherwise fall back to the first writable one found.
    BOOL knownService = [[FlutterPrintLabelPlugin knownPrinterServiceUUIDs]
                         containsObject:service.UUID];
    for (CBCharacteristic *c in service.characteristics) {
        BOOL writable = (c.properties & CBCharacteristicPropertyWriteWithoutResponse) ||
                        (c.properties & CBCharacteristicPropertyWrite);
        if (!writable) continue;
        if (self.writeCharacteristic == nil || knownService) {
            self.writeCharacteristic = c;
        }
        if (knownService) break;
    }

    // Report "connected" exactly once, when the printer is ready to receive.
    if (self.writeCharacteristic != nil && !self.reportedConnected) {
        self.reportedConnected = YES;
        [self updateConnectState:CONNECT_STATE_CONNECTED];
    }
}

// ===== Writing =====

/// [completion] ถูกเรียกเมื่อเขียนครบทุกก้อน (หรือหลุดกลางคัน)
/// ทำให้ฝั่ง Dart await ได้จริง แทนที่จะคืนค่าทันทีแล้วงานซ้อนกัน
- (void)sendData:(NSData *)data result:(FlutterResult)completion {
    CBPeripheral *peripheral = self.connectedPeripheral;
    CBCharacteristic *ch = self.writeCharacteristic;
    if (peripheral == nil || ch == nil ||
        peripheral.state != CBPeripheralStateConnected) {
        NSLog(@"write skipped: not connected or no writable characteristic");
        if (completion) completion(nil);
        return;
    }

    CBCharacteristicWriteType type =
        (ch.properties & CBCharacteristicPropertyWriteWithoutResponse)
            ? CBCharacteristicWriteWithoutResponse
            : CBCharacteristicWriteWithResponse;
    NSUInteger mtu = [peripheral maximumWriteValueLengthForType:type];
    if (mtu == 0 || mtu > 512) mtu = 150;

    self.pendingWriteData = data;
    self.pendingWriteOffset = 0;
    self.pendingWriteMtu = mtu;
    self.pendingWriteType = type;
    self.pendingWriteResult = completion;

    [self pumpPendingWrite];
}

/// เขียนต่อเนื่องเท่าที่คิวของ CoreBluetooth รับไหว
/// เมื่อคิวเต็มจะหยุดรอ callback peripheralIsReadyToSendWriteWithoutResponse:
/// เร็วกว่าการหน่วงตายตัวต่อก้อนหลายเท่า แต่ยังไม่ท่วมบัฟเฟอร์เครื่องพิมพ์
- (void)pumpPendingWrite {
    NSData *data = self.pendingWriteData;
    if (data == nil) return;

    CBPeripheral *peripheral = self.connectedPeripheral;
    CBCharacteristic *ch = self.writeCharacteristic;
    if (peripheral == nil || ch == nil ||
        peripheral.state != CBPeripheralStateConnected) {
        NSLog(@"write aborted: disconnected at %lu/%lu",
              (unsigned long)self.pendingWriteOffset, (unsigned long)data.length);
        [self finishPendingWrite];
        return;
    }

    while (self.pendingWriteOffset < data.length) {
        if (self.pendingWriteType == CBCharacteristicWriteWithoutResponse &&
            !peripheral.canSendWriteWithoutResponse) {
            // คิวเต็ม — รอ callback แล้วค่อยมาต่อ
            return;
        }

        NSUInteger len =
            MIN(self.pendingWriteMtu, data.length - self.pendingWriteOffset);
        [peripheral writeValue:[data subdataWithRange:NSMakeRange(self.pendingWriteOffset, len)]
             forCharacteristic:ch
                          type:self.pendingWriteType];
        self.pendingWriteOffset += len;
    }

    [self finishPendingWrite];
}

- (void)finishPendingWrite {
    FlutterResult completion = self.pendingWriteResult;
    self.pendingWriteData = nil;
    self.pendingWriteOffset = 0;
    self.pendingWriteResult = nil;
    if (completion) completion(nil);
}

/// CoreBluetooth แจ้งว่าคิวว่างแล้ว — เขียนก้อนถัดไปต่อ
- (void)peripheralIsReadyToSendWriteWithoutResponse:(CBPeripheral *)peripheral {
    [self pumpPendingWrite];
}

- (void)updateConnectState:(ConnectState)state {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSNumber *ret = @0;
        switch (state) {
            case CONNECT_STATE_CONNECTING:
                ret = @1;
                break;
            case CONNECT_STATE_CONNECTED:
                ret = @2;
                break;
            case CONNECT_STATE_FAILT:
            case CONNECT_STATE_DISCONNECT:
            default:
                ret = @0;
                break;
        }

        if (self->_stateStreamHandler.sink != nil) {
            self.stateStreamHandler.sink(ret);
        }
    });
}

@end

@implementation BluetoothPrintStreamHandler

- (FlutterError *)onListenWithArguments:(id)arguments eventSink:(FlutterEventSink)eventSink {
  self.sink = eventSink;
  return nil;
}

- (FlutterError *)onCancelWithArguments:(id)arguments {
  self.sink = nil;
  return nil;
}

@end
