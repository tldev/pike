import XCTest
@testable import Pike

final class KalmanFilterTests: XCTestCase {

    func testFirstMeasurementReturnsAsIs() {
        let filter = CourseKalmanFilter()
        let result = filter.update(measurement: 45.0)
        XCTAssertEqual(result, 45.0, accuracy: 0.001)
    }

    func testNoisySequenceProducesSmoother() {
        let filter = CourseKalmanFilter()
        // Feed a series of noisy values around 90°.
        let measurements = [85.0, 95.0, 88.0, 92.0, 90.0, 87.0, 93.0, 91.0, 89.0, 90.0]
        var results: [Double] = []
        for m in measurements {
            results.append(filter.update(measurement: m))
        }

        // The later values should be closer to 90° than the raw measurements.
        let lastFew = Array(results.suffix(3))
        for val in lastFew {
            XCTAssertEqual(val, 90.0, accuracy: 5.0, "Filtered output should converge near 90°")
        }

        // Variance of filtered output should be less than variance of raw input.
        let rawMean = measurements.reduce(0, +) / Double(measurements.count)
        let rawVar = measurements.map { ($0 - rawMean) * ($0 - rawMean) }.reduce(0, +) / Double(measurements.count)
        let filtMean = results.reduce(0, +) / Double(results.count)
        let filtVar = results.map { ($0 - filtMean) * ($0 - filtMean) }.reduce(0, +) / Double(results.count)
        XCTAssertLessThan(filtVar, rawVar, "Filtered variance should be less than raw variance")
    }

    func testWraparoundHandling() {
        let filter = CourseKalmanFilter()
        // Start near 350°, then measurements cross 0°.
        _ = filter.update(measurement: 350.0)
        _ = filter.update(measurement: 355.0)
        let result = filter.update(measurement: 5.0)  // Crossed 0°

        // Should be somewhere around 0° (between 350 and 10), not jump to ~180°.
        let diff = min(abs(result - 0), abs(result - 360))
        XCTAssertLessThan(diff, 30, "Should handle wraparound gracefully")
    }

    func testStableInputConverges() {
        let filter = CourseKalmanFilter()
        var result = 0.0
        for _ in 0..<20 {
            result = filter.update(measurement: 180.0)
        }
        XCTAssertEqual(result, 180.0, accuracy: 1.0, "Stable input should converge to the measurement")
    }
}
