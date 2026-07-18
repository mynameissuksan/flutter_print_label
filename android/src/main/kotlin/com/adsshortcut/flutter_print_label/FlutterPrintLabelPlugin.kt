package com.adsshortcut.flutter_print_label

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Message
import android.util.Log
import android.widget.Toast
import androidx.core.app.ActivityCompat
import androidx.core.app.ActivityCompat.startActivityForResult
import com.adsshortcut.flutter_print_label.bluetooth.BluetoothConnection
import com.adsshortcut.flutter_print_label.bluetooth.BluetoothConstants
import com.adsshortcut.flutter_print_label.bluetooth.BluetoothService
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry

/**
 * Bluetooth label printer plugin (Android side).
 *
 * Supports two transports:
 * - Bluetooth Classic (SPP): lists devices already paired in system settings.
 * - BLE: real scan of nearby devices; unnamed devices are reported with a
 *   generated fallback name instead of being skipped, because many budget
 *   Chinese label printers advertise without a name.
 */
class FlutterPrintLabelPlugin : FlutterPlugin, MethodCallHandler,
    PluginRegistry.RequestPermissionsResultListener,
    PluginRegistry.ActivityResultListener,
    ActivityAware {

    private val tag = "FlutterPrintLabelPlugin"

    private var binaryMessenger: BinaryMessenger? = null

    private var channel: MethodChannel? = null
    private var stateChannel: EventChannel? = null
    private var eventSink: EventChannel.EventSink? = null
    private var context: Context? = null
    private var currentActivity: Activity? = null
    private var requestPermissionBT: Boolean = false
    private var isBle: Boolean = false
    private var isScan: Boolean = false
    private lateinit var bluetoothService: BluetoothService

    private val bluetoothHandler = object : Handler(Looper.getMainLooper()) {

        private val bluetoothStatus: Int
            get() = BluetoothService.bluetoothConnection?.state ?: 99

        override fun handleMessage(msg: Message) {
            super.handleMessage(msg)
            when (msg.what) {
                BluetoothConstants.MESSAGE_STATE_CHANGE -> {
                    when (bluetoothStatus) {
                        BluetoothConstants.STATE_CONNECTED -> {
                            if (msg.obj != null)
                                try {
                                    val result = msg.obj as Result?
                                    result?.success(true)
                                } catch (_: Exception) {
                                }
                            eventSink?.success(2)
                            bluetoothService.removeReconnectHandlers()
                        }
                        BluetoothConstants.STATE_CONNECTING -> {
                            eventSink?.success(1)
                        }
                        BluetoothConstants.STATE_NONE -> {
                            eventSink?.success(0)
                            bluetoothService.autoConnectBt()
                        }
                        BluetoothConstants.STATE_FAILED -> {
                            if (msg.obj != null)
                                try {
                                    val result = msg.obj as Result?
                                    result?.success(false)
                                } catch (_: Exception) {
                                }
                            eventSink?.success(0)
                        }
                    }
                }
                BluetoothConstants.MESSAGE_TOAST -> {
                    val bundle = msg.data
                    bundle?.getInt(BluetoothConnection.TOAST)?.let {
                        Toast.makeText(context, context!!.getString(it), Toast.LENGTH_SHORT).show()
                    }
                }
                else -> {
                    // Other message types (read/write/scan notifications) need
                    // no handling here.
                }
            }
        }
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        binaryMessenger = flutterPluginBinding.binaryMessenger
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        stateChannel?.setStreamHandler(null)
        stateChannel = null
        if (this::bluetoothService.isInitialized) bluetoothService.setHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        context = binding.activity.applicationContext
        currentActivity = binding.activity

        channel = MethodChannel(binaryMessenger!!, methodChannel)
        channel!!.setMethodCallHandler(this)

        stateChannel = EventChannel(binaryMessenger!!, eventChannelBT)
        stateChannel?.setStreamHandler(object : EventChannel.StreamHandler {

            override fun onListen(p0: Any?, sink: EventChannel.EventSink) {
                eventSink = sink
            }

            override fun onCancel(p0: Any?) {
                eventSink = null
            }
        })

        bluetoothService = BluetoothService.getInstance(bluetoothHandler)

        binding.addRequestPermissionsResultListener(this)
        binding.addActivityResultListener(this)
        bluetoothService.setActivity(currentActivity)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        currentActivity = null
        if (this::bluetoothService.isInitialized) bluetoothService.setActivity(null)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        currentActivity = binding.activity
        binding.addRequestPermissionsResultListener(this)
        binding.addActivityResultListener(this)
        bluetoothService.setActivity(currentActivity)
    }

    override fun onDetachedFromActivity() {
        currentActivity = null
        if (this::bluetoothService.isInitialized) bluetoothService.setActivity(null)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        isScan = false
        Log.d(tag, "method call " + call.method)
        when {
            // Bluetooth Classic: return the list of devices paired in system
            // settings. This is not a real scan.
            call.method.equals("getBluetoothList") -> {
                isBle = false
                isScan = true
                if (verifyIsBluetoothIsOn()) {
                    bluetoothService.cleanHandlerBtBle()
                    bluetoothService.scanBluDevice(channel!!)
                    result.success(null)
                }
            }
            // BLE: real scan of nearby advertising devices.
            call.method.equals("getBluetoothLeList") -> {
                isBle = true
                isScan = true
                if (verifyIsBluetoothIsOn()) {
                    bluetoothService.scanBleDevice(channel!!)
                    result.success(null)
                }
            }

            call.method.equals("onStartConnection") -> {
                val address: String? = call.argument("address")
                val isBle: Boolean? = call.argument("isBle")
                val autoConnect: Boolean =
                    if (call.hasArgument("autoConnect")) call.argument("autoConnect")!! else false
                if (verifyIsBluetoothIsOn()) {
                    bluetoothService.setHandler(bluetoothHandler)
                    bluetoothService.onStartConnection(
                        context!!, address!!, result,
                        isBle = isBle!!, autoConnect = autoConnect
                    )
                } else {
                    result.success(false)
                }
            }

            call.method.equals("disconnect") -> {
                try {
                    bluetoothService.setHandler(bluetoothHandler)
                    bluetoothService.bluetoothDisconnect()
                    result.success(true)
                } catch (e: Exception) {
                    result.success(false)
                }
            }

            call.method.equals("sendDataByte") -> {
                if (verifyIsBluetoothIsOn()) {
                    bluetoothService.setHandler(bluetoothHandler)
                    val listInt: ArrayList<Int>? = call.argument("bytes")
                    val ints = listInt!!.toIntArray()
                    val bytes =
                        ints.foldIndexed(ByteArray(ints.size)) { i, a, v -> a.apply { set(i, v.toByte()) } }
                    val res = bluetoothService.sendDataByte(bytes)
                    result.success(res)
                } else {
                    result.success(false)
                }
            }
            call.method.equals("sendText") -> {
                if (verifyIsBluetoothIsOn()) {
                    val text: String? = call.argument("text")
                    bluetoothService.sendData(text!!)
                    result.success(true)
                } else {
                    result.success(false)
                }
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    /**
     * Ensures runtime permissions are granted and Bluetooth is enabled.
     * When Bluetooth is off, shows the system "enable Bluetooth" dialog.
     */
    private fun verifyIsBluetoothIsOn(): Boolean {
        if (checkPermissions()) {
            if (!this::bluetoothService.isInitialized) {
                bluetoothService = BluetoothService.getInstance(bluetoothHandler)
            }
            if (!bluetoothService.mBluetoothAdapter.isEnabled) {
                if (requestPermissionBT) return false
                val enableBtIntent = Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE)
                currentActivity?.let {
                    startActivityForResult(it, enableBtIntent, PERMISSION_ENABLE_BLUETOOTH, null)
                }
                requestPermissionBT = true
                return false
            }
        } else return false
        return true
    }

    private fun checkPermissions(): Boolean {
        val permissions = mutableListOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            permissions.add(Manifest.permission.BLUETOOTH_SCAN)
            permissions.add(Manifest.permission.BLUETOOTH_CONNECT)
        }

        if (!hasPermissions(context, *permissions.toTypedArray())) {
            ActivityCompat.requestPermissions(
                currentActivity!!, permissions.toTypedArray(), PERMISSION_ALL
            )
            return false
        }
        return true
    }

    private fun hasPermissions(context: Context?, vararg permissions: String?): Boolean {
        if (context != null) {
            for (permission in permissions) {
                if (ActivityCompat.checkSelfPermission(context, permission!!)
                    != PackageManager.PERMISSION_GRANTED
                ) {
                    return false
                }
            }
        }
        return true
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        when (requestCode) {
            PERMISSION_ENABLE_BLUETOOTH -> {
                requestPermissionBT = false
                if (resultCode == Activity.RESULT_OK)
                    if (isScan)
                        if (isBle) bluetoothService.scanBleDevice(channel!!)
                        else bluetoothService.scanBluDevice(channel!!)
            }
        }
        return true
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        when (requestCode) {
            PERMISSION_ALL -> {
                var grant = true
                grantResults.forEach { permission ->
                    val permissionGranted = grantResults.isNotEmpty() &&
                            permission == PackageManager.PERMISSION_GRANTED
                    if (!permissionGranted) grant = false
                }
                if (!grant) {
                    Toast.makeText(context, R.string.not_permissions, Toast.LENGTH_LONG).show()
                } else {
                    if (verifyIsBluetoothIsOn() && isScan)
                        if (isBle) bluetoothService.scanBleDevice(channel!!)
                        else bluetoothService.scanBluDevice(channel!!)
                }
                return true
            }
        }
        return false
    }

    companion object {
        const val PERMISSION_ALL = 1
        const val PERMISSION_ENABLE_BLUETOOTH = 999
        const val methodChannel = "com.adsshortcut.flutter_print_label"
        const val eventChannelBT = "com.adsshortcut.flutter_print_label/bt_state"
    }
}
