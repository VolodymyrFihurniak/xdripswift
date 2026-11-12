//
//  InsulinPenReader.swift
//  xdrip
//
//  Reads the dose log of a NovoPen 6 / NovoPen Echo Plus over NFC, after JugglucoNG's
//  `NovoPen` package (GPL-3.0, see THIRD_PARTY_NOTICES.md), itself a modification of xDrip+'s
//  OpenNov by JamOrHam: an NFC Forum Type 4 tag carrying IEEE 11073-20601 messages in a "PHD"
//  NDEF record. The protocol is written against a transport protocol so that everything but the
//  CoreNFC session itself is plain, testable code.
//

import CoreData
import Foundation
import SwiftUI
#if canImport(CoreNFC)
import CoreNFC
#endif

// MARK: - Bytes

/// Big-endian reader over a byte array. Reading past the end throws, as ByteBuffer does.
struct PenByteReader {
    struct Underflow: Error {}

    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    var remaining: Int { bytes.count - offset }

    mutating func u8() throws -> Int {
        guard remaining >= 1 else { throw Underflow() }
        defer { offset += 1 }
        return Int(bytes[offset])
    }

    mutating func u16() throws -> Int {
        let high = try u8()
        let low = try u8()
        return high << 8 | low
    }

    mutating func u32() throws -> Int64 {
        let high = try u16()
        let low = try u16()
        return Int64(high) << 16 | Int64(low)
    }

    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, remaining >= count else { throw Underflow() }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    /// A 16-bit length followed by that many bytes.
    mutating func indexed() throws -> [UInt8] {
        let count = try u16()
        return try take(count)
    }
}

extension Array where Element == UInt8 {
    mutating func appendU16(_ value: Int) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendU32(_ value: Int64) {
        appendU16(Int(truncatingIfNeeded: value >> 16))
        appendU16(Int(truncatingIfNeeded: value))
    }

    mutating func appendIndexed(_ bytes: [UInt8]) {
        appendU16(bytes.count)
        append(contentsOf: bytes)
    }
}

// MARK: - Type 4 tag commands

/// The ISO 7816 commands of an NFC Forum Type 4 tag, as OpenNov's `T4Transceiver` sends them.
enum PenT4 {
    static let selectApplication: [UInt8] = [0x00, 0xA4, 0x04, 0x00, 0x07, 0xD2, 0x76, 0x00, 0x00, 0x85, 0x01, 0x01, 0x00]
    static let selectContainer: [UInt8] = [0x00, 0xA4, 0x00, 0x0C, 0x02, 0xE1, 0x03]
    static let selectNDEF: [UInt8] = [0x00, 0xA4, 0x00, 0x0C, 0x02, 0xE1, 0x04]
    static let containerSize = 15
    static let maximumReadSize = 255

    static func read(offset: Int, length: Int) -> [UInt8] {
        [0x00, 0xB0, UInt8(truncatingIfNeeded: offset >> 8), UInt8(truncatingIfNeeded: offset), UInt8(truncatingIfNeeded: length)]
    }

    /// One UPDATE BINARY. The first command carries the NDEF length (zero while more fragments
    /// follow); the closing command of a fragmented write only sets the real length.
    static func update(_ bytes: [UInt8], offset: Int, firstFragment: Bool, lastFragment: Bool) -> [UInt8] {
        let isFragment = offset > 0
        let hasLength = offset == 0 || firstFragment
        var command: [UInt8] = [0x00, 0xD6]
        command.appendU16(isFragment ? offset + 2 : 0)
        command.append(UInt8(truncatingIfNeeded: lastFragment ? 2 : bytes.count + (hasLength ? 2 : 0)))
        if hasLength { command.appendU16(firstFragment ? 0 : bytes.count) }
        if !lastFragment { command.append(contentsOf: bytes) }
        return command
    }

    /// The UPDATE BINARY commands that write `bytes` as the NDEF file with a tag accepting `mtu` bytes.
    static func updates(for bytes: [UInt8], mtu: Int) -> [[UInt8]] {
        let chunkSize = max(mtu - 7, 1)
        var commands: [[UInt8]] = []
        var offset = 0
        while offset < bytes.count {
            let count = min(bytes.count - offset, chunkSize)
            let chunk = Array(bytes[offset..<(offset + count)])
            commands.append(update(chunk, offset: offset, firstFragment: offset == 0 && offset + count < bytes.count, lastFragment: false))
            offset += count
        }
        if commands.count > 1 {
            commands.append(update(bytes, offset: 0, firstFragment: false, lastFragment: true))
        } else if commands.isEmpty {
            commands.append(update([], offset: 0, firstFragment: false, lastFragment: false))
        }
        return commands
    }

    /// The READ BINARY commands for `length` bytes from `offset`, at most `mtu` each.
    static func reads(offset: Int, length: Int, mtu: Int) -> [[UInt8]] {
        var commands: [[UInt8]] = []
        var position = offset
        var left = length
        while left > 0 {
            let count = min(left, max(mtu, 1))
            commands.append(read(offset: position, length: count))
            position += count
            left -= count
        }
        return commands
    }

    /// The data of a reply when its status word is 90 00.
    static func data(of reply: [UInt8]) -> [UInt8]? {
        guard reply.count >= 2, reply[reply.count - 2] == 0x90, reply[reply.count - 1] == 0x00 else { return nil }
        return Array(reply.dropLast(2))
    }
}

// MARK: - PHD link layer

/// The "PHD" NDEF record every message travels in (OpenNov `PHDll`).
struct PenPHD: Equatable {
    var sequence: Int
    var inner: [UInt8]

    private static let typeID: [UInt8] = Array("PHD".utf8)
    static let emptyNDEF: [UInt8] = [0xD0, 0x00, 0x00]

    func encode() -> [UInt8] {
        // MB | ME | SR | well-known type.
        var bytes: [UInt8] = [0xD1, UInt8(Self.typeID.count), UInt8(truncatingIfNeeded: inner.count + 1)]
        bytes.append(contentsOf: Self.typeID)
        bytes.append(UInt8(sequence & 15) | 0x80)
        bytes.append(contentsOf: inner)
        return bytes
    }

