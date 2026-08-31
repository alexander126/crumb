import Foundation

struct CrumbShakeGestureRecognizer {
    private let thresholdG: Double
    private let requiredHits: Int
    private let hitWindow: TimeInterval
    private let cooldown: TimeInterval

    private var gravity = [Double](repeating: 0, count: 3)
    private var hitTimes: [TimeInterval] = []
    private var lastTriggerAt: TimeInterval?

    init(
        thresholdG: Double = 2.2,
        requiredHits: Int = 2,
        hitWindow: TimeInterval = 0.6,
        cooldown: TimeInterval = 1.5
    ) {
        self.thresholdG = thresholdG
        self.requiredHits = requiredHits
        self.hitWindow = hitWindow
        self.cooldown = cooldown
    }

    mutating func record(
        accelerationX: Double,
        y: Double,
        z: Double,
        at timestamp: TimeInterval
    ) -> Bool {
        let values = [accelerationX, y, z]
        var magnitudeSquared = 0.0
        for index in values.indices {
            gravity[index] = 0.8 * gravity[index] + 0.2 * values[index]
            let linear = values[index] - gravity[index]
            magnitudeSquared += linear * linear
        }
        return record(linearMagnitudeG: magnitudeSquared.squareRoot(), at: timestamp)
    }

    mutating func record(linearMagnitudeG: Double, at timestamp: TimeInterval) -> Bool {
        guard linearMagnitudeG >= thresholdG else { return false }
        hitTimes.append(timestamp)
        hitTimes.removeAll { timestamp - $0 > hitWindow }

        guard hitTimes.count >= requiredHits else { return false }
        guard lastTriggerAt.map({ timestamp - $0 >= cooldown }) ?? true else {
            hitTimes.removeAll()
            return false
        }

        lastTriggerAt = timestamp
        hitTimes.removeAll()
        return true
    }

    mutating func reset() {
        gravity = [Double](repeating: 0, count: 3)
        hitTimes.removeAll()
        lastTriggerAt = nil
    }
}
