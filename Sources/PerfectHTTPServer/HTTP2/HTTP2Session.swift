//
//  HTTP2Session.swift
//  PerfectHTTPServer
//
//  Created by Kyle Jessup on 2017-06-20.
//
//

import PerfectNet
import PerfectLib
import PerfectThread
import PerfectHTTP

// receives notification of an unexpected network shutdown
protocol HTTP2NetErrorDelegate: class {
	func networkShutdown()
}

protocol HTTP2FrameReceiver: class {
	func receiveFrame(_ frame: HTTP2Frame)
}

// A single HTTP/2 connection handling multiple requests and responses
class HTTP2Session: Hashable, HTTP2NetErrorDelegate, HTTP2FrameReceiver {
	
	enum SessionState {
		case setup
		case active
	}
	
	private static let pinLock = Threading.Lock()
	private static var pins = Set<HTTP2Session>()
	
	static func ==(lhs: HTTP2Session, rhs: HTTP2Session) -> Bool {
		return lhs.net.fd.fd == rhs.net.fd.fd
	}
	
	var hashValue: Int { return Int(net.fd.fd) }
	
	let net: NetTCP
	let routeNavigator: RouteNavigator
	var frameReader: HTTP2FrameReader?
	var frameWriter: HTTP2FrameWriter?
	var settings = HTTP2SessionSettings()
	var state = SessionState.setup
	
	let encoder = HPACKEncoder()
	let decoder = HPACKDecoder()
	
	private let streamsLock = Threading.Lock()
	private var streams = [UInt32:HTTP2Request]()
	
	init(_ net: NetTCP, routeNavigator: RouteNavigator) {
		self.net = net
		self.routeNavigator = routeNavigator
		frameReader = HTTP2FrameReader(net, frameReceiver: self, errorDelegate: self)
		frameWriter = HTTP2FrameWriter(net, errorDelegate: self)
		pinSelf()
		sendInitialSettings()
	}
	
	deinit {
		print("~HTTP2Session")
	}
	
	private func pinSelf() {
		HTTP2Session.pinLock.lock()
		HTTP2Session.pins.insert(self)
		HTTP2Session.pinLock.unlock()
	}
	
	private func unpinSelf() {
		HTTP2Session.pinLock.lock()
		HTTP2Session.pins.remove(self)
		HTTP2Session.pinLock.unlock()
	}
	
	func sendInitialSettings() {
		let frame = HTTP2Frame(type: .settings)
		frameWriter?.enqueueFrame(frame)
	}
	
	func getRequest(_ streamId: UInt32) -> HTTP2Request? {
		streamsLock.lock()
		defer {
			streamsLock.unlock()
		}
		return streams[streamId]
	}
	
	func putRequest(_ request: HTTP2Request) {
		streamsLock.lock()
		defer {
			streamsLock.unlock()
		}
		streams[request.streamId] = request
	}
	
	func removeRequest(_ streamId: UInt32) {
		streamsLock.lock()
		defer {
			streamsLock.unlock()
		}
		streams.removeValue(forKey: streamId)
	}
	
	func networkShutdown() {
		net.shutdown()
		unpinSelf()
	}
	
	func receiveFrame(_ frame: HTTP2Frame) {
		print("frame: \(frame.type)")
		if state == .setup && frame.type != .settings {
			fatalError(error: .protocolError, msg: "Settings expected")
			return
		}
		if frame.streamId == 0 {
			switch frame.type {
			case .settings:
				settingsFrame(frame)
			case .ping:
				pingFrame(frame)
			case .goAway:
				goAwayFrame(frame)
			case .windowUpdate:
				windowUpdateFrame(frame)
			default:
				fatalError(error: .protocolError, msg: "Frame requires stream id")
			}
		} else {
			switch frame.type {
			case .headers:
				headersFrame(frame)
			case .priority:
				()
			case .cancelStream:
				()
			case .windowUpdate:
				()
			case .continuation:
				()
			default:
				fatalError(error: .protocolError, msg: "Invalid frame with stream id")
			}
		}
	}
	
