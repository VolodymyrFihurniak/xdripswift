//
//  AnytimeAlgorithmTests.swift
//  xdripTests
//
//  Expected values come from running the unchanged JugglucoNG Kotlin (`AnytimeAlgorithm`,
//  `AnytimeCalibrator`) on the JVM with the same inputs. Floats are compared by bit pattern
//  (`Float.floatToIntBits` there, `bitPattern` here). Never compared with a real sensor.
//

import XCTest
@testable import xdrip

final class AnytimeAlgorithmTests: XCTestCase {

    private func fb(_ value: Float) -> String {
        return value.isNaN ? "NaN" : String(Int32(bitPattern: value.bitPattern))
    }

    private func sourceName(_ source: AnytimeAlgorithm.Source) -> String {
        switch source {
        case .native: return "NATIVE"
        case .nativePort: return "NATIVE_PORT"
        case .model: return "MODEL"
        case .linear: return "LINEAR"
        }
    }

    private func text(_ output: AnytimeAlgorithm.Output) -> String {
        return "\(output.glucoseId)/\(fb(output.mmol))/\(output.mgdlTimes10)/\(fb(output.rawMgdl))/\(sourceName(output.source))/\(output.trend)/\(output.errorCode)/\(output.warnCode)"
    }

    private func voltages(_ output: AnytimeAlgorithm.Output) -> String {
        return "\(output.beVoltageMv)/\(output.weVoltageMv)/\(output.reVoltageMv)/\(output.ceVoltageMv)/\(output.bVoltageMv)/\(output.calibrationStatus)"
    }

    private func raw(_ id: Int, _ iw: Float, _ temperature: Float) -> AnytimeRawRecord {
        return AnytimeRawRecord(indexInPacket: 0, glucoseId: id, ibNa: 0.5, iwNa: iw, temperatureC: temperature, recordBytes: [])
    }

    private let start: Int64 = 1_700_000_000_000
    private let day: Int64 = 86_400_000

    // MARK: linear fallback