    static func parse(_ bytes: [UInt8]) -> PenPHD? {
        var reader = PenByteReader(bytes)
        do {
            let opcode = try reader.u8()
            let hasID = opcode & 0x08 != 0
            _ = try reader.u8()
            let payloadLength = try reader.u8() - 1
            let idLength = try hasID ? reader.u8() : 0
            let type = try reader.take(3)
            guard type == typeID, payloadLength >= 0 else { return nil }
            if hasID { _ = try reader.take(idLength) }
            let check = try reader.u8()
            let inner = try reader.take(payloadLength)
            return PenPHD(sequence: check & 15, inner: inner)
        } catch {
            return nil
        }
    }
}

// MARK: - IEEE 11073 messages

/// What one scan has learned from the pen so far (OpenNov `OpContext`).
struct PenContext {
    struct Association {
        var version: Int64
        var encoding: Int
        var nomenclature: Int64
        var functional: Int64
        var systemID: [UInt8]
    }

    struct Configuration {
        var id: Int
        var handle: Int
        var numberOfSegments: Int64 = -1
        var totalStoredEntries: Int64 = -1
        var unitCode: Int64 = -1

        /// International units, and a store the machine knows how to read.
        var isAsExpected: Bool { unitCode == 5472 && numberOfSegments >= 0 && totalStoredEntries >= 0 }
    }

    struct EventReport {
        var handle: Int
        var instance = -1
        var index: Int64 = -1
        var count = -1
    }

    struct Segment {
        var instance: Int
        var usage: Int64
        var isTypical: Bool
        var processed = false
    }

    /// One block of 12-byte dose records and the epoch second the pen's counter was pinned to.
    struct DoseBlock: Equatable {
        var referenceTime: Int64
        var raw: [UInt8]
    }

    var apduType: Int?
    var invokeID = -1
    var association: Association?
    var configuration: Configuration?
    var eventReport: EventReport?
    var segments: [Segment]?
    var transferAccepted: Bool?
    var serial: String?
    var doseBlocks: [DoseBlock] = []
    private(set) var referenceTime: Int64?

    /// The pen has no clock, only an uptime counter, so a dose time is "phone clock now minus
    /// counter now". It is pinned on the first report: reading the pair again for every block
    /// would land a second or two away each time and the doses of one scan would disagree.
    mutating func referenceTime(relativeTime: Int64, now: Date) -> Int64 {
        if let referenceTime { return referenceTime }
        let pinned = Int64(now.timeIntervalSince1970) - relativeTime
        referenceTime = pinned
        return pinned
    }
}

/// Parsing and building of the messages (OpenNov `Message` and its `mt` package).
enum PenMessage {
    static let associationRequest = 0xE200
    static let associationResponse = 0xE300
    static let releaseRequest = 0xE400
    static let releaseResponse = 0xE500
    static let abort = 0xE600
    static let presentation = 0xE700

    private static let apoep = 20601
    private static let confirmedEventReport = 0x0101
    private static let get = 0x0103
    private static let confirmedAction = 0x0107
    private static let responseConfirmedEventReport = 0x0201
    private static let responseGet = 0x0203
    private static let responseConfirmedAction = 0x0207
    private static let segmentGetInfo = 3085
    private static let segmentTriggerTransfer = 3100
    private static let notifyConfiguration = 3356
    private static let notifySegmentData = 3361
    private static let storeHandle = 256
    private static let attributeProductSpecification = 2349
    private static let attributeNumberOfSegments = 2385
    private static let attributeStoreUsage = 2372
    private static let attributeUnitCode = 2454
    private static let attributeSegmentMap = 2638
    private static let attributeSegmentUsage = 2427
    private static let attributeNumericObservation = 2646
    private static let attributeEnumObservation = 2662

    struct Parsed {
        var length: Int
        var invokeID = -1
        var closed = false
    }

    /// Reads one message into the context. nil when it is not an 11073 message at all.
    static func parse(_ payload: [UInt8], into context: inout PenContext, now: Date = Date()) -> Parsed? {
        var parsed = Parsed(length: payload.count)
        // An empty message is the pen saying "nothing yet"; the last APDU type stays in force.
        guard payload.count >= 4 else { return parsed }
        var reader = PenByteReader(payload)
        do {
            let type = try reader.u16()
            guard type & 0xff == 0, type >= associationRequest, type <= presentation else { return nil }
            _ = try reader.u16()
            context.apduType = type
            switch type {
            case associationRequest:
                context.association = try parseAssociation(&reader)
            case releaseResponse:
                parsed.closed = true
            case presentation:
                _ = try reader.u16()
                parsed.invokeID = try reader.u16()
                context.invokeID = parsed.invokeID
                let choice = try reader.u16()
                _ = try reader.u16()
                try parseData(choice: choice, reader: &reader, context: &context, now: now)
            default:
                break
            }
        } catch {
            // A truncated message keeps what it delivered before the cut.
        }
        return parsed
    }

    private static func parseAssociation(_ reader: inout PenByteReader) throws -> PenContext.Association? {
        _ = try reader.u32()
        let elements = try reader.u16()
        _ = try reader.u16()
        var association: PenContext.Association?
        for _ in 0..<elements {
            let proto = try reader.u16()
            let bytes = try reader.indexed()
            guard proto == apoep else { continue }
            var element = PenByteReader(bytes)
            let version = try element.u32()
            let encoding = try element.u16()
            let nomenclature = try element.u32()
            let functional = try element.u32()
            _ = try element.u32()
            let systemID = try element.indexed()
            association = PenContext.Association(version: version, encoding: encoding, nomenclature: nomenclature,
                                                 functional: functional, systemID: systemID)
        }
        return association
    }

