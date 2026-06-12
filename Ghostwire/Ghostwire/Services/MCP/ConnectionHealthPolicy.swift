//
//  ConnectionHealthPolicy.swift
//  Ghostwire
//
//  GW-219: verified cross-SDK bug class — after an SSE drop/reconnect,
//  clients blast requests at an uninitialized session. Our rule: never
//  trust a wounded connection. Two consecutive failures => full teardown
//  + fresh connect(); every wake revalidates. Pure so GW-173 can reuse it.
//

import Foundation

struct ConnectionHealthPolicy: Equatable {
    enum Action: Equatable {
        case retry                 // transient; try the operation again in place
        case teardownAndReconnect  // kill transport/process, fresh connect()
        case revalidate            // ping; failure escalates to teardown
    }

    private(set) var consecutiveFailures = 0
    let teardownThreshold: Int

    init(teardownThreshold: Int = 2) {
        self.teardownThreshold = teardownThreshold
    }

    mutating func recordFailure() -> Action {
        consecutiveFailures += 1
        if consecutiveFailures >= teardownThreshold {
            consecutiveFailures = 0
            return .teardownAndReconnect
        }
        return .retry
    }

    mutating func recordSuccess() {
        consecutiveFailures = 0
    }

    func actionOnWake() -> Action {
        .revalidate
    }
}
