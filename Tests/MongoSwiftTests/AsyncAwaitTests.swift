#if compiler(>=5.5) && canImport(_Concurrency) && os(Linux)

import Foundation
@testable import MongoSwift
import Nimble
import NIO
import TestsCommon
import XCTest

/// Temporary utility function until XCTest supports `async` tests.
func testAsync(_ block: @escaping () async throws -> Void) {
    let group = DispatchGroup()
    group.enter()
    Task.detached {
        try await block()
        group.leave()
    }
    group.wait()
}

extension Task where Success == Never, Failure == Never {
    ///  Helper taken from https://www.hackingwithswift.com/quick-start/concurrency/how-to-make-a-task-sleep to support
    /// configuring with seconds rather than nanoseconds.
    static func sleep(seconds: TimeInterval) async throws {
        let duration = UInt64(seconds * 1_000_000_000)
        try await Task.sleep(nanoseconds: duration)
    }
}

/// Asserts that the provided block returns true within the specified timeout. Nimble's `toEventually` can only be used
/// rom the main testing thread which is too restrictive for our purposes testing the async/await APIs.
func assertIsEventuallyTrue(
    description: String,
    timeout: TimeInterval = 5,
    sleepInterval: TimeInterval = 0.1,
    _ block: () -> Bool
) async throws {
    let start = DispatchTime.now()
    while DispatchTime.now() < start + timeout {
        if block() {
            return
        }
        try await Task.sleep(seconds: sleepInterval)
    }
    XCTFail("Expected condition \"\(description)\" to be true within \(timeout) seconds, but was not")
}

extension MongoSwiftTestCase {
    internal func withTestClient<T>(
        _ uri: String = MongoSwiftTestCase.getConnectionString().toString(),
        options: MongoClientOptions? = nil,
        eventLoopGroup: EventLoopGroup? = nil,
        f: (MongoClient) async throws -> T
    ) async throws -> T {
        let elg = eventLoopGroup ?? MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { elg.syncShutdownOrFail() }
        let client = try MongoClient.makeTestClient(uri, eventLoopGroup: elg, options: options)
        defer { client.syncCloseOrFail() }
        return try await f(client)
    }
}

final class AsyncAwaitTests: MongoSwiftTestCase {
    func testMongoClient() throws {
        testAsync {
            let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let client = try MongoClient.makeTestClient(eventLoopGroup: elg)
            let databases = try await client.listDatabases()
            expect(databases).toNot(beEmpty())
            // We don't use `withTestClient` here so we can explicity test the `async` version of `close()``.
            try await client.close()
        }
    }

    func testClientSession() throws {
        testAsync {
            try await self.withTestClient { client in
                let dbs = try await client.withSession { session -> [DatabaseSpecification] in
                    try await client.listDatabases(session: session)
                }
                expect(dbs).toNot(beEmpty())

                // the session's connection should be back in the pool.
                try await assertIsEventuallyTrue(
                    description: "Session's underlying connection should be returned to the pool"
                ) {
                    client.connectionPool.checkedOutConnections == 0
                }

                // test session is cleaned up even if closure throws an error.
                try? await client.withSession { session in
                    _ = try await client.listDatabases(session: session)
                    throw TestError(message: "intentional error thrown from withSession closure")
                }
                try await assertIsEventuallyTrue(
                    description: "Session's underlying connection should be returned to the pool"
                ) {
                    client.connectionPool.checkedOutConnections == 0
                }

                // TODO: SWIFT-1391 once we have more API methods available, test transaction usage here.
            }
        }
    }
}

#endif
