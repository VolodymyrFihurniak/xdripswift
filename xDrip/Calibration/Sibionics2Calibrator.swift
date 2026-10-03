import CoreData
import Foundation

/// xDrip+'s existing weighted calibration curve applied to the factory-corrected
/// Sibionics value (mg/dL), which is already the value delivered by the stock core.
final class Sibionics2XDripCalibrator: Calibrator {
    let rawValueDivider = 1.0
    let ageAdjustMentNeeded = false
    let sParams = SlopeParameters(
        LOW_SLOPE_1: 1, LOW_SLOPE_2: 1, HIGH_SLOPE_1: 1, HIGH_SLOPE_2: 1,
        DEFAULT_LOW_SLOPE_LOW: 1, DEFAULT_LOW_SLOPE_HIGH: 1, DEFAULT_SLOPE: 1,
        DEFAULT_HIGH_SLOPE_HIGH: 1, DEFAUL_HIGH_SLOPE_LOW: 1
    )

    func description() -> String { "Sibionics2XDripCalibrator" }

    func createNewBgReading(
        rawData: Double, timeStamp: Date?, sensor: Sensor?, last3Readings: inout [BgReading],
        lastCalibrationsForActiveSensorInLastXDays: inout [Calibration],
        firstCalibration: Calibration?, lastCalibration: Calibration?, deviceName: String?,
        nsManagedObjectContext: NSManagedObjectContext
    ) -> BgReading {
        // The stock core has already converted this value to mg/dL. A new sensor
        // must have visible factory readings before the first fingerstick.
        guard firstCalibration != nil, lastCalibration != nil else {
            let reading = NoCalibrator().createNewBgReading(
                rawData: rawData, timeStamp: timeStamp, sensor: sensor,
                last3Readings: &last3Readings,
                lastCalibrationsForActiveSensorInLastXDays: &lastCalibrationsForActiveSensorInLastXDays,
                firstCalibration: nil, lastCalibration: nil, deviceName: deviceName,
                nsManagedObjectContext: nsManagedObjectContext
            )
            reading.ageAdjustedRawValue = rawData
            return reading
        }
        let reading = Sibionics2WeightedCalibrator().createNewBgReading(
            rawData: rawData, timeStamp: timeStamp, sensor: sensor,
            last3Readings: &last3Readings,
            lastCalibrationsForActiveSensorInLastXDays: &lastCalibrationsForActiveSensorInLastXDays,
            firstCalibration: firstCalibration, lastCalibration: lastCalibration,
            deviceName: deviceName, nsManagedObjectContext: nsManagedObjectContext
        )
        // The shared implementation only sets a calibrated value when a prior
        // reading exists. Its empty-history path otherwise changes zero to the
        // generic error value (38), even though this is a valid factory sample.
        if last3Readings.isEmpty,
           reading.calculatedValue == ConstantsCalibrationAlgorithms.bgReadingErrorValue,
           let lastCalibration {
            let corrected = lastCalibration.slope * rawData + lastCalibration.intercept
            let value = corrected.isFinite && corrected > 0 ? corrected : rawData
            reading.calculatedValue = min(
                ConstantsCalibrationAlgorithms.maximumBgReadingCalculatedValueLimit,
                max(ConstantsCalibrationAlgorithms.minimumBgReadingCalculatedValue, value)
            )
            reading.c = reading.calculatedValue
        }
        return reading
    }
}

/// Calls the shared xDrip weighted implementation for readings with calibration.
private struct Sibionics2WeightedCalibrator: Calibrator {
    let rawValueDivider = 1.0
    let ageAdjustMentNeeded = false
    let sParams = Sibionics2XDripCalibrator().sParams
    func description() -> String { "Sibionics2WeightedCalibrator" }
}