    private static func parseData(choice: Int, reader: inout PenByteReader, context: inout PenContext, now: Date) throws {
        switch choice {
        case responseConfirmedAction:
            _ = try reader.u16()
            let action = try reader.u16()
            _ = try reader.u16()
            if action == segmentGetInfo {
                context.segments = try parseSegments(&reader)
            } else if action == segmentTriggerTransfer {
                let segment = try reader.u16()
                let response = try reader.u16()
                context.transferAccepted = segment != 0 && response == 0
            }
        case confirmedEventReport:
            let handle = try reader.u16()
            let relativeTime = try reader.u32()
            let event = try reader.u16()
            _ = try reader.u16()
            var report = PenContext.EventReport(handle: handle)
            if event == notifySegmentData {
                let reference = context.referenceTime(relativeTime: relativeTime, now: now)
                report.instance = try reader.u16()
                report.index = try reader.u32()
                report.count = try Int(reader.u32())
                _ = try reader.u16()
                _ = try reader.u16()
                let raw = try reader.take(PenDoseParser.recordSize * report.count)
                context.doseBlocks.append(PenContext.DoseBlock(referenceTime: reference, raw: raw))
                context.eventReport = report
            } else if event == notifyConfiguration {
                context.eventReport = report
                if let configuration = try parseConfiguration(&reader) { context.configuration = configuration }
            }
        case responseGet, get:
            _ = try reader.u16()
            let count = try reader.u16()
            _ = try reader.u16()
            for _ in 0..<count {
                let attribute = try parseAttribute(&reader)
                if attribute.type == attributeProductSpecification, let serial = try parseSerial(attribute.bytes) {
                    context.serial = serial
                }
            }
        default:
            break
        }
    }

    private static func parseAttribute(_ reader: inout PenByteReader) throws -> (type: Int, bytes: [UInt8], value: Int64) {
        let type = try reader.u16()
        let bytes = try reader.indexed()
        var value: Int64 = -1
        var valueReader = PenByteReader(bytes)
        if bytes.count == 4 {
            value = try valueReader.u32()
        } else if bytes.count == 2 {
            value = try Int64(valueReader.u16())
        }
        return (type, bytes, value)
    }

    private static func parseConfiguration(_ reader: inout PenByteReader) throws -> PenContext.Configuration? {
        let id = try reader.u16()
        let count = try reader.u16()
        _ = try reader.u16()
        var configuration: PenContext.Configuration?
        for _ in 0..<count {
            _ = try reader.u16()
            let handle = try reader.u16()
            let attributes = try reader.u16()
            _ = try reader.u16()
            for _ in 0..<attributes {
                var current = configuration ?? PenContext.Configuration(id: id, handle: handle)
                let attribute = try parseAttribute(&reader)
                switch attribute.type {
                case attributeNumberOfSegments: current.numberOfSegments = attribute.value
                case attributeStoreUsage: current.totalStoredEntries = attribute.value
                case attributeUnitCode: current.unitCode = attribute.value
                default: break
                }
                configuration = current
            }
        }
        return configuration
    }

    private static func parseSerial(_ bytes: [UInt8]) throws -> String? {
        var reader = PenByteReader(bytes)
        let count = try reader.u16()
        _ = try reader.u16()
        var serial: String?
        for _ in 0..<count {
            let type = try reader.u16()
            _ = try reader.u16()
            let text = try reader.indexed().filter { $0 != 0 }
            if type == 1 { serial = String(decoding: text, as: UTF8.self) }
        }
        return serial
    }

    private static func parseSegments(_ reader: inout PenByteReader) throws -> [PenContext.Segment] {
        let count = try reader.u16()
        _ = try reader.u16()
        var segments: [PenContext.Segment] = []
        for _ in 0..<count {
            let instance = try reader.u16()
            let attributes = try reader.u16()
            _ = try reader.u16()
            var usage: Int64 = -1
            var mapIsTypical = false
            for _ in 0..<attributes {
                let attribute = try parseAttribute(&reader)
                if attribute.type == attributeSegmentMap {
                    mapIsTypical = (try? segmentMapIsTypical(attribute.bytes)) ?? false
                } else if attribute.type == attributeSegmentUsage {
                    usage = attribute.value
                }
            }
            segments.append(PenContext.Segment(instance: instance, usage: usage, isTypical: usage >= 0 && mapIsTypical))
        }
        return segments
    }

    /// The layout the dose parser understands: a numeric dose, then two enumerations.
    private static func segmentMapIsTypical(_ bytes: [UInt8]) throws -> Bool {
        var reader = PenByteReader(bytes)
        _ = try reader.u16()
        let count = try reader.u16()
        _ = try reader.u16()
        var entries: [(metric: Int, object: Int, value: Int)] = []
        for _ in 0..<count {
            _ = try reader.u16()
            let metric = try reader.u16()
            let object = try reader.u16()
            _ = try reader.u16()
            _ = try reader.u16()
            let length = try reader.u16()
            var value = 0
            if length == 4 {
                value = try reader.u16()
                _ = try reader.u16()
            } else {
                _ = try reader.take(length)
            }
            entries.append((metric, object, value))
        }
        return entries.count == 3
            && entries[0].object == 13313 && entries[0].metric == 130 && entries[0].value == attributeNumericObservation
            && entries[1].object == 13314 && entries[1].metric == 130 && entries[1].value == attributeEnumObservation
            && entries[2].object == 61440 && entries[2].metric == 130 && entries[2].value == attributeEnumObservation
    }

    // Building

    private static func apdu(_ type: Int, _ payload: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.appendU16(type)
        bytes.appendIndexed(payload)
        return bytes
    }

    private static func data(invokeID: Int, choice: Int, _ payload: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.appendU16(payload.count + 6)
        bytes.appendU16(invokeID)
        bytes.appendU16(choice)
        bytes.appendIndexed(payload)
        return apdu(presentation, bytes)
    }

    /// Accepts the association as a manager, echoing the pen's own protocol parameters.
    static func associationResponse(to association: PenContext.Association) -> [UInt8] {
        var element: [UInt8] = []
        element.appendU32(association.version)
        element.appendU16(association.encoding)
        element.appendU32(association.nomenclature)
        element.appendU32(association.functional)
        element.appendU32(0x8000_0000)
        element.appendIndexed(association.systemID)
        element.appendU16(0)
        element.appendU32(0)
        element.appendU16(0)
        element.appendU16(0)
        var body: [UInt8] = []
        body.appendU16(3)
        body.appendU16(apoep)
        body.appendIndexed(element)
        return apdu(associationResponse, body)
    }

