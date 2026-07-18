#import <Flutter/Flutter.h>
#import <CoreBluetooth/CoreBluetooth.h>

#define NAMESPACE @"flutter_print_label"

/// Connection states reported to the Dart side through the state event channel.
typedef NS_ENUM(NSUInteger, ConnectState) {
    NOT_FOUND_DEVICE,
    CONNECT_STATE_DISCONNECT,
    CONNECT_STATE_CONNECTING,
    CONNECT_STATE_CONNECTED,
    CONNECT_STATE_TIMEOUT,
    CONNECT_STATE_FAILT,
};

@interface FlutterPrintLabelPlugin : NSObject <FlutterPlugin, CBCentralManagerDelegate, CBPeripheralDelegate>
@end

@interface BluetoothPrintStreamHandler : NSObject <FlutterStreamHandler>
@property FlutterEventSink sink;
@end