/// Recovers the factory readings left at zero by an older Sibionics calibration path.
/// Each row is evaluated at its own timestamp, so a later fingerstick cannot rewrite history.
enum Sibionics2ReadingRepair {
    static func repair(in context: NSManagedObjectContext, sensor: Sensor, mode: Sibionics2CalibrationMode) -> Int {
        var repaired = 0
        context.performAndWait {
            let request: NSFetchRequest<BgReading> = BgReading.fetchRequest()
            request.predicate = NSPredicate(
                format: "sensor == %@ AND calculatedValue == 0 AND rawData > 0 AND calibrationFlag == NO", sensor
            )
            request.sortDescriptors = [NSSortDescriptor(key: "timeStamp", ascending: true)]
            let calibrationRequest: NSFetchRequest<Calibration> = Calibration.fetchRequest()
            calibrationRequest.predicate = NSPredicate(format: "sensor == %@", sensor)
            calibrationRequest.sortDescriptors = [NSSortDescriptor(key: "timeStamp", ascending: true)]
            guard let readings = try? context.fetch(request),
                  let calibrations = try? context.fetch(calibrationRequest) else { return }

            for reading in readings {
                let eligible = calibrations.filter {
                    $0.timeStamp <= reading.timeStamp &&
                        $0.timeStamp >= reading.timeStamp.addingTimeInterval(-TimeInterval(mode.calibrationHistoryDays * 24 * 3600))
                }
                let value: Double
                switch mode {
                case .jugglucoNG:
                    let anchors = eligible.map {
                        Sibionics2CalibrationAnchor(
                            sensorMgDl: $0.estimateRawAtTimeOfCalibration > 0
                                ? $0.estimateRawAtTimeOfCalibration : $0.adjustedRawValue,
                            fingerstickMgDl: $0.bg, timeStamp: $0.timeStamp
                        )
                    }
                    value = Sibionics2JugglucoCalibrationMath.calibratedValue(
                        reading.rawData, at: reading.timeStamp, anchors: anchors
                    )
                case .xDripPlus:
                    if let latest = eligible.last, latest.slope.isFinite, latest.intercept.isFinite,
                       latest.slope > 0 {
                        value = latest.slope * reading.rawData + latest.intercept
                    } else {
                        value = reading.rawData
                    }
                }
                guard value.isFinite, value > 0 else { continue }
                reading.ageAdjustedRawValue = reading.rawData
                reading.calculatedValue = min(
                    ConstantsCalibrationAlgorithms.maximumBgReadingCalculatedValueLimit,
                    max(ConstantsCalibrationAlgorithms.minimumBgReadingCalculatedValue, value)
                )
                repaired += 1
            }
        }
        return repaired
    }
}

/// JugglucoNG's default calibration profile: single-point offset, then fresh
/// weighted OLS with a bounded slope and a small local anchor blend.
final class Sibionics2JugglucoCalibrator: Calibrator {
    let rawValueDivider = 1.0
    let ageAdjustMentNeeded = false
    let sParams = SlopeParameters(
        LOW_SLOPE_1: 1, LOW_SLOPE_2: 1, HIGH_SLOPE_1: 1, HIGH_SLOPE_2: 1,
        DEFAULT_LOW_SLOPE_LOW: 1, DEFAULT_LOW_SLOPE_HIGH: 1, DEFAULT_SLOPE: 1,
        DEFAULT_HIGH_SLOPE_HIGH: 1, DEFAUL_HIGH_SLOPE_LOW: 1
    )

    func description() -> String { "Sibionics2JugglucoNGCalibrator" }

    func createNewBgReading(
        rawData: Double,
        timeStamp: Date?,
        sensor: Sensor?,
        last3Readings: inout [BgReading],
        lastCalibrationsForActiveSensorInLastXDays: inout [Calibration],
        firstCalibration: Calibration?,
        lastCalibration: Calibration?,
        deviceName: String?,
        nsManagedObjectContext: NSManagedObjectContext
    ) -> BgReading {
        let reading = NoCalibrator().createNewBgReading(
            rawData: rawData,
            timeStamp: timeStamp,
            sensor: sensor,
            last3Readings: &last3Readings,
            lastCalibrationsForActiveSensorInLastXDays: &lastCalibrationsForActiveSensorInLastXDays,
            firstCalibration: firstCalibration,
            lastCalibration: lastCalibration,
            deviceName: deviceName,
            nsManagedObjectContext: nsManagedObjectContext
        )

        // NoCalibrator leaves this field at zero. Manual calibration uses it
        // as the sensor-side value, and Sibionics requires no age adjustment.
        reading.ageAdjustedRawValue = rawData
        let anchors = Self.uniqueAnchors(
            lastCalibrationsForActiveSensorInLastXDays + [firstCalibration].compactMap { $0 }
        )
        let corrected = Sibionics2JugglucoCalibrationMath.calibratedValue(
            rawData,
            at: timeStamp ?? Date(),
            anchors: anchors
        )
        reading.calculatedValue = min(
            ConstantsCalibrationAlgorithms.maximumBgReadingCalculatedValue,
            max(ConstantsCalibrationAlgorithms.minimumBgReadingCalculatedValue, corrected)
        )
        findSlope(for: reading, last2Readings: &last3Readings)
        return reading
    }

