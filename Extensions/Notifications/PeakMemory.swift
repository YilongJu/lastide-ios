// `mach_task_self_` is a C global, which Swift 6 refuses without this import form (Swift Forums thread 73289).
@preconcurrency import Darwin

/// The extension's peak physical footprint in bytes, from `task_info` with `TASK_VM_INFO` (design section 6.4).
/// Live check L7 compares it with the extension's 24 MB limit. Returns nil when the call fails.
enum PeakMemory {
    static func read() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { raw in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), raw, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let footprint = UInt64(info.phys_footprint)
        // The ledger's peak arrived in revision 2 of the structure. An older answer is too short to hold it.
        guard let offset = MemoryLayout<task_vm_info_data_t>.offset(of: \.ledger_phys_footprint_peak),
              Int(count) * MemoryLayout<integer_t>.size >= offset + MemoryLayout<Int64>.size,
              info.ledger_phys_footprint_peak > 0
        else { return footprint }
        return max(footprint, UInt64(info.ledger_phys_footprint_peak))
    }
}