    func testLinearMatchesTheKotlinFallback() {
        let iws: [Float] = [-1, 0, 0.5, 5, 12.3, 40, 400, Float.nan, Float.infinity]
        let krs: [(Float, Float)] = [(0, 0), (0.3, 50), (1.13, 70), (2.5, 120)]
        let families: [AnytimeFamily] = [.ct4, .ct3]
        let expected: [String] =
[
            "7/1074580685/396/1080452710/LINEAR/6/0/0",
            "7/1074580685/396/1080452710/LINEAR/6/0/0",
            "7/1074580685/396/1080452710/LINEAR/6/0/0",
            "7/1074580685/396/1080452710/LINEAR/6/0/0",
            "7/1074580685/396/1080452710/LINEAR/6/0/0",
            "7/1074580685/396/1080452710/LINEAR/6/0/0",
            "7/1074580685/396/1080452710/LINEAR/6/0/0",
            "7/1074580685/396/1080452710/LINEAR/6/0/0",
            "7/1074580685/396/-1057509867/LINEAR/6/0/0",
            "7/1074580685/396/-1057509867/LINEAR/6/0/0",
            "7/1074580685/396/-1057509867/LINEAR/6/0/0",
            "7/1074580685/396/-1057509867/LINEAR/6/0/0",
            "7/1074580685/396/-1044696269/LINEAR/6/0/0",
            "7/1074580685/396/-1044696269/LINEAR/6/0/0",
            "7/1074580685/396/-1044696269/LINEAR/6/0/0",
            "7/1074580685/396/-1044696269/LINEAR/6/0/0",
            "7/1074580685/396/1091567616/LINEAR/6/0/0",
            "7/1074580685/396/1091567616/LINEAR/6/0/0",
            "7/1074580685/396/1091567616/LINEAR/6/0/0",
            "7/1074580685/396/1091567616/LINEAR/6/0/0",
            "7/1074580685/396/1091567616/LINEAR/6/0/0",
            "7/1074580685/396/1091567616/LINEAR/6/0/0",
            "7/1074580685/396/1091567616/LINEAR/6/0/0",
            "7/1074580685/396/1091567616/LINEAR/6/0/0",
            "7/1074580685/396/1095342489/LINEAR/6/0/0",
            "7/1074580685/396/1095342489/LINEAR/6/0/0",
            "7/1074580685/396/1095342489/LINEAR/6/0/0",
            "7/1074580685/396/1095342489/LINEAR/6/0/0",
            "7/1074580685/396/1101843661/LINEAR/6/0/0",
            "7/1074580685/396/1101843661/LINEAR/6/0/0",
            "7/1074580685/396/1101843661/LINEAR/6/0/0",
            "7/1074580685/396/1101843661/LINEAR/6/0/0",
            "7/1074580685/396/1094398771/LINEAR/6/0/0",
            "7/1074580685/396/1094398771/LINEAR/6/0/0",
            "7/1074580685/396/1092983193/LINEAR/6/0/0",
            "7/1074580685/396/1094398771/LINEAR/6/0/0",
            "7/1074580685/396/1094398771/LINEAR/6/0/0",
            "7/1074580685/396/1094398771/LINEAR/6/0/0",
            "7/1074580685/396/1092983193/LINEAR/6/0/0",
            "7/1074580685/396/1094398771/LINEAR/6/0/0",
            "7/1074580685/396/1102457078/LINEAR/6/0/0",
            "7/1074580685/396/1102457078/LINEAR/6/0/0",
            "7/1074580685/396/1099791073/LINEAR/6/0/0",
            "7/1074580685/396/1102457078/LINEAR/6/0/0",
            "7/1075629261/441/1110468199/LINEAR/6/0/0",
            "7/1075629261/441/1110468199/LINEAR/6/0/0",
            "7/1074580685/396/1107519079/LINEAR/6/0/0",
            "7/1075629261/441/1110468199/LINEAR/6/0/0",
            "7/1074580685/396/1108344832/LINEAR/6/0/0",
            "7/1074580685/396/1108344832/LINEAR/6/0/0",
            "7/1074580685/396/1102315520/LINEAR/6/0/0",
            "7/1074580685/396/1108344832/LINEAR/6/0/0",
            "7/1074580685/396/1108344832/LINEAR/6/0/0",
            "7/1074580685/396/1108344832/LINEAR/6/0/0",
            "7/1074580685/396/1102315520/LINEAR/6/0/0",
            "7/1074580685/396/1108344832/LINEAR/6/0/0",
            "7/1087058739/1143/1122277785/LINEAR/6/0/0",
            "7/1087058739/1143/1122277785/LINEAR/6/0/0",
            "7/1080138138/635/1115540685/LINEAR/6/0/0",
            "7/1087058739/1143/1122277785/LINEAR/6/0/0",
            "7/1096495923/2466/1131846041/LINEAR/6/0/0",
            "7/1096495923/2466/1131846041/LINEAR/6/0/0",
            "7/1089365606/1341/1124473241/LINEAR/6/0/0",
            "7/1096495923/2466/1131846041/LINEAR/6/0/0",
            "7/1082528892/754/1117181708/LINEAR/6/0/0",
            "7/1082528892/754/1117181708/LINEAR/6/0/0",
            "7/1075188860/422/1109972748/LINEAR/6/0/0",
            "7/1082528892/754/1117181708/LINEAR/6/0/0",
            "7/1082528892/754/1117181708/LINEAR/6/0/0",
            "7/1082528892/754/1117181708/LINEAR/6/0/0",
            "7/1075188860/422/1109972748/LINEAR/6/0/0",
            "7/1082528892/754/1117181708/LINEAR/6/0/0",
            "7/1097438593/2628/1132684313/LINEAR/6/0/0",
            "7/1097438593/2628/1132684313/LINEAR/6/0/0",
            "7/1089783988/1377/1124708581/LINEAR/6/0/0",
            "7/1097438593/2628/1132684313/LINEAR/6/0/0",
            "7/1107270042/4000/1141884519/LINEAR/6/0/0",
            "7/1107270042/4000/1141884519/LINEAR/6/0/0",
            "7/1099209114/2984/1133849805/LINEAR/6/0/0",
            "7/1107270042/4000/1141884519/LINEAR/6/0/0",
            "7/1095237632/2250/1130430464/LINEAR/6/0/0",
            "7/1095237632/2250/1130430464/LINEAR/6/0/0",
            "7/1087373312/1170/1122631680/LINEAR/6/0/0",
            "7/1095237632/2250/1130430464/LINEAR/6/0/0",
            "7/1095237632/2250/1130430464/LINEAR/6/0/0",
            "7/1095237632/2250/1130430464/LINEAR/6/0/0",
            "7/1087373312/1170/1122631680/LINEAR/6/0/0",
            "7/1095237632/2250/1130430464/LINEAR/6/0/0",
            "7/1110940058/4000/1145998541/LINEAR/6/0/0",
            "7/1110940058/4000/1145998541/LINEAR/6/0/0",
            "7/1102734951/4000/1137816372/LINEAR/6/0/0",
            "7/1110940058/4000/1145998541/LINEAR/6/0/0",
            "7/1120560742/4000/1155773235/LINEAR/6/0/0",
            "7/1120560742/4000/1155773235/LINEAR/6/0/0",
            "7/1112329421/4000/1147561575/LINEAR/6/0/0",
            "7/1120560742/4000/1155773235/LINEAR/6/0/0",
            "7/1123090433/4000/1158123521/LINEAR/6/0/0",
            "7/1123090433/4000/1158123521/LINEAR/6/0/0",
            "7/1114767361/4000/1149771777/LINEAR/6/0/0",
            "7/1123090433/4000/1158123521/LINEAR/6/0/0",
            "7/1123090433/4000/1158123521/LINEAR/6/0/0",
            "7/1123090433/4000/1158123521/LINEAR/6/0/0",
            "7/1114767361/4000/1149771777/LINEAR/6/0/0",
            "7/1123090433/4000/1158123521/LINEAR/6/0/0",
            "7/1138907546/4000/1174316237/LINEAR/6/0/0",
            "7/1138907546/4000/1174316237/LINEAR/6/0/0",
            "7/1130541875/4000/1165953433/LINEAR/6/0/0",
            "7/1138907546/4000/1174316237/LINEAR/6/0/0",
            "7/1148865741/4000/1183632179/LINEAR/6/0/0",
            "7/1148865741/4000/1183632179/LINEAR/6/0/0",
            "7/1140496794/4000/1175254631/LINEAR/6/0/0",
            "7/1148865741/4000/1183632179/LINEAR/6/0/0",
            "7/NaN/170/NaN/LINEAR/6/0/0",
            "7/NaN/170/NaN/LINEAR/6/0/0",
            "7/NaN/170/NaN/LINEAR/6/0/0",
            "7/NaN/170/NaN/LINEAR/6/0/0",
            "7/NaN/170/NaN/LINEAR/6/0/0",
            "7/NaN/170/NaN/LINEAR/6/0/0",
            "7/NaN/170/NaN/LINEAR/6/0/0",
            "7/NaN/170/NaN/LINEAR/6/0/0",
            "7/NaN/170/NaN/LINEAR/6/0/0",
            "7/NaN/170/NaN/LINEAR/6/0/0",
            "7/NaN/170/NaN/LINEAR/6/0/0",
            "7/NaN/170/NaN/LINEAR/6/0/0",
            "7/NaN/170/NaN/LINEAR/6/0/0",
            "7/NaN/170/NaN/LINEAR/6/0/0",
            "7/NaN/170/NaN/LINEAR/6/0/0",
            "7/NaN/170/NaN/LINEAR/6/0/0",
            "7/2139095040/4000/2139095040/LINEAR/6/0/0",
            "7/2139095040/4000/2139095040/LINEAR/6/0/0",
            "7/2139095040/4000/2139095040/LINEAR/6/0/0",
            "7/2139095040/4000/2139095040/LINEAR/6/0/0",
            "7/2139095040/4000/2139095040/LINEAR/6/0/0",
            "7/2139095040/4000/2139095040/LINEAR/6/0/0",
            "7/2139095040/4000/2139095040/LINEAR/6/0/0",
            "7/2139095040/4000/2139095040/LINEAR/6/0/0",
            "7/2139095040/4000/2139095040/LINEAR/6/0/0",
            "7/2139095040/4000/2139095040/LINEAR/6/0/0",
            "7/2139095040/4000/2139095040/LINEAR/6/0/0",
            "7/2139095040/4000/2139095040/LINEAR/6/0/0",
            "7/2139095040/4000/2139095040/LINEAR/6/0/0",
            "7/2139095040/4000/2139095040/LINEAR/6/0/0",
            "7/2139095040/4000/2139095040/LINEAR/6/0/0",
            "7/2139095040/4000/2139095040/LINEAR/6/0/0"
        ]

        var index = 0
        for iw in iws {
            for (k, r) in krs {
                for flag in 0...1 {
                    for family in families {
                        let output = AnytimeAlgorithm.computeLinear(record: raw(7, iw, 33), k: k, r: r, family: family, voltageFlag: flag)
                        XCTAssertEqual(text(output), expected[index], "linear iw=\(iw) k=\(k) r=\(r) flag=\(flag) \(family)")
                        index += 1
                    }
                }
            }
        }
        XCTAssertEqual(index, expected.count)
        let noFamily = AnytimeAlgorithm.computeLinear(record: raw(7, 9, 33), k: 1, r: 60, family: nil, voltageFlag: 1)
        XCTAssertEqual(text(noFamily), "7/1092196762/1728/1127009485/LINEAR/6/0/0")
    }

