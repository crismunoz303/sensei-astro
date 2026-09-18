import Foundation

enum LocationPolicy {
    static func accepts(accuracy: Double, timestamp: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(timestamp)
        return accuracy.isFinite && accuracy >= 0 && age >= -10 && age <= 60
    }

    static func shouldUpdate(distance: Double, oldAccuracy: Double, newAccuracy: Double) -> Bool {
        distance >= 500 || (oldAccuracy > 1_000 && newAccuracy < oldAccuracy / 2)
    }
}