    static func acceptConfiguration(_ context: PenContext) -> [UInt8]? {
        guard let configuration = context.configuration else { return nil }
        var request: [UInt8] = []
        request.appendU16(0)
        request.appendU32(0)
        request.appendU16(notifyConfiguration)
        request.appendU16(4)
        request.appendU16(configuration.id)
        request.appendU16(0)
        return data(invokeID: context.invokeID, choice: responseConfirmedEventReport, request)
    }

    static func askInformation(_ context: PenContext) -> [UInt8]? {
        guard context.configuration != nil, let report = context.eventReport else { return nil }
        var arguments: [UInt8] = []
        arguments.appendU16(report.handle)
        arguments.appendU16(0)
        arguments.appendU16(0)
        return data(invokeID: context.invokeID, choice: get, arguments)
    }

    private static func action(_ context: PenContext, type: Int, arguments: [UInt8]) -> [UInt8]? {
        guard context.configuration != nil else { return nil }
        var body: [UInt8] = []
        body.appendU16(storeHandle)
        body.appendU16(type)
        body.appendIndexed(arguments)
        return data(invokeID: context.invokeID, choice: confirmedAction, body)
    }

    /// Asks which segments the dose store holds.
    static func askSegments(_ context: PenContext) -> [UInt8]? {
        action(context, type: segmentGetInfo, arguments: [0x00, 0x01, 0x00, 0x02, 0x00, 0x00])
    }

    static func startTransfer(_ context: PenContext, segment: Int) -> [UInt8]? {
        var arguments: [UInt8] = []
        arguments.appendU16(segment)
        return action(context, type: segmentTriggerTransfer, arguments: arguments)
    }

    /// Confirms one block of doses, which makes the pen send the next.
    static func confirmTransfer(_ context: PenContext, invokeID: Int, instance: Int, index: Int, count: Int) -> [UInt8]? {
        guard context.configuration != nil else { return nil }
        var request: [UInt8] = []
        request.appendU16(storeHandle)
        request.appendU32(0xFFFF_FFFF)
        request.appendU16(notifySegmentData)
        request.appendU16(12)
        request.appendU16(instance)
        request.appendU16(0)
        request.appendU16(index)
        request.appendU16(0)
        request.appendU16(count)
        request.append(0)
        request.append(0x80)
        return data(invokeID: invokeID, choice: responseConfirmedEventReport, request)
    }

    static let closeDown: [UInt8] = [0xE4, 0x00, 0x00, 0x02, 0x00, 0x00]
}

// MARK: - State machine

/// The conversation with the pen (OpenNov `Machine`): associate, accept the configuration, ask
/// for the serial number, list the store's segments, then pull dose blocks until done.
struct PenMachine {
    enum Step: Equatable {
        /// Write this message (possibly empty), then read the pen's answer.
        case writeRead([UInt8])
        case done
    }

    private enum State { case awaitAssociation, awaitConfiguration, askInformation, awaitInformation, awaitStorageInfo, awaitTransferConfirm, awaitLogData, awaitCloseDown }

    private static let maximumRequests = 100

    private(set) var context = PenContext()
    private var state = State.awaitAssociation
    private var requestCount = 0
    private var currentSegmentCount: Int64 = -1
    /// True when every dose of the newest block was imported before: the pen sends its newest
    /// doses first, so the rest of the log is known and the read can stop.
    var isFullyImported: (_ serial: String, _ block: PenContext.DoseBlock) -> Bool = { _, _ in false }
    var now: () -> Date = { Date() }

    mutating func process(_ payload: [UInt8]) -> Step {
        guard let message = PenMessage.parse(payload, into: &context, now: now()),
              let type = context.apduType, type != PenMessage.abort else { return .done }
        if type == PenMessage.releaseRequest { return closeDown() }

        switch state {
        case .awaitAssociation:
            guard let association = context.association, association.systemID.count == 8 else { return .done }
            state = .awaitConfiguration
            return .writeRead(PenMessage.associationResponse(to: association))
        case .awaitConfiguration:
            guard let configuration = context.configuration, configuration.isAsExpected else { return .done }
            state = .askInformation
            return step(PenMessage.acceptConfiguration(context))
        case .askInformation:
            state = .awaitInformation
            return step(PenMessage.askInformation(context))
        case .awaitInformation:
            guard context.serial != nil else { return step(PenMessage.askInformation(context)) }
            state = .awaitStorageInfo
            return step(PenMessage.askSegments(context))
        case .awaitStorageInfo:
            return nextSegment()
        case .awaitTransferConfirm:
            if message.length != 0 {
                guard context.transferAccepted == true else { return nextSegment() }
                context.transferAccepted = nil
                state = .awaitLogData
            }
            return .writeRead([])
        case .awaitLogData:
            guard message.length != 0 else { return .writeRead([]) }
            guard let report = context.eventReport else { return .done }
            if let serial = context.serial, serial.count > 3,
               report.count == 0 || context.doseBlocks.last.map({ isFullyImported(serial, $0) }) == true {
                return closeDown()
            }
            if currentSegmentCount == report.index + Int64(report.count) {
                markProcessed(report.instance)
                if context.segments?.contains(where: { !$0.processed }) == true { return nextSegment() }
            }
            return step(PenMessage.confirmTransfer(context, invokeID: message.invokeID, instance: report.instance,
                                                   index: Int(report.index), count: report.count))
        case .awaitCloseDown:
            return .done
        }
    }

    /// The read ran to its close-down rather than being cut short.
    var finishedNormally: Bool { state == .awaitCloseDown }

    private func step(_ payload: [UInt8]?) -> Step { payload.map(Step.writeRead) ?? .done }

    private mutating func closeDown() -> Step {
        state = .awaitCloseDown
        return .writeRead(PenMessage.closeDown)
    }

    private mutating func markProcessed(_ instance: Int) {
        guard let segments = context.segments else { return }
        context.segments = segments.map { segment in
            var segment = segment
            if segment.instance == instance { segment.processed = true }
            return segment
        }
    }

    private mutating func nextSegment() -> Step {
        requestCount += 1
        // A store that is not one typical segment is a pen this reader does not know.
        guard requestCount <= Self.maximumRequests, let segments = context.segments,
              segments.count == 1, segments.allSatisfy(\.isTypical) else { return .done }
        state = .awaitTransferConfirm
        guard let segment = segments.first(where: { !$0.processed }) else { return closeDown() }
        currentSegmentCount = segment.usage
        return step(PenMessage.startTransfer(context, segment: segment.instance))
    }
}