    // MARK: CT-14 model (CT2)

    func testCt14ModelMatchesTheKotlinModel() {
        let iws: [Float] = [-1, 0, 3, 5.5, 8, 20, Float.nan]
        let samples: [Int64] = [start - 1000, start, start + 1, start + day / 2, start + 3 * day, start + 14 * day + 12345]
        let starts: [Int64] = [0, start]
        let rawExpected: [String] =
[
            "-1082130432",
            "-1082130432",
            "-1082130432",
            "-1082130432",
            "-1082130432",
            "-1082130432",
            "-1082130432",
            "-1085485875",
            "-1082130432",
            "1045220560",
            "-1082130432",
            "1083388843",
            "0",
            "0",
            "0",
            "0",
            "0",
            "832508583",
            "0",
            "1045220557",
            "0",
            "1067030938",
            "0",
            "1085485995",
            "1077936128",
            "1077936128",
            "1077936128",
            "1077936128",
            "1077936128",
            "1077936128",
            "1077936128",
            "1078774989",
            "1077936128",
            "1082549862",
            "1077936128",
            "1091148246",
            "1085276160",
            "1085276160",
            "1085276160",
            "1085276160",
            "1085276160",
            "1085276160",
            "1085276160",
            "1085695590",
            "1085276160",
            "1087792742",
            "1085276160",
            "1093769686",
            "1090519040",
            "1090519040",
            "1090519040",
            "1090519040",
            "1090519040",
            "1090519040",
            "1090519040",
            "1090728755",
            "1090519040",
            "1091777331",
            "1090519040",
            "1096391126",
            "1101004800",
            "1101004800",
            "1101004800",
            "1101004800",
            "1101004800",
            "1101004800",
            "1101004800",
            "1101109658",
            "1101004800",
            "1101633946",
            "1101004800",
            "1103940843",
            "NaN",
            "NaN",
            "NaN",
            "NaN",
            "NaN",
            "NaN",
            "NaN",
            "NaN",
            "NaN",
            "NaN",
            "NaN",
            "NaN"
        ]
        let fullExpected: [String] = [
            "11/1074580685/396/-1036319550/LINEAR/6/0/0",
            "11/1074580685/396/-1036319550/LINEAR/6/0/0",
            "11/1074580685/396/-1036319550/LINEAR/6/0/0",
            "11/1074580685/396/-1036319550/LINEAR/6/0/0",
            "11/1074580685/396/-1036319550/LINEAR/6/0/0",
            "11/1074580685/396/-1036319550/LINEAR/6/0/0",
            "11/1074580685/396/-1036319550/LINEAR/6/0/0",
            "11/1074580685/396/-1036885667/LINEAR/6/0/0",
            "11/1074580685/396/-1036319550/LINEAR/6/0/0",
            "11/1074580685/396/-1039716257/LINEAR/6/0/0",
            "11/1074580685/396/-1036319550/LINEAR/6/0/0",
            "11/1074580685/396/1096510472/LINEAR/6/0/0",
            "11/1074580685/396/-1039150139/LINEAR/6/0/0",
            "11/1074580685/396/-1039150139/LINEAR/6/0/0",
            "11/1074580685/396/-1039150139/LINEAR/6/0/0",
            "11/1074580685/396/-1039150139/LINEAR/6/0/0",
            "11/1074580685/396/-1039150139/LINEAR/6/0/0",
            "11/1074580685/396/-1039150139/LINEAR/6/0/0",
            "11/1074580685/396/-1039150139/LINEAR/6/0/0",
            "11/1074580685/396/-1039716257/LINEAR/6/0/0",
            "11/1074580685/396/-1039150139/LINEAR/6/0/0",
            "11/1074580685/396/-1044906300/LINEAR/6/0/0",
            "11/1074580685/396/-1039150139/LINEAR/6/0/0",
            "11/1074580685/396/1103370238/LINEAR/6/0/0",
            "11/1074580685/396/-1067184925/LINEAR/6/0/0",
            "11/1074580685/396/-1067184925/LINEAR/6/0/0",
            "11/1074580685/396/-1067184925/LINEAR/6/0/0",
            "11/1074580685/396/-1067184925/LINEAR/6/0/0",
            "11/1074580685/396/-1067184925/LINEAR/6/0/0",
            "11/1074580685/396/-1067184925/LINEAR/6/0/0",
            "11/1074580685/396/-1067184925/LINEAR/6/0/0",
            "11/1074580685/396/-1078743801/LINEAR/6/0/0",
            "11/1074580685/396/-1067184925/LINEAR/6/0/0",
            "11/1074580685/396/1091980880/LINEAR/6/0/0",
            "11/1074580685/396/-1067184925/LINEAR/6/0/0",
            "11/1078613098/569/1113825015/LINEAR/6/0/0",
            "11/1074580685/396/1102803797/LINEAR/6/0/0",
            "11/1074580685/396/1102803797/LINEAR/6/0/0",
            "11/1074580685/396/1102803797/LINEAR/6/0/0",
            "11/1074580685/396/1102803797/LINEAR/6/0/0",
            "11/1074580685/396/1102803797/LINEAR/6/0/0",
            "11/1074580685/396/1102803797/LINEAR/6/0/0",
            "11/1074580685/396/1102803797/LINEAR/6/0/0",
            "11/1074580685/396/1103936031/LINEAR/6/0/0",
            "11/1074580685/396/1102803797/LINEAR/6/0/0",
            "11/1074580685/396/1108446732/LINEAR/6/0/0",
            "11/1074580685/396/1102803797/LINEAR/6/0/0",
            "11/1083516864/839/1118293176/LINEAR/6/0/0",
            "11/1077103306/504/1112126499/LINEAR/6/0/0",
            "11/1077103306/504/1112126499/LINEAR/6/0/0",
            "11/1077103306/504/1112126499/LINEAR/6/0/0",
            "11/1077103306/504/1112126499/LINEAR/6/0/0",
            "11/1077103306/504/1112126499/LINEAR/6/0/0",
            "11/1077103306/504/1112126499/LINEAR/6/0/0",
            "11/1077103306/504/1112126499/LINEAR/6/0/0",
            "11/1077606521/526/1112692616/LINEAR/6/0/0",
            "11/1077103306/504/1112126499/LINEAR/6/0/0",
            "11/1080122600/634/1115523205/LINEAR/6/0/0",
            "11/1077103306/504/1112126499/LINEAR/6/0/0",
            "11/1086661963/1109/1121831412/LINEAR/6/0/0",
            "11/1092616192/1800/1127481344/LINEAR/6/0/0",
            "11/1092616192/1800/1127481344/LINEAR/6/0/0",
            "11/1092616192/1800/1127481344/LINEAR/6/0/0",
            "11/1092616192/1800/1127481344/LINEAR/6/0/0",
            "11/1092616192/1800/1127481344/LINEAR/6/0/0",
            "11/1092616192/1800/1127481344/LINEAR/6/0/0",
            "11/1092616192/1800/1127481344/LINEAR/6/0/0",
            "11/1092741996/1822/1127622874/LINEAR/6/0/0",
            "11/1092616192/1800/1127481344/LINEAR/6/0/0",
            "11/1093371016/1930/1128330521/LINEAR/6/0/0",
            "11/1092616192/1800/1127481344/LINEAR/6/0/0",
            "11/1096138739/2405/1131444209/LINEAR/6/0/0",
            "11/NaN/170/NaN/LINEAR/6/0/0",
            "11/NaN/170/NaN/LINEAR/6/0/0",
            "11/NaN/170/NaN/LINEAR/6/0/0",
            "11/NaN/170/NaN/LINEAR/6/0/0",
            "11/NaN/170/NaN/LINEAR/6/0/0",
            "11/NaN/170/NaN/LINEAR/6/0/0",
            "11/NaN/170/NaN/LINEAR/6/0/0",
            "11/NaN/170/NaN/LINEAR/6/0/0",
            "11/NaN/170/NaN/LINEAR/6/0/0",
            "11/NaN/170/NaN/LINEAR/6/0/0",
            "11/NaN/170/NaN/LINEAR/6/0/0",
            "11/NaN/170/NaN/LINEAR/6/0/0"
        ]

        var index = 0
        for iw in iws {
            for sample in samples {
                for sensorStart in starts {
                    XCTAssertEqual(fb(AnytimeAlgorithm.ct14RawNa(iwNa: iw, sampleTimeMs: sample, sensorStartTimeMs: sensorStart)), rawExpected[index], "raw iw=\(iw) sample=\(sample) start=\(sensorStart)")
                    let output = AnytimeAlgorithm.computeCt14(record: raw(11, iw, 31), sampleTimeMs: sample, sensorStartTimeMs: sensorStart)
                    XCTAssertEqual(text(output), fullExpected[index], "ct14 iw=\(iw) sample=\(sample) start=\(sensorStart)")
                    index += 1
                }
            }
        }
        XCTAssertEqual(index, rawExpected.count)
    }