	func fatalError(streamId: UInt32 = 0, error: HTTP2Error, msg: String) {
		if streamId != 0 {
			removeRequest(streamId)
		}
		let bytes = Bytes()
		bytes.import32Bits(from: UInt32(streamId).hostToNet)
			.import32Bits(from: error.rawValue.hostToNet)
			.importBytes(from: Array(msg.utf8))
		let frame = HTTP2Frame(type: HTTP2FrameType.goAway, payload: bytes.data)
		frameWriter?.enqueueFrame(frame)
		frameWriter?.waitUntilEmpty {
			self.networkShutdown()
		}
	}
	
	func settingsFrame(_ frame: HTTP2Frame) {
		let isAck = (frame.flags & flagSettingsAck) != 0
		if !isAck { // ACK settings receipt
			state = .active
			if let payload = frame.payload {
				processSettingsPayload(Bytes(existingBytes: payload))
			}
			let response = HTTP2Frame(type: HTTP2FrameType.settings,
			                          flags: flagSettingsAck)
			frameWriter?.enqueueFrame(response)
		}
	}
	
	func windowUpdateFrame(_ frame: HTTP2Frame) {
		guard let b = frame.payload, b.count == 4 else {
			return fatalError(error: .protocolError, msg: "Invalid frame")
		}
		var sid: UInt32 = UInt32(b[0])
		sid <<= 8
		sid += UInt32(b[1])
		sid <<= 8
		sid += UInt32(b[2])
		sid <<= 8
		sid += UInt32(b[3])
		sid &= ~0x80000000
		let windowSize = Int(sid.netToHost)
		frameWriter?.windowSize = windowSize
	}

	func headersFrame(_ frame: HTTP2Frame) {
		let streamId = frame.streamId
		let request = HTTP2Request(streamId, session: self)
		putRequest(request)
		request.headersFrame(frame)
	}
	
	func continuationFrame(_ frame: HTTP2Frame) {
		let streamId = frame.streamId
		guard let request = getRequest(streamId) else {
			return fatalError(error: .streamClosed, msg: "Invalid stream id")
		}
		request.continuationFrame(frame)
	}
	
	func pushPromiseFrame(_ frame: HTTP2Frame) {
		print("pushPromiseFrame")
	}
	
	func pingFrame(_ frame: HTTP2Frame) {
		print("pingFrame")
	}
	
	func goAwayFrame(_ frame: HTTP2Frame) {
		if let bytes = frame.payload {
			let b = Bytes(existingBytes: bytes)
			let lastStreamId = b.export32Bits().netToHost
			let errorCode = b.export32Bits().netToHost
			let remainingBytes = b.exportBytes(count: b.availableExportBytes)
			let errorStr = String(validatingUTF8: remainingBytes)
			print("\(lastStreamId) \(String(describing: HTTP2Error(rawValue: errorCode))) \(String(describing: errorStr))")
		}
		networkShutdown()
	}
	
	func processSettingsPayload(_ b: Bytes) {
		while b.availableExportBytes >= 6 {
			let identifier = b.export16Bits().netToHost
			let value = Int(b.export32Bits().netToHost)
			switch identifier {
			case SETTINGS_HEADER_TABLE_SIZE:
				settings.headerTableSize = Int(value)
				decoder.maxDynamicTableSize = Int(value)
			case SETTINGS_ENABLE_PUSH:
				settings.enablePush = value == 1
			case SETTINGS_MAX_CONCURRENT_STREAMS:
				settings.maxConcurrentStreams = value
			case SETTINGS_INITIAL_WINDOW_SIZE:
				settings.initialWindowSize = value
			case SETTINGS_MAX_FRAME_SIZE:
				settings.maxFrameSize = value
			case SETTINGS_MAX_HEADER_LIST_SIZE:
				settings.maxHeaderListSize = value
			default:
				()
			}
		}
	}
}