// MARK: - Session

/// Sends one command APDU and returns the reply with its two status bytes.
protocol PenTransport {
    func transceive(_ command: [UInt8]) async throws -> [UInt8]
}

/// Runs the whole read over a transport (OpenNov `OpenNov.processTag` with its link layer helpers).
struct PenSession {
    private static let maximumErrors = 3
    private static let maximumTransactions = 200
    private static let maximumRetries = 3

    let transport: PenTransport
    private var maximumRead = 0
    private var maximumWrite = 0
    private var sequence = 0
    /// True once the tag answered the NDEF application select: only then is it a pen at all.
    private(set) var spokeProtocol = false

    init(transport: PenTransport) { self.transport = transport }

    private func okay(_ command: [UInt8]) async throws -> [UInt8]? {
        PenT4.data(of: try await transport.transceive(command))
    }

    private mutating func select() async throws -> Bool {
        guard try await okay(PenT4.selectApplication) != nil else { return false }
        spokeProtocol = true
        guard try await okay(PenT4.selectContainer) != nil,
              let container = try await okay(PenT4.read(offset: 0, length: PenT4.containerSize)),
              container.count == PenT4.containerSize else { return false }
        maximumRead = Int(container[3]) << 8 | Int(container[4])
        maximumWrite = Int(container[5]) << 8 | Int(container[6])
        return try await okay(PenT4.selectNDEF) != nil
    }

    private func write(_ bytes: [UInt8]) async throws {
        for command in PenT4.updates(for: bytes, mtu: maximumWrite) {
            guard try await okay(command) != nil else { return }
        }
    }

    /// The NDEF file: its two length bytes, then the content in reads the tag allows.
    private func read() async throws -> [UInt8]? {
        attempts: for _ in 0..<Self.maximumRetries {
            guard let lengthBytes = try await okay(PenT4.read(offset: 0, length: 2)), lengthBytes.count == 2 else { continue }
            let length = Int(lengthBytes[0]) << 8 | Int(lengthBytes[1])
            var content: [UInt8] = []
            for command in PenT4.reads(offset: 2, length: length, mtu: min(PenT4.maximumReadSize, maximumRead)) {
                var part: [UInt8]?
                for retry in 0..<Self.maximumRetries {
                    if retry > 0 { try await Task.sleep(nanoseconds: 50_000_000) }
                    part = try await okay(command)
                    if part != nil { break }
                }
                guard let part else { continue attempts }
                content.append(contentsOf: part)
            }
            if content.count == length { return content }
        }
        return nil
    }

    /// Reads the pen. The machine comes back with whatever arrived, also when the tag was lost
    /// part way: the pen sends its newest doses first, so a partial read is still the useful part.
    mutating func run(machine: inout PenMachine) async {
        do {
            guard try await select() else { return }
            var errors = 0
            var transactions = 0
            while errors < Self.maximumErrors, transactions < Self.maximumTransactions {
                transactions += 1
                guard let file = try await read(), let record = PenPHD.parse(file), record.sequence == sequence else {
                    errors += 1
                    continue
                }
                // Acknowledge by emptying the NDEF file, then answer.
                try await write(PenPHD.emptyNDEF)
                guard case .writeRead(let payload) = machine.process(record.inner) else { return }
                try await write(PenPHD(sequence: sequence + 1, inner: payload).encode())
                sequence = (sequence + 2) & 0x0F
            }
        } catch {
            // Tag lost or session closed: keep what was read.
        }
    }
}

// MARK: - Doses

/// One dose of the pen's log (JugglucoNG `PenDose`).
struct PenDose: Equatable, Identifiable {
    /// The pen's own counter at the dose: its identity, the same on every scan.
    let relativeSeconds: Int64
    /// Epoch second, from the anchor this scan pinned.
    let timestampSeconds: Int64
    /// Tenths of a unit, as the pen stores the amount.
    let tenths: Int
    /// Non-zero when the pen flagged something about the dose.
    let flags: Int
    /// A small dose just before a real one: an air shot, not therapy.
    var priming = false

    var id: Int64 { relativeSeconds }
    var units: Double { Double(tenths) / 10 }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(timestampSeconds)) }
}

/// Decodes the 12-byte dose records (JugglucoNG `PenDoseParser`):
/// 0..3 relative time, 4..5 marker FF 00, 6..7 tenths of a unit, 8..10 marker 08 00 00, 11 flags.
/// A record failing a marker is skipped, never guessed at.
enum PenDoseParser {
    static let recordSize = 12
    static let maximumAgeSeconds: Int64 = 100 * 24 * 60 * 60
    private static let maximumTenths = 600
    private static let primingMaximumTenths = 20
    private static let primingWindowSeconds: Int64 = 60

    static func parse(_ block: PenContext.DoseBlock, nowSeconds: Int64) -> [PenDose] {
        var doses: [PenDose] = []
        var offset = 0
        while offset + recordSize <= block.raw.count {
            defer { offset += recordSize }
            let record = Array(block.raw[offset..<(offset + recordSize)])
            guard record[4] == 0xFF, record[5] == 0x00, record[8] == 0x08, record[9] == 0x00, record[10] == 0x00 else { continue }
            let relative = Int64(record[0]) << 24 | Int64(record[1]) << 16 | Int64(record[2]) << 8 | Int64(record[3])
            let tenths = Int(record[6]) << 8 | Int(record[7])
            guard tenths > 0, tenths <= maximumTenths else { continue }
            let timestamp = block.referenceTime + relative
            guard timestamp >= nowSeconds - maximumAgeSeconds, timestamp <= nowSeconds else { continue }
            doses.append(PenDose(relativeSeconds: relative, timestampSeconds: timestamp, tenths: tenths, flags: Int(record[11])))
        }
        return markPriming(doses.sorted { $0.timestampSeconds < $1.timestampSeconds })
    }

