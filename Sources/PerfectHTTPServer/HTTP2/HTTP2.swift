//
//  HTTP2.swift
//  PerfectLib
//
//  Created by Kyle Jessup on 2016-02-18.
//  Copyright © 2016 PerfectlySoft. All rights reserved.
//
//===----------------------------------------------------------------------===//
//
// This source file is part of the Perfect.org open source project
//
// Copyright (c) 2015 - 2016 PerfectlySoft Inc. and the Perfect project authors
// Licensed under Apache License v2.0
//
// See http://perfect.org/licensing.html for license information
//
//===----------------------------------------------------------------------===//
//

let SETTINGS_HEADER_TABLE_SIZE: UInt16 = 0x1
let SETTINGS_ENABLE_PUSH: UInt16 = 0x2
let SETTINGS_MAX_CONCURRENT_STREAMS: UInt16 = 0x3
let SETTINGS_INITIAL_WINDOW_SIZE: UInt16 = 0x4
let SETTINGS_MAX_FRAME_SIZE: UInt16 = 0x5
let SETTINGS_MAX_HEADER_LIST_SIZE: UInt16 = 0x6

let http2ConnectionPreface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

enum HTTP2StreamState {
	case idle, reserved, open, halfClosed, closed
}

enum HTTP2Error: UInt32 {
	case noError = 0x0
	case protocolError = 0x1
	case internalError = 0x2
	case flowControlError = 0x3
	case settingsTimeout = 0x4
	case streamClosed = 0x5
	case frameSizeError = 0x6
	case refusedStream = 0x7
	case cancel = 0x8
	case compressionError = 0x9
	case connectError = 0xa
	case enhanceYourCalm = 0xb
	case inadequateSecurity = 0xc
	case http11Required = 0xd
}

