import CoreBluetooth

struct CharacteristicWriteTaskController: PeripheralTaskController {

    typealias TaskSpec = CharacteristicWriteTaskSpec

    private let task: SubjectTask

    init(_ task: SubjectTask) {
        self.task = task
    }

    func start(peripheral: CBPeripheral) -> SubjectTask {
        let serviceIndex = Int(task.key.serviceInstanceID) ?? 0
        let characteristicIndex = Int(task.key.instanceID) ?? 0
        let filteredServices = peripheral.services?.filter({ $0.uuid == task.key.serviceID }) ?? []

        guard
            peripheral.state == .connected,
            serviceIndex >= 0, serviceIndex < filteredServices.count
        else {
            return task.with(state: task.state.finished(PluginError.internalInconcictency(details: nil)))
        }

        let service = filteredServices[serviceIndex]
        let filteredCharacteristics = service.characteristics?.filter({ $0.uuid == task.key.id }) ?? []

        guard
            characteristicIndex >= 0, characteristicIndex < filteredCharacteristics.count
        else {
            return task.with(state: task.state.finished(PluginError.internalInconcictency(details: nil)))
        }

        let characteristic = filteredCharacteristics[characteristicIndex]

        guard characteristic.properties.contains(.write)
        else {
            return task.with(state: task.state.finished(PluginError.internalInconcictency(details: nil)))
        }

        peripheral.writeValue(task.params.value, for: characteristic, type: .withResponse)

        return task.with(state: task.state.processing(.writing))
    }

    func cancel(error: Error) -> SubjectTask {
        return task.with(state: task.state.finished(error))
    }

    func handleWrite(error: Error?) -> SubjectTask {
        return task.with(state: task.state.finished(error))
    }
}