    /// The doses of one scan, oldest first, without the overlap between blocks.
    static func merge(_ blocks: [PenContext.DoseBlock], nowSeconds: Int64) -> [PenDose] {
        var byCounter: [Int64: PenDose] = [:]
        for block in blocks {
            for dose in parse(block, nowSeconds: nowSeconds) {
                var dose = dose
                dose.priming = false
                byCounter[dose.relativeSeconds] = dose
            }
        }
        return markPriming(byCounter.values.sorted { $0.timestampSeconds < $1.timestampSeconds })
    }

    /// Priming shots are flagged, not dropped: the review lets the person decide.
    private static func markPriming(_ sorted: [PenDose]) -> [PenDose] {
        sorted.indices.map { index in
            var dose = sorted[index]
            if index + 1 < sorted.count {
                let gap = sorted[index + 1].timestampSeconds - dose.timestampSeconds
                dose.priming = dose.tenths <= primingMaximumTenths && gap >= 0 && gap <= primingWindowSeconds
            }
            return dose
        }
    }
}

// MARK: - Known pens

/// What the app remembers about one pen between scans.
struct InsulinPen: Codable, Equatable, Identifiable {
    let serial: String
    /// `InsulinProfile` raw value; nil until chosen.
    var insulin: String?
    var addedAt: Date
    var lastScanAt: Date?
    /// The pen counter of the newest dose reviewed. Doses at or below it are not offered again.
    var cursor: Int64 = 0
    var importedCount = 0

    var id: String { serial }
    var profile: InsulinProfile? { insulin.flatMap(InsulinProfile.init(rawValue:)) }
    /// A pen filled with a basal or premixed insulin logs basal injections.
    var isBasal: Bool { profile.map(InsulinProfile.basalChoices.contains) ?? false }
}

enum InsulinPenStore {
    static let key = "experimentalInsulinPens"

    static func pens(defaults: UserDefaults = .standard) -> [InsulinPen] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([InsulinPen].self, from: data)) ?? []
    }

    static func save(_ pen: InsulinPen, defaults: UserDefaults = .standard) {
        var pens = pens(defaults: defaults).filter { $0.serial != pen.serial }
        pens.append(pen)
        if let data = try? JSONEncoder().encode(pens.sorted { $0.addedAt < $1.addedAt }) { defaults.set(data, forKey: key) }
    }

    static func remove(serial: String, defaults: UserDefaults = .standard) {
        let pens = pens(defaults: defaults).filter { $0.serial != serial }
        if let data = try? JSONEncoder().encode(pens) { defaults.set(data, forKey: key) }
    }

    static func pen(serial: String, defaults: UserDefaults = .standard) -> InsulinPen? {
        pens(defaults: defaults).first { $0.serial == serial }
    }
}

/// Decides what a scan offers for review and what an import writes.
enum InsulinPenImport {
    /// How far a logged treatment may sit from the pen dose it stands for (JugglucoNG's window).
    static let matchWindowSeconds: TimeInterval = 300

    struct Candidate: Identifiable, Equatable {
        let dose: PenDose
        /// An insulin treatment of the same size is already logged next to it.
        let alreadyLogged: Bool

        var id: Int64 { dose.id }
        /// Air shots and doses that are already in the log start unticked.
        var preselected: Bool { !dose.priming && !alreadyLogged }
    }

    /// Doses past the pen's cursor (all of them for a full read), newest first.
    static func candidates(doses: [PenDose], cursor: Int64, fullRead: Bool,
                           logged: [(date: Date, units: Double)]) -> [Candidate] {
        doses.filter { fullRead || $0.relativeSeconds > cursor }
            .sorted { $0.timestampSeconds > $1.timestampSeconds }
            .map { dose in
                Candidate(dose: dose, alreadyLogged: logged.contains { entry in
                    abs(entry.date.timeIntervalSince(dose.date)) <= matchWindowSeconds && Int((entry.units * 10).rounded()) == dose.tenths
                })
            }
    }

    /// True when every dose of the block is at or below the cursor, so nothing older is new.
    static func isFullyImported(_ block: PenContext.DoseBlock, cursor: Int64) -> Bool {
        guard cursor > 0, block.raw.count >= PenDoseParser.recordSize else { return false }
        return stride(from: 0, to: block.raw.count - PenDoseParser.recordSize + 1, by: PenDoseParser.recordSize).allSatisfy { offset in
            let relative = Int64(block.raw[offset]) << 24 | Int64(block.raw[offset + 1]) << 16
                | Int64(block.raw[offset + 2]) << 8 | Int64(block.raw[offset + 3])
            return relative <= cursor
        }
    }

    /// The notes of an imported dose: the insulin's short name, which is how a treatment names
    /// its insulin, or a plain marker for a pen whose insulin was not chosen.
    static func notes(for pen: InsulinPen) -> String? {
        pen.profile?.shortName
    }

    /// Writes the chosen doses as treatments and moves the pen's cursor past everything reviewed.
    @discardableResult
    static func write(_ doses: [PenDose], reviewed: [PenDose], pen: InsulinPen, coreDataManager: CoreDataManager,
                      defaults: UserDefaults = .standard, now: Date = Date()) -> Bool {
        let context = coreDataManager.mainManagedObjectContext
        for dose in doses {
            _ = TreatmentEntry(date: dose.date, value: dose.units,
                               treatmentType: pen.isBasal ? .BasalInjection : .Insulin,
                               nightscoutEventType: pen.isBasal ? ConstantsNightscout.noteEventType : nil,
                               enteredBy: nil, notes: notes(for: pen), nsManagedObjectContext: context)
        }
        guard doses.isEmpty || coreDataManager.saveChanges() else { return false }
        var pen = pen
        pen.cursor = max(pen.cursor, reviewed.map(\.relativeSeconds).max() ?? 0)
        pen.importedCount += doses.count
        pen.lastScanAt = now
        InsulinPenStore.save(pen, defaults: defaults)
        if !doses.isEmpty { defaults.nightscoutSyncRequired = true }
        return true
    }

