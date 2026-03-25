package com.signify.hue.flutterreactiveble.ble.extensions

import android.bluetooth.BluetoothGattCharacteristic
import com.polidea.rxandroidble2.RxBleConnection
import io.reactivex.Single
import java.util.UUID

fun RxBleConnection.resolveCharacteristic(
    uuid: UUID,
    instanceId: Int,
): Single<BluetoothGattCharacteristic> =
    discoverServices().flatMap { services ->
        val matches = services.bluetoothGattServices.flatMap { service ->
            service.characteristics.filter {
                it.uuid == uuid && it.instanceId == instanceId
            }
        }
        if (matches.size == 1) {
            Single.just(matches.first())
        } else if (matches.isEmpty()) {
            Single.error(NoSuchElementException("Characteristic $uuid with instanceId $instanceId not found"))
        } else {
            Single.error(IllegalArgumentException("Multiple characteristics found for $uuid with instanceId $instanceId"))
        }
    }

fun RxBleConnection.writeCharWithResponse(
    characteristic: BluetoothGattCharacteristic,
    value: ByteArray,
): Single<ByteArray> {
    characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
    return writeCharacteristic(characteristic, value)
}

fun RxBleConnection.writeCharWithoutResponse(
    characteristic: BluetoothGattCharacteristic,
    value: ByteArray,
): Single<ByteArray> {
    characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
    return writeCharacteristic(characteristic, value)
}