    // MARK: transmitter computed records (CT5)

    func testComputedRecordsPassThroughTheTransmitterValue() {
        let records: [AnytimeComputedRecord] = [
            AnytimeComputedRecord(glucoseId: 300, hypoEarlyWarnMinutes: 0, hyperEarlyWarnMinutes: 0, ibNa: 0.3, iwNa: 9.4, temperatureC: 33.5, gluMmol: 6.1, referenceBgMmol: 0, errorCode: 0, trend: 3, warnCode: 0),
            AnytimeComputedRecord(glucoseId: 301, hypoEarlyWarnMinutes: 5, hyperEarlyWarnMinutes: 7, ibNa: 0.3, iwNa: 9.4, temperatureC: 33.5, gluMmol: 1.0, referenceBgMmol: 0, errorCode: 0, trend: 1, warnCode: 2),
            AnytimeComputedRecord(glucoseId: 302, hypoEarlyWarnMinutes: 0, hyperEarlyWarnMinutes: 0, ibNa: 0.3, iwNa: 9.4, temperatureC: 33.5, gluMmol: 40.0, referenceBgMmol: 0, errorCode: 4, trend: 5, warnCode: 0),
            AnytimeComputedRecord(glucoseId: 303, hypoEarlyWarnMinutes: 0, hyperEarlyWarnMinutes: 0, ibNa: 0.3, iwNa: 9.4, temperatureC: 33.5, gluMmol: 5.55, referenceBgMmol: 0, errorCode: 0, trend: 3, warnCode: 0, hasGlucose: true, beVoltageMv: 200, weVoltageMv: 600, reVoltageMv: 400, ceVoltageMv: 560, batteryRaw: 3012),
            AnytimeComputedRecord(glucoseId: 304, hypoEarlyWarnMinutes: 0, hyperEarlyWarnMinutes: 0, ibNa: 0.3, iwNa: 9.4, temperatureC: 33.5, gluMmol: Float.nan, referenceBgMmol: 0, errorCode: 0, trend: 3, warnCode: 0, hasGlucose: false)
        ]
        let calibrations: [AnytimeQrCalibration?] = [nil, AnytimeQr.ct5Default(voltageFlag: 0), AnytimeQr.ct5Default(voltageFlag: 1)]
        let expected: [String] =
[
            "300/1086534451/1100/1114573373/NATIVE/3/0/0|-2147483648/-2147483648/-2147483648/-2147483648/-2147483648/-1",
            "300/1086534451/1100/1127894221/NATIVE/3/0/0|-2147483648/-2147483648/-2147483648/-2147483648/-2147483648/-1",
            "300/1086534451/1100/1127894221/NATIVE/3/0/0|-2147483648/-2147483648/-2147483648/-2147483648/-2147483648/-1",
            "301/1065353216/180/1114573373/NATIVE/1/0/2|-2147483648/-2147483648/-2147483648/-2147483648/-2147483648/-1",
            "301/1065353216/180/1127894221/NATIVE/1/0/2|-2147483648/-2147483648/-2147483648/-2147483648/-2147483648/-1",
            "301/1065353216/180/1127894221/NATIVE/1/0/2|-2147483648/-2147483648/-2147483648/-2147483648/-2147483648/-1",
            "302/1109393408/4000/1114573373/NATIVE/5/4/0|-2147483648/-2147483648/-2147483648/-2147483648/-2147483648/-1",
            "302/1109393408/4000/1127894221/NATIVE/5/4/0|-2147483648/-2147483648/-2147483648/-2147483648/-2147483648/-1",
            "302/1109393408/4000/1127894221/NATIVE/5/4/0|-2147483648/-2147483648/-2147483648/-2147483648/-2147483648/-1",
            "303/1085381018/1000/1114573373/NATIVE/3/0/0|200/600/400/560/3012/-1",
            "303/1085381018/1000/1127894221/NATIVE/3/0/0|200/600/400/560/3012/-1",
            "303/1085381018/1000/1127894221/NATIVE/3/0/0|200/600/400/560/3012/-1",
            "304/NaN/170/1114573373/NATIVE/3/0/0|-2147483648/-2147483648/-2147483648/-2147483648/-2147483648/-1",
            "304/NaN/170/1127894221/NATIVE/3/0/0|-2147483648/-2147483648/-2147483648/-2147483648/-2147483648/-1",
            "304/NaN/170/1127894221/NATIVE/3/0/0|-2147483648/-2147483648/-2147483648/-2147483648/-2147483648/-1"
        ]

        var index = 0
        for record in records {
            for calibration in calibrations {
                let output = AnytimeAlgorithm.fromComputedRecord(record, qr: calibration, family: .ct5)
                XCTAssertEqual(text(output) + "|" + voltages(output), expected[index], "computed \(record.glucoseId) \(index)")
                index += 1
            }
        }
        XCTAssertEqual(index, expected.count)
    }