    /// Insulin treatments around the scanned doses, for the "already logged" check.
    static func loggedInsulin(around doses: [PenDose], coreDataManager: CoreDataManager) -> [(date: Date, units: Double)] {
        guard let first = doses.map(\.date).min(), let last = doses.map(\.date).max() else { return [] }
        let request = TreatmentEntry.fetchRequest()
        request.predicate = NSPredicate(
            format: "date >= %@ AND date <= %@ AND (treatmentdeleted == NO OR treatmentdeleted == nil) AND treatmentType IN %@",
            first.addingTimeInterval(-matchWindowSeconds) as NSDate, last.addingTimeInterval(matchWindowSeconds) as NSDate,
            [TreatmentType.Insulin.rawValue, TreatmentType.BasalInjection.rawValue])
        let entries = (try? coreDataManager.mainManagedObjectContext.fetch(request)) ?? []
        return entries.map { (date: $0.date, units: $0.value) }
    }
}

// MARK: - CoreNFC

/// What a scan ended with.
enum InsulinPenScanResult {
    case read(serial: String, doses: [PenDose], complete: Bool)
    /// A tag answered, but it is not a pen or the read brought nothing usable.
    case failed
    case cancelled
    case unavailable
}

#if canImport(CoreNFC)
/// One NFC reader session for one pen.
final class InsulinPenScanner: NSObject, NFCTagReaderSessionDelegate {
    private struct TagTransport: PenTransport {
        let tag: NFCISO7816Tag

        func transceive(_ command: [UInt8]) async throws -> [UInt8] {
            guard let apdu = NFCISO7816APDU(data: Data(command)) else { throw PenByteReader.Underflow() }
            let (data, sw1, sw2) = try await tag.sendCommand(apdu: apdu)
            return Array(data) + [sw1, sw2]
        }
    }

    private var session: NFCTagReaderSession?
    private var continuation: CheckedContinuation<InsulinPenScanResult, Never>?
    private var cursorForSerial: (String) -> Int64 = { _ in 0 }
    private var finished = false

    static var isAvailable: Bool { NFCTagReaderSession.readingAvailable }

    /// Shows the system NFC sheet and reads the first pen held to the phone.
    /// - parameter cursor: the newest imported counter of a known pen, which lets the read stop early; 0 reads everything.
    @MainActor
    func scan(cursor: @escaping (String) -> Int64) async -> InsulinPenScanResult {
        guard NFCTagReaderSession.readingAvailable,
              let session = NFCTagReaderSession(pollingOption: [.iso14443], delegate: self, queue: .main) else { return .unavailable }
        cursorForSerial = cursor
        finished = false
        session.alertMessage = ExperimentalTexts.text("pen.hold", "Hold the top of the iPhone to the pen's dose display and keep it there until the read finishes.")
        self.session = session
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            session.begin()
        }
    }

    private func finish(_ result: InsulinPenScanResult) {
        guard !finished else { return }
        finished = true
        continuation?.resume(returning: result)
        continuation = nil
        session = nil
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        finish(.cancelled)
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let first = tags.first, case .iso7816(let tag) = first else {
            session.invalidate(errorMessage: ExperimentalTexts.text("pen.notAPen", "This is not a supported insulin pen."))
            finish(.failed)
            return
        }
        Task { @MainActor in
            do {
                try await session.connect(to: first)
            } catch {
                session.invalidate(errorMessage: ExperimentalTexts.text("pen.readFailed", "The pen could not be read. Try again and hold the phone still."))
                self.finish(.failed)
                return
            }
            var machine = PenMachine()
            let cursor = self.cursorForSerial
            machine.isFullyImported = { serial, block in InsulinPenImport.isFullyImported(block, cursor: cursor(serial)) }
            var penSession = PenSession(transport: TagTransport(tag: tag))
            await penSession.run(machine: &machine)

            let context = machine.context
            let doses = PenDoseParser.merge(context.doseBlocks, nowSeconds: Int64(Date().timeIntervalSince1970))
            if let serial = context.serial, penSession.spokeProtocol, !context.doseBlocks.isEmpty || machine.finishedNormally {
                session.alertMessage = ExperimentalTexts.text("pen.done", "Pen read.")
                session.invalidate()
                self.finish(.read(serial: serial, doses: doses, complete: machine.finishedNormally))
            } else {
                session.invalidate(errorMessage: penSession.spokeProtocol
                    ? ExperimentalTexts.text("pen.readFailed", "The pen could not be read. Try again and hold the phone still.")
                    : ExperimentalTexts.text("pen.notAPen", "This is not a supported insulin pen."))
                self.finish(.failed)
            }
        }
    }
}
#endif

// MARK: - Settings

/// The known pens, the scan button and the review of what a scan found.
struct InsulinPenSettingsView: View {
    private struct Review: Identifiable {
        let id = UUID()
        var pen: InsulinPen
        let candidates: [InsulinPenImport.Candidate]
        let complete: Bool
    }

    @State private var pens = InsulinPenStore.pens()
    @State private var fullRead = false
    @State private var isScanning = false
    @State private var message: String?
    @State private var review: Review?
    #if canImport(CoreNFC)
    @State private var scanner = InsulinPenScanner()
    #endif

    private var insulinChoices: [InsulinProfile] { InsulinProfile.perDoseBolusChoices + InsulinProfile.basalChoices }

