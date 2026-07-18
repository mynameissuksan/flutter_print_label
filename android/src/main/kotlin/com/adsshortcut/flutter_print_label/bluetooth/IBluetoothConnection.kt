package com.adsshortcut.flutter_print_label.bluetooth
import io.flutter.plugin.common.MethodChannel.Result

interface IBluetoothConnection {
    fun connect(address: String, result: Result)
    fun stop()
    fun write(out: ByteArray?)
    var state: Int
}