    func testReferenceBloodGlucoseAttachment() {
        let expected: [Bool] = [
false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, true, true, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, false, true, true, false, true, true, false, false, false, false, false, false, false, false, false, false, false, false, false, true, true, false, true, true, false, true, true, false, false, false]

        var index = 0
        for id in [0, 1, 5, 10] {
            for ref in [-1, 0, 1, 5, 10, 11] {
                for mgdlTimes10 in [0, 1, 99] {
                    XCTAssertEqual(AnytimeAlgorithm.shouldAttachReferenceBg(recordGlucoseId: id, referenceGlucoseId: ref, referenceMgdlTimes10: mgdlTimes10), expected[index], "attach \(id) \(ref) \(mgdlTimes10)")
                    index += 1
                }
            }
        }
        XCTAssertEqual(index, expected.count)
    }

    // MARK: MK4 calibrator

    private let ramp: [(Int, Float, Float)] = [
        (0, 3.0, 28), (1, 3.2, 29.9), (2, 3.3, 30), (3, 3.4, 31), (4, 3.5, 33),
        (5, 9.0, 34), (6, 9.5, 35), (7, 2.0, 35), (8, 2.1, 36.5), (9, 2.2, 36.5),
        (10, 0.0, 36), (11, -3.0, 36), (12, 6.0, 34), (100, 6.4, 33), (479, 6.8, 33),
        (480, 7.2, 33), (481, 7.1, 32), (600, 300, 33), (601, 7.0, 33), (602, 7.0, 33),
        (602, 7.1, 33), (5, 7.2, 33), (6, 7.3, 33)
    ]