    var body: some View {
        List {
            Section(footer: Text(ExperimentalTexts.text("pensScanFooter", "Hold the top of the iPhone against the pen's dose display until the read finishes; a long log takes several seconds. Only doses newer than the last import are offered, unless the whole log is asked for. The pen has no clock: dose times are worked out from its counter and this phone's clock at the moment of the scan."))) {
                Button {
                    Task { await scan() }
                } label: {
                    HStack {
                        Label(ExperimentalTexts.text("pensScan", "Scan a pen"), systemImage: "wave.3.right")
                        if isScanning { Spacer(); ProgressView() }
                    }
                }
                .disabled(isScanning)
                Toggle(ExperimentalTexts.text("pensFullRead", "Read the whole log next time"), isOn: $fullRead)
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
            if !pens.isEmpty {
                Section(header: Text(ExperimentalTexts.text("pensKnown", "Pens")),
                        footer: Text(ExperimentalTexts.text("pensKnownFooter", "Choose the insulin in each pen. A pen with a basal or premixed insulin logs basal injections, any other pen boluses. Removing a pen forgets what was imported from it, not the treatments."))) {
                    ForEach(pens) { pen in
                        VStack(alignment: .leading, spacing: 4) {
                            Picker(pen.serial, selection: insulinBinding(for: pen)) {
                                Text(ExperimentalTexts.text("notSet", "Not set")).tag(String?.none)
                                ForEach(insulinChoices, id: \.self) { profile in
                                    Text(profile.displayName).tag(String?.some(profile.rawValue))
                                }
                            }
                            Text(String(format: ExperimentalTexts.text("pensImported", "%d doses imported"), pen.importedCount)
                                 + (pen.lastScanAt.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { pens[$0].serial }.forEach { InsulinPenStore.remove(serial: $0) }
                        pens = InsulinPenStore.pens()
                    }
                }
            }
        }
        .navigationTitle(ExperimentalTexts.text("pens", "Insulin pens (NFC)"))
        .sheet(item: $review) { review in
            InsulinPenReviewView(pen: review.pen, candidates: review.candidates, complete: review.complete) { imported in
                pens = InsulinPenStore.pens()
                message = String(format: ExperimentalTexts.text("pensImportedNow", "%d doses added to the treatments."), imported)
            }
        }
    }

    private func insulinBinding(for pen: InsulinPen) -> Binding<String?> {
        Binding(get: { InsulinPenStore.pen(serial: pen.serial)?.insulin },
                set: { newValue in
                    guard var stored = InsulinPenStore.pen(serial: pen.serial) else { return }
                    stored.insulin = newValue
                    InsulinPenStore.save(stored)
                    pens = InsulinPenStore.pens()
                })
    }

    @MainActor
    private func scan() async {
        message = nil
        #if canImport(CoreNFC)
        isScanning = true
        let wholeLog = fullRead
        let result = await scanner.scan { serial in wholeLog ? 0 : (InsulinPenStore.pen(serial: serial)?.cursor ?? 0) }
        isScanning = false
        switch result {
        case .read(let serial, let doses, let complete):
            var pen = InsulinPenStore.pen(serial: serial) ?? InsulinPen(serial: serial, insulin: nil, addedAt: Date())
            pen.lastScanAt = Date()
            InsulinPenStore.save(pen)
            pens = InsulinPenStore.pens()
            let logged = TherapyMetricsManager.shared.configuredCoreDataManager
                .map { InsulinPenImport.loggedInsulin(around: doses, coreDataManager: $0) } ?? []
            let candidates = InsulinPenImport.candidates(doses: doses, cursor: pen.cursor, fullRead: wholeLog, logged: logged)
            fullRead = false
            if candidates.isEmpty {
                message = ExperimentalTexts.text("pensNothingNew", "No new doses on this pen.")
            } else {
                review = Review(pen: pen, candidates: candidates, complete: complete)
            }
        case .failed:
            message = ExperimentalTexts.text("pen.readFailed", "The pen could not be read. Try again and hold the phone still.")
        case .unavailable:
            message = ExperimentalTexts.text("pensUnavailable", "NFC is not available on this device.")
        case .cancelled:
            break
        }
        #else
        message = ExperimentalTexts.text("pensUnavailable", "NFC is not available on this device.")
        #endif
    }
}

/// Lets the person tick which scanned doses become treatments.
struct InsulinPenReviewView: View {
    let pen: InsulinPen
    let candidates: [InsulinPenImport.Candidate]
    let complete: Bool
    let onImported: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<Int64>
    @State private var failed = false

    init(pen: InsulinPen, candidates: [InsulinPenImport.Candidate], complete: Bool, onImported: @escaping (Int) -> Void) {
        self.pen = pen
        self.candidates = candidates
        self.complete = complete
        self.onImported = onImported
        _selected = State(initialValue: Set(candidates.filter(\.preselected).map(\.id)))
    }

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text(pen.profile?.displayName ?? pen.serial), footer: Text(footer)) {
                    ForEach(candidates) { candidate in
                        Button {
                            if selected.contains(candidate.id) { selected.remove(candidate.id) } else { selected.insert(candidate.id) }
                        } label: {
                            HStack {
                                Image(systemName: selected.contains(candidate.id) ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ChartCursorCard.units(candidate.dose.units)).foregroundStyle(ConstantsAppColors.rowTitleText)
                                    Text(candidate.dose.date.formatted(date: .abbreviated, time: .shortened) + remark(candidate))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if failed {
                    Text(ExperimentalTexts.text("pensSaveFailed", "The doses could not be saved.")).foregroundStyle(Color.red)
                }
            }
            .navigationTitle(ExperimentalTexts.text("pensReview", "Doses on the pen"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(Texts_Common.Cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(ExperimentalTexts.text("pensImport", "Add")) { add() }
                }
            }
        }
    }

    private var footer: String {
        var text = ExperimentalTexts.text("pensReviewFooter", "Ticked doses are added as treatments. Unticked doses are not offered again unless the whole log is read. A small dose within a minute before another is taken for an air shot and starts unticked, as does a dose that is already in the treatments.")
        if pen.profile == nil { text += " " + ExperimentalTexts.text("pensNoInsulin", "No insulin is chosen for this pen, so the doses are added as boluses without a named insulin.") }
        if !complete { text += " " + ExperimentalTexts.text("pensPartial", "The read was cut short: older doses may be missing. Scan again to get them.") }
        return text
    }

    private func remark(_ candidate: InsulinPenImport.Candidate) -> String {
        if candidate.dose.priming { return " · " + ExperimentalTexts.text("pensPriming", "air shot?") }
        if candidate.alreadyLogged { return " · " + ExperimentalTexts.text("pensAlreadyLogged", "already logged") }
        if candidate.dose.flags != 0 { return " · " + ExperimentalTexts.text("pensFlagged", "flagged by the pen") }
        return ""
    }

    private func add() {
        guard let coreDataManager = TherapyMetricsManager.shared.configuredCoreDataManager else { failed = true; return }
        let doses = candidates.map(\.dose).filter { selected.contains($0.id) }
        // A cut-short read may have missed doses between the cursor and what arrived, so the
        // cursor only moves when the read was complete.
        let reviewed = complete ? candidates.map(\.dose) : []
        guard InsulinPenImport.write(doses, reviewed: reviewed, pen: pen, coreDataManager: coreDataManager) else { failed = true; return }
        onImported(doses.count)
        dismiss()
    }
}
