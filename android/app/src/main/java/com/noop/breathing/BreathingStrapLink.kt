package com.noop.breathing

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import com.noop.ble.StandardHeartRate
import com.noop.ui.NoopPrefs
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * FORK: the chest strap of the Breathing tab. Twin of the fork iOS `BreathingStrapLink`: scans for a
 * standard Bluetooth heart-rate strap (service 0x180D), connects, and publishes its heart rate and
 * beat-to-beat R-R intervals live, ALONGSIDE the WHOOP.
 *
 * Read-only and isolated, like `StandardHrSource`: its own scanner and [BluetoothGatt], never touching
 * `WhoopBleClient` or the WHOOP link, and it persists nothing — the session that reads it decides what to
 * keep. The only write is the standard notify subscription (CCCD) on 0x2A37. The last strap used is
 * remembered so the next session reconnects without a scan.
 */
@SuppressLint("MissingPermission")
object BreathingStrapLink {

    enum class State { IDLE, BLUETOOTH_OFF, SCANNING, CONNECTING, CONNECTED, DISCONNECTED }

    data class Found(val address: String, val name: String, val rssi: Int)

    private val HEART_RATE_SERVICE: UUID = UUID.fromString("0000180d-0000-1000-8000-00805f9b34fb")
    private val HEART_RATE_CHAR: UUID = UUID.fromString("00002a37-0000-1000-8000-00805f9b34fb")
    private val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    private const val LAST_STRAP_KEY = "noop.breathing.lastStrapAddress"
    private const val LAST_STRAP_NAME_KEY = "noop.breathing.lastStrapName"

    private val _state = MutableStateFlow(State.IDLE)
    val state: StateFlow<State> = _state
    private val _found = MutableStateFlow<List<Found>>(emptyList())
    val found: StateFlow<List<Found>> = _found
    private val _strapName = MutableStateFlow<String?>(null)
    val strapName: StateFlow<String?> = _strapName
    private val _heartRate = MutableStateFlow<Int?>(null)
    val heartRate: StateFlow<Int?> = _heartRate

    val isConnected: Boolean get() = _state.value == State.CONNECTED

    private val handler = Handler(Looper.getMainLooper())
    private var appContext: Context? = null
    private var gatt: BluetoothGatt? = null
    private val seen = ConcurrentHashMap<String, BluetoothDevice>()
    private val beatLock = Any()
    /** Beats not yet taken by the session: (unix seconds, fractional; R-R ms). */
    private val pendingBeats = ArrayList<Pair<Double, Int>>()
    private var userDisconnect = false
    private var retriedOnce = false

    private fun adapter(ctx: Context) =
        (ctx.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    fun lastStrapAddress(ctx: Context): String? = NoopPrefs.of(ctx).getString(LAST_STRAP_KEY, null)
    fun lastStrapName(ctx: Context): String? = NoopPrefs.of(ctx).getString(LAST_STRAP_NAME_KEY, null)

    /** Scan for straps. Results land in [found], closest first. */
    fun scan(ctx: Context) {
        val app = ctx.applicationContext.also { appContext = it }
        _found.value = emptyList()
        val ad = adapter(app)
        if (ad == null || !ad.isEnabled) { _state.value = State.BLUETOOTH_OFF; return }
        val sc = ad.bluetoothLeScanner ?: run { _state.value = State.BLUETOOTH_OFF; return }
        runCatching { sc.stopScan(scanCallback) }
        _state.value = State.SCANNING
        val filter = ScanFilter.Builder().setServiceUuid(ParcelUuid(HEART_RATE_SERVICE)).build()
        val settings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        runCatching { sc.startScan(listOf(filter), settings, scanCallback) }
            .onFailure { _state.value = State.IDLE }
    }

    fun stopScan() {
        val app = appContext ?: return
        val ad = adapter(app)
        if (ad?.isEnabled == true) runCatching { ad.bluetoothLeScanner?.stopScan(scanCallback) }
        if (_state.value == State.SCANNING) _state.value = State.IDLE
    }

    /** Reconnect the last strap without a scan, when there is one. */
    fun reconnectLast(ctx: Context) {
        val app = ctx.applicationContext.also { appContext = it }
        if (isConnected || _state.value == State.CONNECTING) return
        val addr = lastStrapAddress(app) ?: return
        connect(app, addr)
    }

    fun connect(ctx: Context, address: String) {
        val app = ctx.applicationContext.also { appContext = it }
        stopScan()
        val ad = adapter(app)
        if (ad == null || !ad.isEnabled) { _state.value = State.BLUETOOTH_OFF; return }
        val device = seen[address] ?: runCatching { ad.getRemoteDevice(address) }.getOrNull() ?: return
        userDisconnect = false
        retriedOnce = false
        val name = _found.value.firstOrNull { it.address == address }?.name ?: runCatching { device.name }.getOrNull()
        NoopPrefs.of(app).edit().putString(LAST_STRAP_KEY, address)
            .apply { if (name != null) putString(LAST_STRAP_NAME_KEY, name) }.apply()
        _strapName.value = name ?: lastStrapName(app)
        connectDevice(app, device)
    }

    private fun connectDevice(app: Context, device: BluetoothDevice) {
        gatt?.let { runCatching { it.disconnect(); it.close() } }
        _state.value = State.CONNECTING
        gatt = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                device.connectGatt(app, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
            } else {
                @Suppress("DEPRECATION")
                device.connectGatt(app, false, gattCallback)
            }
        }.getOrNull()
        if (gatt == null) _state.value = State.DISCONNECTED
    }