    private func run(_ label: String, k0: Float, steps: [(Int, Float, Float)], expected: [String]) {
        let calibrator = AnytimeCalibrator(k0: k0)
        XCTAssertEqual(steps.count, expected.count, label)
        for (index, step) in steps.enumerated() {
            let value = calibrator.computeNext(raw(step.0, step.1, step.2))
            let snapshot = calibrator.snapshot()
            XCTAssertEqual("\(step.0)/\(fb(value))/\(fb(snapshot.tempSmoothPrev))/\(fb(snapshot.filteredPrev))/\(snapshot.lastGlucoseId)", expected[index], "\(label) step \(index)")
        }
    }

    func testCalibratorFollowsTheKotlinChain() {
        run("k0 1.13", k0: 1.13, steps: ramp, expected: [
            "0/1076337466/1105199104/1076337466/0",
            "1/1076205975/1106195251/1076205975/1",
            "2/1076498242/1106247680/1076498242/2",
            "3/1076715212/1106378752/1076715212/3",
            "4/1076707536/1106739200/1076707536/4",
            "5/1080066419/1107140608/1080066419/5",
            "6/1082711058/1107434496/1082711058/6",
            "7/1078164661/1107596544/1078164661/7",
            "8/1072331082/1107816384/1072331082/8",
            "9/1068940997/1107981264/1068940997/9",
            "10/0/1108072156/0/10",
            "11/-1074704818/1108140325/-1074704818/11",
            "12/-1081844673/1108060380/-1081844673/12",
            "100/-1102619493/1107934885/-1102619493/100",
            "479/1059159432/1107840764/1059159432/479",
            "480/1069043448/1107770173/1069043448/480",
            "481/1074648617/1107651694/1074648617/481",
            "600/1129340283/1107628370/1129340283/600",
            "601/1129251416/1107610878/1129251416/601",
            "602/1129162549/1107597758/1129162549/602",
            "602/1129073682/1107587918/1129073682/602",
            "5/1084322507/1107580538/1084322507/5",
            "6/1084480408/1107575004/1084480408/6"
        ])

        run("k0 1.5", k0: 1.5, steps: ramp, expected: [
            "0/1073514213/1105199104/1073514213/0",
            "1/1073316100/1106195251/1073316100/1",
            "2/1073749136/1106247680/1073749136/2",
            "3/1073912586/1106378752/1073912586/3",
            "4/1073906805/1106739200/1073906805/4",
            "5/1077060041/1107140608/1077060041/5",
            "6/1080005602/1107434496/1080005602/6",
            "7/1072657815/1107596544/1072657815/7",
            "8/1065859443/1107816384/1065859443/8",
            "9/1065986821/1107981264/1065986821/9",
            "10/0/1108072156/0/10",
            "11/-1078605659/1108140325/-1078605659/11",
            "12/-1088696911/1108060380/-1088696911/12",
            "100/1043984892/1107934885/1043984892/100",
            "479/1064438912/1107840764/1064438912/479",
            "480/1071031099/1107770173/1071031099/480",
            "481/1075192817/1107651694/1075192817/481",
            "600/1125971947/1107628370/1125971947/600",
            "601/1125853982/1107610878/1125853982/601",
            "602/1125736017/1107597758/1125736017/602",
            "602/1125618052/1107587918/1125618052/602",
            "5/1081294778/1107580538/1081294778/5",
            "6/1081532683/1107575004/1081532683/6"
        ])

        run("k0 0.8", k0: 0.8, steps: ramp, expected: [
            "0/1080868470/1105199104/1080868470/0",
            "1/1080682739/1106195251/1080682739/1",
            "2/1081095566/1106247680/1081095566/2",
            "3/1081402035/1106378752/1081402035/3",
            "4/1081391195/1106739200/1081391195/4",
            "5/1083543977/1107140608/1083543977/5",
            "6/1085290558/1107434496/1085290558/6",
            "7/1083475683/1107596544/1083475683/7",
            "8/1081190344/1107816384/1081190344/8",
            "9/1077558916/1107981264/1077558916/9",
            "10/1073926648/1108072156/1073926648/10",
            "11/1066845260/1108140325/1066845260/11",
            "12/1073631574/1108060380/1073631574/12",
            "100/1077030895/1107934885/1077030895/100",
            "479/1080318005/1107840764/1080318005/479",
            "480/1082834720/1107770173/1082834720/480",
            "481/1084349236/1107651694/1084349236/481",
            "600/1133717613/1107628370/1133717613/600",
            "601/1133686156/1107610878/1133686156/601",
            "602/1133654699/1107597758/1133654699/602",
            "602/1133623242/1107587918/1133623242/602",
            "5/1088687038/1107580538/1088687038/5",
            "6/1088910075/1107575004/1088910075/6"
        ])

        let high: [(Int, Float, Float)] = [(0, 90, 33), (1, 80, 33), (2, 80, 33), (3, 75, 33), (4, 20, 33), (5, 55, 33), (6, 56, 33), (7, 58, 33)]
        run("saturated", k0: 1.0, steps: high, expected: [
            "0/1114636288/1107558400/1114636288/0",
            "1/1115581229/1107558400/1115581229/1",
            "2/1115581229/1107558400/1115581229/2",
            "3/1115581229/1107558400/1115581229/3",
            "4/1115297851/1107558400/1115297851/4",
            "5/1115014408/1107558400/1115014408/5",
            "6/1114730899/1107558400/1114730899/6",
            "7/1114447325/1107558400/1114447325/7"
        ])

    }