    func initialCalibration(
        firstCalibrationBgValue: Double,
        firstCalibrationTimeStamp: Date,
        secondCalibrationBgValue: Double,
        sensor: Sensor,
        lastBgReadingsWithCalculatedValue0AndForSensor: inout [BgReading],
        deviceName: String?,
        nsManagedObjectContext: NSManagedObjectContext
    ) -> (firstCalibration: Calibration?, secondCalibration: Calibration?) {
        // Repair readings created before the factory value was preserved here.
        for reading in lastBgReadingsWithCalculatedValue0AndForSensor {
            reading.ageAdjustedRawValue = reading.rawData
        }
        let result = Sibionics2XDripCalibrator().initialCalibration(
            firstCalibrationBgValue: firstCalibrationBgValue,
            firstCalibrationTimeStamp: firstCalibrationTimeStamp,
            secondCalibrationBgValue: secondCalibrationBgValue,
            sensor: sensor,
            lastBgReadingsWithCalculatedValue0AndForSensor: &lastBgReadingsWithCalculatedValue0AndForSensor,
            deviceName: deviceName,
            nsManagedObjectContext: nsManagedObjectContext
        )
        let anchors = Self.uniqueAnchors([result.firstCalibration, result.secondCalibration].compactMap { $0 })
        for index in lastBgReadingsWithCalculatedValue0AndForSensor.indices {
            let reading = lastBgReadingsWithCalculatedValue0AndForSensor[index]
            reading.calculatedValue = Self.clampedValue(
                Sibionics2JugglucoCalibrationMath.calibratedValue(
                    reading.ageAdjustedRawValue,
                    at: max(reading.timeStamp, result.secondCalibration?.timeStamp ?? firstCalibrationTimeStamp),
                    anchors: anchors
                )
            )
            var olderReadings = Array(lastBgReadingsWithCalculatedValue0AndForSensor.dropFirst(index + 1).prefix(3))
            findSlope(for: reading, last2Readings: &olderReadings)
        }
        return result
    }

    func createNewCalibration(
        bgValue: Double,
        lastBgReading: BgReading?,
        sensor: Sensor,
        lastCalibrationsForActiveSensorInLastXDays: inout [Calibration],
        firstCalibration: Calibration,
        deviceName: String?,
        nsManagedObjectContext: NSManagedObjectContext
    ) -> Calibration? {
        guard let lastBgReading else { return nil }
        lastBgReading.ageAdjustedRawValue = lastBgReading.rawData
        guard let calibration = Sibionics2XDripCalibrator().createNewCalibration(
            bgValue: bgValue,
            lastBgReading: lastBgReading,
            sensor: sensor,
            lastCalibrationsForActiveSensorInLastXDays: &lastCalibrationsForActiveSensorInLastXDays,
            firstCalibration: firstCalibration,
            deviceName: deviceName,
            nsManagedObjectContext: nsManagedObjectContext
        ) else { return nil }

        // The xDrip calibration path already inserts the new calibration into
        // the inout history. Count each stored calibration only once.
        let anchors = Self.uniqueAnchors(
            lastCalibrationsForActiveSensorInLastXDays + [firstCalibration, calibration]
        )
        lastBgReading.calculatedValue = Self.clampedValue(
            Sibionics2JugglucoCalibrationMath.calibratedValue(
                lastBgReading.ageAdjustedRawValue,
                at: max(lastBgReading.timeStamp, calibration.timeStamp),
                anchors: anchors
            )
        )
        return calibration
    }

    private static func uniqueAnchors(_ calibrations: [Calibration]) -> [Sibionics2CalibrationAnchor] {
        var seen = Set<NSManagedObjectID>()
        return calibrations.filter { seen.insert($0.objectID).inserted }.map { anchor($0) }
    }

    private static func anchor(_ calibration: Calibration) -> Sibionics2CalibrationAnchor {
        Sibionics2CalibrationAnchor(
            sensorMgDl: calibration.estimateRawAtTimeOfCalibration > 0
                ? calibration.estimateRawAtTimeOfCalibration
                : calibration.adjustedRawValue,
            fingerstickMgDl: calibration.bg,
            timeStamp: calibration.timeStamp
        )
    }

    private static func clampedValue(_ value: Double) -> Double {
        min(
            ConstantsCalibrationAlgorithms.maximumBgReadingCalculatedValue,
            max(ConstantsCalibrationAlgorithms.minimumBgReadingCalculatedValue, value)
        )
    }
}