    fun disconnect() {
        userDisconnect = true
        gatt?.let { runCatching { it.disconnect(); it.close() } }
        gatt = null
        _heartRate.value = null
        _state.value = State.IDLE
    }

    fun forget(ctx: Context) {
        disconnect()
        NoopPrefs.of(ctx).edit().remove(LAST_STRAP_KEY).remove(LAST_STRAP_NAME_KEY).apply()
        _strapName.value = null
    }

    /** Hand over the beats received since the last call. */
    fun takeBeats(): List<Pair<Double, Int>> = synchronized(beatLock) {
        val out = ArrayList(pendingBeats)
        pendingBeats.clear()
        out
    }

    private fun handle(bytes: ByteArray) {
        val parsed = StandardHeartRate.parse(bytes) ?: return
        if (parsed.hr > 0) _heartRate.value = parsed.hr
        if (parsed.rr.isEmpty()) return
        // A notification carries the beats that ended just before it; place them back in time from now.
        var t = System.currentTimeMillis() / 1000.0
        val beats = ArrayList<Pair<Double, Int>>()
        for (rr in parsed.rr.asReversed()) if (rr > 0) { beats += t to rr; t -= rr / 1000.0 }
        synchronized(beatLock) { pendingBeats.addAll(beats.asReversed()) }
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val d = result.device
            seen[d.address] = d
            val name = runCatching { d.name }.getOrNull() ?: result.scanRecord?.deviceName ?: "Ceinture cardio"
            val list = _found.value.filter { it.address != d.address } + Found(d.address, name, result.rssi)
            _found.value = list.sortedByDescending { it.rssi }
        }

        override fun onScanFailed(errorCode: Int) {
            if (_state.value == State.SCANNING) _state.value = State.IDLE
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            handler.post {
                when (newState) {
                    BluetoothProfile.STATE_CONNECTED -> {
                        _state.value = State.CONNECTED
                        runCatching { g.device.name }.getOrNull()?.let { _strapName.value = it }
                        runCatching { g.discoverServices() }
                    }
                    BluetoothProfile.STATE_DISCONNECTED -> {
                        _heartRate.value = null
                        if (gatt === g) { runCatching { g.close() }; gatt = null }
                        if (userDisconnect) return@post
                        _state.value = State.DISCONNECTED
                        // An unexpected drop mid-session (or Android's transient 133): try to come back once.
                        val app = appContext
                        if (!retriedOnce && app != null) {
                            retriedOnce = true
                            handler.postDelayed({ if (!userDisconnect) connectDevice(app, g.device) }, 1000)
                        }
                    }
                }
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS) return
            val ch = g.getService(HEART_RATE_SERVICE)?.getCharacteristic(HEART_RATE_CHAR) ?: return
            runCatching {
                g.setCharacteristicNotification(ch, true)
                val cccd = ch.getDescriptor(CCCD) ?: return@runCatching
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    g.writeDescriptor(cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                } else {
                    @Suppress("DEPRECATION")
                    run { cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE; g.writeDescriptor(cccd) }
                }
            }
            retriedOnce = false
        }

        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic, value: ByteArray) {
            if (ch.uuid == HEART_RATE_CHAR) handler.post { handle(value) }
        }

        @Deprecated("Deprecated in Java")
        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic) {
            if (ch.uuid != HEART_RATE_CHAR) return
            val v = ch.value?.copyOf() ?: return
            handler.post { handle(v) }
        }
    }
}