    func testAutoSensitivityAndTemperatureMultiplier() {
        let ids = [-5, 0, 1, 100, 479, 480, 481, 4800, 100000]
        let expected: [String] =
[
            "1067202065",
            "1067202065",
            "1067204435",
            "1067439043",
            "1068337191",
            "1068339561",
            "1068339561",
            "1068339561",
            "1068339561"
        ]

        for (index, id) in ids.enumerated() {
            XCTAssertEqual(fb(AnytimeCalibrator(k0: 1.13).autoSensitivity(glucoseId: id)), expected[index], "id \(id)")
        }
        let temperatures: [Float] = [20, 30, 30.1, 32, 36.5, 40]
        let multipliers: [String] =
[
            "1069976681/1069976681",
            "1066123794/1066123794",
            "1066085264/1066085264",
            "1065353216/1065353216",
            "1061885617/1061885617",
            "1059188596/1059188596"
        ]

        for (index, temperature) in temperatures.enumerated() {
            let calibrator = AnytimeCalibrator(k0: 1)
            let first = calibrator.tempMultiplier(temperature)
            let second = calibrator.tempMultiplier(temperature)
            XCTAssertEqual("\(fb(first))/\(fb(second))", multipliers[index], "temperature \(temperature)")
        }
    }

    func testRestoredCalibratorContinuesLikeTheOriginal() {
        let source = AnytimeCalibrator(k0: 1.13)
        for step in ramp.prefix(8) { _ = source.computeNext(raw(step.0, step.1, step.2)) }
        let restored = AnytimeCalibrator(k0: 1.13)
        restored.restoreState(source.snapshot())
        let expected: [String] =
[
            "1072331082/1072331082",
            "1068940997/1068940997",
            "0/0",
            "-1074704818/-1074704818",
            "-1081844673/-1081844673",
            "-1102619493/-1102619493"
        ]

        for (index, step) in ramp.dropFirst(8).prefix(6).enumerated() {
            let a = source.computeNext(raw(step.0, step.1, step.2))
            let b = restored.computeNext(raw(step.0, step.1, step.2))
            XCTAssertEqual("\(fb(a))/\(fb(b))", expected[index], "step \(step.0)")
        }
    }

    func testEmptyRestoredStateStartsAFreshLimiter() {
        let calibrator = AnytimeCalibrator(k0: 1.13)
        calibrator.restoreState(AnytimeCalibrator.State(tempSmoothPrev: Float.nan, filteredPrev: Float.nan, lastGlucoseId: -1))
        XCTAssertEqual(fb(calibrator.computeNext(raw(3, 3.0, 33))), "1074206444", "restoreNaN")
        let again = AnytimeCalibrator(k0: 1.13)
        _ = again.computeNext(raw(9, 4, 33))
        again.reset()
        XCTAssertEqual("\(again.snapshot().lastGlucoseId)/\(fb(again.computeNext(raw(2, 4, 33))))", "-1/1077157521", "afterReset")
    }

