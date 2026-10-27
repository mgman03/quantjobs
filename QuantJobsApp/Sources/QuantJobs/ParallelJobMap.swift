import Foundation

/// Parallel CPU work for large boards. Small boards stay sequential to avoid
/// task overhead; chunk indices restore source order as workers finish.
enum ParallelJobMap {
    static func compactMap<Input: Sendable, Output: Sendable>(
        _ values: [Input],
        transform: @escaping @Sendable (Input) -> Output?
    ) async -> [Output] {
        guard values.count >= 600 else { return values.compactMap(transform) }
        let workers = min(4, ProcessInfo.processInfo.activeProcessorCount,
                          max(2, values.count / 400))
        let size = (values.count + workers - 1) / workers
        var chunks = Array(repeating: [Output](), count: (values.count + size - 1) / size)
        await withTaskGroup(of: (Int, [Output]).self) { group in
            for index in chunks.indices {
                let start = index * size
                let end = min(start + size, values.count)
                group.addTask {
                    (index, values[start..<end].compactMap(transform))
                }
            }
            for await (index, output) in group { chunks[index] = output }
        }
        return chunks.flatMap { $0 }
    }
}