    func testCalibratorStateSurvivesJSON() throws {
        let state = AnytimeCalibrator.State(tempSmoothPrev: 33.25, filteredPrev: 5.5, lastGlucoseId: 20)
        let decoded = try JSONDecoder().decode(AnytimeCalibrator.State.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
        let empty = AnytimeCalibrator.State(tempSmoothPrev: Float.nan, filteredPrev: Float.nan, lastGlucoseId: -1)
        let data = try JSONEncoder().encode(empty)
        let decodedEmpty = try JSONDecoder().decode(AnytimeCalibrator.State.self, from: data)
        XCTAssertTrue(decodedEmpty.tempSmoothPrev.isNaN)
        XCTAssertTrue(decodedEmpty.filteredPrev.isNaN)
        XCTAssertEqual(decodedEmpty.lastGlucoseId, -1)
    }

    // MARK: dispatch per family

    func testCt4SessionMatchesTheKotlinPool() {
        let calibrations: [AnytimeQrCalibration?] = [nil, AnytimeQr.ct5Default(voltageFlag: 0), AnytimeQr.ct5Default(voltageFlag: 1)]
        let expected: [String] =
[
            "0/1076337466/471/1103731098/MODEL/6/0/0",
            "1/1076205975/466/1104297329/MODEL/6/0/0",
            "2/1076498242/478/1104580444/MODEL/6/0/0",
            "3/1076715212/488/1104863561/MODEL/6/0/0",
            "4/1076707536/487/1105146676/MODEL/6/0/0",
            "5/1080066419/631/1114007143/MODEL/6/0/0",
            "6/1082711058/770/1114714932/MODEL/6/0/0",
            "7/1078164661/550/1100899943/MODEL/6/0/0",
            "8/1074580685/396/1101183058/MODEL/6/0/0",
            "9/1074580685/396/1101466174/MODEL/6/0/0",
            "10/1074580685/396/1091567616/MODEL/6/0/0",
            "11/1074580685/396/-1058642328/MODEL/6/0/0",
            "0/1076637037/484/1114526188/MODEL/6/0/0",
            "1/1076501959/478/1115564279/MODEL/6/0/0",
            "2/1076802197/491/1115884094/MODEL/6/0/0",
            "3/1077025085/501/1116143617/MODEL/6/0/0",
            "4/1077017200/501/1116403139/MODEL/6/0/0",
            "5/1080393940/645/1127375177/MODEL/6/0/0",
            "6/1082886651/785/1128023982/MODEL/6/0/0",
            "7/1078651962/571/1109335736/MODEL/6/0/0",
            "8/1074580685/396/1109854781/MODEL/6/0/0",
            "9/1074580685/396/1110373827/MODEL/6/0/0",
            "10/1074580685/396/1043878379/MODEL/6/0/0",
            "11/1074580685/396/-1033051831/MODEL/6/0/0",
            "0/1076637037/484/1106184766/MODEL/6/0/0",
            "1/1076501959/478/1107222857/MODEL/6/0/0",
            "2/1076802197/491/1107519079/MODEL/6/0/0",
            "3/1077025085/501/1107778602/MODEL/6/0/0",
            "4/1077017200/501/1108038124/MODEL/6/0/0",
            "5/1080393940/645/1118998365/MODEL/6/0/0",
            "6/1082886651/785/1119647171/MODEL/6/0/0",
            "7/1078651962/571/1100994314/MODEL/6/0/0",
            "8/1074580685/396/1101513359/MODEL/6/0/0",
            "9/1074580685/396/1102032405/MODEL/6/0/0",
            "10/1074580685/396/1043878379/MODEL/6/0/0",
            "11/1074580685/396/-1033051831/MODEL/6/0/0"
        ]

        var index = 0
        for calibration in calibrations {
            let session = AnytimeAlgorithmSession()
            for step in ramp.prefix(12) {
                let output = session.compute(record: raw(step.0, step.1, step.2), qr: calibration, family: .ct4, sampleTimeMs: start + Int64(step.0) * 180_000, sensorStartTimeMs: 0)
                XCTAssertEqual(output.map { text($0) }, expected[index], "ct4 \(index)")
                index += 1
            }
        }
        XCTAssertEqual(index, expected.count)
    }

    func testCt2SessionUsesTheCt14Model() {
        let expected: [String] =
[
            "0/1074580685/396/-1067184925/LINEAR/6/0/0",
            "1/1074580685/396/-1078819278/LINEAR/6/0/0",
            "2/1074580685/396/-1097030706/LINEAR/6/0/0",
            "3/1074580685/396/1061709974/LINEAR/6/0/0",
            "4/1074580685/396/1072664948/LINEAR/6/0/0",
            "5/1079629868/613/1114968882/LINEAR/6/0/0"
        ]

        let session = AnytimeAlgorithmSession()
        for (index, step) in ramp.prefix(6).enumerated() {
            let output = session.compute(record: raw(step.0, step.1, step.2), qr: nil, family: .ct2, sampleTimeMs: start + Int64(step.0) * 180_000, sensorStartTimeMs: start)
            XCTAssertEqual(output.map { text($0) }, expected[index], "ct2 \(index)")
        }
        XCTAssertNil(session.calibrator)
    }

    func testRestoredSessionContinuesTheCalibrator() {
        let session = AnytimeAlgorithmSession()
        session.restoreCalibrator(k0: 1.13, state: AnytimeCalibrator.State(tempSmoothPrev: 33, filteredPrev: 5.5, lastGlucoseId: 20))
        let snapshot = session.snapshotCalibrator()
        XCTAssertEqual("\(fb(snapshot?.tempSmoothPrev ?? Float.nan))/\(fb(snapshot?.filteredPrev ?? Float.nan))/\(snapshot?.lastGlucoseId ?? -99)", "1107558400/1085276160/20")
        let output = session.compute(record: raw(21, 7, 33), qr: nil, family: .ct4, sampleTimeMs: start, sensorStartTimeMs: 0)
        XCTAssertEqual(output.map { text($0) }, "21/1084070590/887/1111175988/MODEL/6/0/0")
        session.clear()
        XCTAssertNil(session.snapshotCalibrator())
        session.restoreCalibrator(k0: 0, state: AnytimeCalibrator.State(tempSmoothPrev: 33, filteredPrev: 5.5, lastGlucoseId: 20))
        XCTAssertNil(session.snapshotCalibrator(), "a zero K0 is not restorable")
    }

    func testFamiliesWithoutAValuePathPublishNothing() {
        let session = AnytimeAlgorithmSession()
        for family in [AnytimeFamily.ct25, .ct3, .ct3Plus, .ct3Yuwell, .ct3Ultrasonic, .unknown, .ct5] {
            XCTAssertNil(session.compute(record: raw(5, 8, 33), qr: AnytimeQr.ct5Default(voltageFlag: 0), family: family, sampleTimeMs: start, sensorStartTimeMs: start), "\(family)")
        }
        XCTAssertEqual(AnytimeAlgorithm.valuePath(for: .ct5), .transmitterComputed)
        XCTAssertEqual(AnytimeAlgorithm.valuePath(for: .ct2), .ct14Model)
        XCTAssertEqual(AnytimeAlgorithm.valuePath(for: .ct4), .mk4Model)
        XCTAssertEqual(AnytimeAlgorithm.valuePath(for: .ct3), .unavailable)
        XCTAssertEqual(AnytimeAlgorithm.valuePath(for: .ct25), .unavailable)
    }
}
