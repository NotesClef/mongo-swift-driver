import Foundation
@testable import MongoSwift
import Nimble
import TestsCommon
import XCTest

/// Represents a single file containing connection string tests.
private struct ConnectionStringTestFile: Decodable {
    let tests: [ConnectionStringTestCase]
}

/// Represents a single test case within a file.
private struct ConnectionStringTestCase: Decodable {
    /// A string describing the test.
    let description: String
    /// A string containing the URI to be parsed.
    let uri: String
    /// A boolean indicating if the URI should be considered valid.
    let valid: Bool
    /// A boolean indicating whether URI parsing should emit a warning
    let warning: Bool?
    /// An object containing key/value pairs for each parsed query string option.
    let options: BSONDocument?
    /// Hosts contained in the connection string.
    let hosts: [TestServerAddress]?
    /// Auth information.
    let auth: TestCredential?
}

/// Represents a host in a connection string. We can't just use ServerAddress because the port
/// may not be present.
private struct TestServerAddress: Decodable {
    /// The host.
    let host: String
    /// The port number.
    let port: UInt16?

    /// Compares the test expectation to an actual address. If a field is nil in the expectation we do not need to
    /// assert on it.
    func matches(_ address: MongoConnectionString.HostIdentifier) -> Bool {
        self.host == address.host && (self.port == nil || self.port == address.port)
    }
}

/// Represents credential data. We can't use MongoCredential directly as the coding keys don't match.
private struct TestCredential: Decodable {
    /// Username.
    let username: String?
    /// Password.
    let password: String?
    /// A string containing the authentication database.
    let db: String?

    /// Compares the test expectation to an actual credential. If a field is nil in the expectation we do not need to
    /// assert on it.
    func matches(_ credential: MongoCredential) -> Bool {
        (self.username == nil || self.username == credential.username) &&
            (self.password == nil || self.password == credential.password) &&
            (self.db == nil || self.db == credential.source)
    }
}

// Tests we skip because we don't support the specified behavior.
let skipUnsupported: [String: [String]] = [
    "valid-auth.json": ["mongodb-cr"], // we don't support MONGODB-CR authentication
    "connection-pool-options.json": [
        // we don't support maxIdleTimeMS.
        "too low maxidletimems causes a warning",
        "non-numeric maxidletimems causes a warning",
        "valid connection pool options are parsed correctly",
        // We don't support minPoolSize.
        "minpoolsize=0 does not error",
        // We don't allow maxPoolSize=0, see SWIFT-1339.
        "maxpoolsize=0 does not error"
    ],
    "connection-options.json": ["*"], // requires maxIdleTimeMS
    "compression-options.json": ["*"], // requires Snappy, see SWIFT-894
    "valid-db-with-dotted-name.json": ["*"] // libmongoc doesn't allow db names in dotted form in the URI
]

// Tests for options that are not yet supported on MongoConnectionString.
// TODO: SWIFT-1163: remove this.
let skipMongoConnectionStringUnsupported: [String: [String]] = [
    // connection string tests
    "invalid-uris.json": ["option"],
    "valid-options.json": ["*"],
    "valid-unix_socket-absolute.json": ["*"],
    "valid-unix_socket-relative.json": ["*"],
    "valid-warnings.json": ["*"],

    // URI options tests
    "concern-options.json": ["*"],
    "read-preference-options.json": ["*"],
    "single-threaded-options.json": ["*"],
    "srv-options.json": ["*"],
    "tls-options.json": ["*"]
]

func shouldSkip(file: String, test: String) -> Bool {
    if let skipList = skipUnsupported[file],
       skipList.contains(where: test.lowercased().contains) || skipList.contains("*")
    {
        return true
    }

    return false
}

func shouldSkipMongoConnectionString(file: String, test: String) -> Bool {
    if let skipList = skipMongoConnectionStringUnsupported[file],
       skipList.contains(where: test.lowercased().contains) || skipList.contains("*")
    {
        return true
    }

    return false
}

final class ConnectionStringTests: MongoSwiftTestCase {
    func runTests(_ specName: String) throws {
        let testFiles = try retrieveSpecTestFiles(specName: specName, asType: ConnectionStringTestFile.self)
        for (filename, file) in testFiles {
            for testCase in file.tests {
                guard !shouldSkip(file: filename, test: testCase.description)
                    && !shouldSkipMongoConnectionString(file: filename, test: testCase.description)
                else {
                    continue
                }

                // If the URI is invalid or is expected to emit a warning, expect an error to occur. Note that because
                // the driver does not implement logging, we throw errors where the spec indicates to log a warning.
                // TODO: SWIFT-511: revisit when we implement logging spec.
                guard testCase.valid && testCase.warning != true else {
                    expect(try MongoConnectionString(throwsIfInvalid: testCase.uri)).to(
                        throwError(
                            errorType: MongoError.InvalidArgumentError.self
                        ),
                        description: testCase.description
                    )
                    continue
                }

                let connString = try MongoConnectionString(throwsIfInvalid: testCase.uri)

                // Assert that hosts match, if present
                if let expectedHosts = testCase.hosts {
                    let actualHosts = connString.hosts
                    for expectedHost in expectedHosts {
                        guard actualHosts.contains(where: { expectedHost.matches($0) }) else {
                            XCTFail("No host found matching \(expectedHost) in host list \(actualHosts)")
                            continue
                        }
                    }
                }

                // Assert that auth matches, if present
                if let expectedAuth = testCase.auth {
                    let actual = connString.credential ?? MongoCredential()
                    guard expectedAuth.matches(actual) else {
                        XCTFail("Expected credentials: \(expectedAuth) do not match parsed credentials: \(actual)")
                        continue
                    }
                }

                if let expectedOptions = testCase.options {
                    for (key, value) in expectedOptions {
                        if key.lowercased() == "authmechanism" {
                            // authMechanism is always specified as a string in the test JSON
                            let expectedMechanism = value.stringValue!
                            guard let actualMechanism = connString.credential?.mechanism else {
                                XCTFail("Expected credential to contain authMechanism: \(testCase.description)")
                                return
                            }
                            expect(actualMechanism.description.lowercased()).to(equal(expectedMechanism.lowercased()))
                        } else if key.lowercased() == "authmechanismproperties" {
                            // authMechanismProperties is always specified as a document in the test JSON
                            let expectedProperties = value.documentValue!
                            guard let actualProperties = connString.credential?.mechanismProperties else {
                                XCTFail(
                                    "Expected credential to contain authMechanismProperties: \(testCase.description)"
                                )
                                return
                            }
                            expect(actualProperties).to(sortedEqual(expectedProperties))
                        }
                    }
                }
            }
        }
    }

    func testURIOptions() throws {
        try self.runTests("uri-options")
    }

    func testConnectionString() throws {
        try self.runTests("connection-string")
    }

    func testCodable() throws {
        let connStr = try MongoConnectionString(throwsIfInvalid: "mongodb://localhost:27017")
        let encodedData = try JSONEncoder().encode(connStr)
        let decodedResult = try JSONDecoder().decode(MongoConnectionString.self, from: encodedData)
        expect(connStr.description).to(equal(decodedResult.description))
        expect(connStr.description).to(equal("mongodb://localhost:27017"))
    }

    // TODO: Test string conversion behavior after changing to MongoConnectionString
    func testAppNameOption() throws {
        // option is set correctly from options struct
        let opts1 = MongoClientOptions(appName: "MyApp")
        let connStr1 = try ConnectionString("mongodb://localhost:27017", options: opts1)
        expect(connStr1.appName).to(equal("MyApp"))

        // option is parsed correctly from string
        let connStr2 = try ConnectionString("mongodb://localhost:27017/?appName=MyApp")
        expect(connStr2.appName).to(equal("MyApp"))

        // options struct overrides string
        let connStr3 = try ConnectionString("mongodb://localhost:27017/?appName=MyApp2", options: opts1)
        expect(connStr3.appName).to(equal("MyApp"))
    }

    // TODO: Test string conversion behavior after changing to MongoConnectionString
    func testReplSetOption() throws {
        // option is set correctly from options struct
        var opts = MongoClientOptions(replicaSet: "rs0")
        let connStr1 = try ConnectionString("mongodb://localhost:27017", options: opts)
        expect(connStr1.replicaSet).to(equal("rs0"))

        // option is parsed correctly from string
        let connStr2 = try ConnectionString("mongodb://localhost:27017/?replicaSet=rs1")
        expect(connStr2.replicaSet).to(equal("rs1"))

        // options struct overrides string
        let connStr3 = try ConnectionString("mongodb://localhost:27017/?replicaSet=rs1", options: opts)
        expect(connStr3.replicaSet).to(equal("rs0"))

        guard MongoSwiftTestCase.topologyType == .replicaSetWithPrimary else {
            print("Skipping rest of test because of unsupported topology type \(MongoSwiftTestCase.topologyType)")
            return
        }

        let testConnStr = MongoSwiftTestCase.getConnectionString()
        let rsName = testConnStr.replicaSet!

        var connStrWithoutRS = testConnStr.toString()
        connStrWithoutRS.removeSubstring("replicaSet=\(rsName)")
        // need to delete the extra & in case replicaSet was first
        connStrWithoutRS = connStrWithoutRS.replacingOccurrences(of: "?&", with: "?")
        // need to delete exta & in case replicaSet was between two options
        connStrWithoutRS = connStrWithoutRS.replacingOccurrences(of: "&&", with: "&")

        // setting actual name via options struct only should succeed in connecting
        opts.replicaSet = rsName
        try self.withTestClient(connStrWithoutRS, options: opts) { client in
            expect(try client.listDatabases().wait()).toNot(throwError())
        }

        // setting actual name via both client options and URI should succeed in connecting
        opts.replicaSet = rsName
        try self.withTestClient(testConnStr.toString(), options: opts) { client in
            expect(try client.listDatabases().wait()).toNot(throwError())
        }

        // setting to an incorrect repl set name via client options should fail to connect
        // speed up server selection timeout to fail faster
        opts.replicaSet! += "xyz"
        try self.withTestClient(testConnStr.toString() + "&serverSelectionTimeoutMS=1000", options: opts) { client in
            expect(try client.listDatabases().wait()).to(throwError())
        }
    }

    // TODO: Test string conversion behavior after changing to MongoConnectionString
    func testHeartbeatFrequencyMSOption() throws {
        // option is set correctly from options struct
        let opts = MongoClientOptions(heartbeatFrequencyMS: 50000)
        let connStr1 = try ConnectionString("mongodb://localhost:27017", options: opts)
        expect(connStr1.options?["heartbeatfrequencyms"]?.int32Value).to(equal(50000))

        // option is parsed correctly from string
        let connStr2 = try ConnectionString("mongodb://localhost:27017/?heartbeatFrequencyMS=50000")
        expect(connStr2.options?["heartbeatfrequencyms"]?.int32Value).to(equal(50000))

        // options struct overrides string
        let connStr3 = try ConnectionString("mongodb://localhost:27017/?heartbeatFrequencyMS=20000", options: opts)
        expect(connStr3.options?["heartbeatfrequencyms"]?.int32Value).to(equal(50000))

        let tooSmall = 60
        expect(try ConnectionString("mongodb://localhost:27017/?heartbeatFrequencyMS=\(tooSmall)"))
            .to(throwError(errorType: MongoError.InvalidArgumentError.self))

        expect(try ConnectionString(
            "mongodb://localhost:27017",
            options: MongoClientOptions(heartbeatFrequencyMS: tooSmall)
        )).to(throwError(errorType: MongoError.InvalidArgumentError.self))

        guard !MongoSwiftTestCase.is32Bit else {
            print("Skipping remainder of test, only supported on 64-bit platforms")
            return
        }

        let tooLarge = Int(Int32.max) + 1
        expect(try ConnectionString(
            "mongodb://localhost:27017",
            options: MongoClientOptions(heartbeatFrequencyMS: tooLarge)
        )).to(throwError(errorType: MongoError.InvalidArgumentError.self))

        expect(try ConnectionString("mongodb://localhost:27017/?heartbeatFrequencyMS=\(tooLarge)"))
            .to(throwError(errorType: MongoError.InvalidArgumentError.self))
    }

    fileprivate class HeartbeatWatcher: SDAMEventHandler {
        fileprivate var started: [Date] = []
        fileprivate var succeeded: [Date] = []

        // listen for TopologyDescriptionChanged events and continually record the latest description we've seen.
        fileprivate func handleSDAMEvent(_ event: SDAMEvent) {
            switch event {
            case .serverHeartbeatStarted:
                self.started.append(Date())
            case .serverHeartbeatSucceeded:
                self.succeeded.append(Date())
            default:
                return
            }
        }

        fileprivate init() {}
    }

    // TODO: Test string conversion behavior after changing to MongoConnectionString
    func testHeartbeatFrequencyMSWithMonitoring() throws {
        guard MongoSwiftTestCase.topologyType == .single else {
            print(unsupportedTopologyMessage(testName: self.name))
            return
        }

        let watcher = HeartbeatWatcher()

        // verify that we can speed up the heartbeat frequency
        try self.withTestClient(options: MongoClientOptions(heartbeatFrequencyMS: 2000)) { client in
            client.addSDAMEventHandler(watcher)
            _ = try client.listDatabases().wait()
            sleep(5) // sleep to allow heartbeats to occur
        }

        let succeeded = watcher.succeeded

        // the last success time should be roughly 2s after the second-to-last succeeded time.
        // we can't use started events here because streamable monitor checks begin immediately after previous
        // ones succeed. They only fire success events every heartbeatFrequencyMS though.
        let lastSuccess = succeeded.last!
        let secondToLastSuccess = succeeded[succeeded.count - 2]

        let difference = lastSuccess.timeIntervalSince1970 - secondToLastSuccess.timeIntervalSince1970
        expect(difference).to(beCloseTo(2.0, within: 0.2))
    }

    // TODO: Test string conversion behavior after changing to MongoConnectionString
    func testServerSelectionTimeoutMS() throws {
        // option is set correctly from options struct
        let opts = MongoClientOptions(serverSelectionTimeoutMS: 10000)
        let connStr1 = try ConnectionString("mongodb://localhost:27017", options: opts)
        expect(connStr1.options?["serverselectiontimeoutms"]?.int32Value).to(equal(10000))

        // option is parsed correctly from string
        let connStr2 = try ConnectionString("mongodb://localhost:27017/?serverSelectionTimeoutMS=10000")
        expect(connStr2.options?["serverselectiontimeoutms"]?.int32Value).to(equal(10000))

        // options struct overrides string
        let connStr3 = try ConnectionString("mongodb://localhost:27017/?serverSelectionTimeoutMS=5000", options: opts)
        expect(connStr3.options?["serverselectiontimeoutms"]?.int32Value).to(equal(10000))

        let tooSmall = 0

        expect(try ConnectionString(
            "mongodb://localhost:27017",
            options: MongoClientOptions(serverSelectionTimeoutMS: tooSmall)
        )).to(throwError(errorType: MongoError.InvalidArgumentError.self))
        expect(try ConnectionString(
            "mongodb://localhost:27017/?serverSelectionTimeoutMS=\(tooSmall)"
        )).to(throwError(errorType: MongoError.InvalidArgumentError.self))

        guard !MongoSwiftTestCase.is32Bit else {
            print("Skipping remainder of test, only supported on 64-bit platforms")
            return
        }

        let tooLarge = Int(Int32.max) + 1
        expect(try ConnectionString("mongodb://localhost:27017/?serverSelectionTimeoutMS=\(tooLarge)"))
            .to(throwError(errorType: MongoError.InvalidArgumentError.self))

        expect(try ConnectionString(
            "mongodb://localhost:27017",
            options: MongoClientOptions(serverSelectionTimeoutMS: tooLarge)
        )).to(throwError(errorType: MongoError.InvalidArgumentError.self))
    }

    // TODO: Test string conversion behavior after changing to MongoConnectionString
    func testServerSelectionTimeoutMSWithCommand() throws {
        let opts = MongoClientOptions(serverSelectionTimeoutMS: 1000)
        try self.withTestClient("mongodb://localhost:27099", options: opts) { client in
            let start = Date()
            expect(try client.listDatabases().wait()).to(throwError(errorType: MongoError.ServerSelectionError.self))
            let end = Date()

            let difference = end.timeIntervalSince1970 - start.timeIntervalSince1970
            expect(difference).to(beCloseTo(1.0, within: 0.2))
        }
    }

    // TODO: Test string conversion behavior after changing to MongoConnectionString
    func testLocalThresholdMSOption() throws {
        // option is set correctly from options struct
        let opts = MongoClientOptions(localThresholdMS: 100)
        let connStr1 = try ConnectionString("mongodb://localhost:27017", options: opts)
        expect(connStr1.options?["localthresholdms"]?.int32Value).to(equal(100))

        // option is parsed correctly from string
        let connStr2 = try ConnectionString("mongodb://localhost:27017/?localThresholdMS=100")
        expect(connStr2.options?["localthresholdms"]?.int32Value).to(equal(100))

        // options struct overrides string
        let connStr3 = try ConnectionString("mongodb://localhost:27017/?localThresholdMS=50", options: opts)
        expect(connStr3.options?["localthresholdms"]?.int32Value).to(equal(100))

        let tooSmall = -10
        expect(try ConnectionString(
            "mongodb://localhost:27017",
            options: MongoClientOptions(localThresholdMS: tooSmall)
        )).to(throwError(errorType: MongoError.InvalidArgumentError.self))

        expect(try ConnectionString(
            "mongodb://localhost:27017/?localThresholdMS=\(tooSmall)"
        )).to(throwError(errorType: MongoError.InvalidArgumentError.self))

        guard !MongoSwiftTestCase.is32Bit else {
            print("Skipping remainder of test, requires 64-bit platform")
            return
        }

        let tooLarge = Int(Int32.max) + 1
        expect(try ConnectionString("mongodb://localhost:27017/?localThresholdMS=\(tooLarge)"))
            .to(throwError(errorType: MongoError.InvalidArgumentError.self))
        expect(try ConnectionString(
            "mongodb://localhost:27017",
            options: MongoClientOptions(localThresholdMS: tooLarge)
        )).to(throwError(errorType: MongoError.InvalidArgumentError.self))
    }

    // TODO: Test string conversion behavior after changing to MongoConnectionString
    func testConnectTimeoutMSOption() throws {
        // option is set correctly from options struct
        let opts = MongoClientOptions(connectTimeoutMS: 100)
        let connStr1 = try ConnectionString("mongodb://localhost:27017", options: opts)
        expect(connStr1.options?["connecttimeoutms"]?.int32Value).to(equal(100))

        // option is parsed correctly from string
        let connStr2 = try ConnectionString("mongodb://localhost:27017/?connectTimeoutMS=100")
        expect(connStr2.options?["connecttimeoutms"]?.int32Value).to(equal(100))

        // options struct overrides string
        let connStr3 = try ConnectionString("mongodb://localhost:27017/?connectTimeoutMS=50", options: opts)
        expect(connStr3.options?["connecttimeoutms"]?.int32Value).to(equal(100))

        // test invalid options
        expect(try ConnectionString(
            "mongodb://localhost:27017",
            options: MongoClientOptions(connectTimeoutMS: 0)
        )).to(throwError(errorType: MongoError.InvalidArgumentError.self))

        expect(try ConnectionString(
            "mongodb://localhost:27017/?connectTimeoutMS=0"
        )).to(throwError(errorType: MongoError.InvalidArgumentError.self))

        let tooSmall = -10
        expect(try ConnectionString(
            "mongodb://localhost:27017",
            options: MongoClientOptions(connectTimeoutMS: tooSmall)
        )).to(throwError(errorType: MongoError.InvalidArgumentError.self))

        expect(try ConnectionString(
            "mongodb://localhost:27017/?connectTimeoutMS=\(tooSmall)"
        )).to(throwError(errorType: MongoError.InvalidArgumentError.self))

        guard !MongoSwiftTestCase.is32Bit else {
            print("Skipping remainder of test, requires 64-bit platform")
            return
        }

        let tooLarge = Int(Int32.max) + 1
        expect(try ConnectionString("mongodb://localhost:27017/?connectTimeoutMS=\(tooLarge)"))
            .to(throwError(errorType: MongoError.InvalidArgumentError.self))
        expect(try ConnectionString(
            "mongodb://localhost:27017",
            options: MongoClientOptions(connectTimeoutMS: tooLarge)
        )).to(throwError(errorType: MongoError.InvalidArgumentError.self))
    }

    // TODO: Test string conversion behavior after changing to MongoConnectionString
    func testUnsupportedOptions() throws {
        // options we know of but don't support yet should throw errors
        expect(try ConnectionString("mongodb://localhost:27017/?minPoolSize=10"))
            .to(throwError(errorType: MongoError.InvalidArgumentError.self))
        expect(try ConnectionString("mongodb://localhost:27017/?maxIdleTimeMS=10"))
            .to(throwError(errorType: MongoError.InvalidArgumentError.self))
        expect(try ConnectionString("mongodb://localhost:27017/?waitQueueMultiple=10"))
            .to(throwError(errorType: MongoError.InvalidArgumentError.self))
        expect(try ConnectionString("mongodb://localhost:27017/?waitQueueTimeoutMS=10"))
            .to(throwError(errorType: MongoError.InvalidArgumentError.self))

        // options we don't know of should be ignored
        expect(try ConnectionString("mongodb://localhost:27017/?blah=10")).toNot(throwError())
    }

    // TODO: Test string conversion behavior after changing to MongoConnectionString
    func testCompressionOptions() throws {
        // zlib level validation
        expect(try Compressor.zlib(level: -2)).to(throwError(errorType: MongoError.InvalidArgumentError.self))
        expect(try Compressor.zlib(level: 10)).to(throwError(errorType: MongoError.InvalidArgumentError.self))
        expect(try Compressor.zlib(level: -1)).toNot(throwError())
        expect(try Compressor.zlib(level: 9)).toNot(throwError())

        // options are set correctly from options struct
        var opts = MongoClientOptions()
        opts.compressors = [.zlib]
        var connStr = try ConnectionString("mongodb://localhost:27017", options: opts)
        expect(connStr.compressors).to(equal(["zlib"]))

        opts.compressors = [try .zlib(level: 6)]
        connStr = try ConnectionString("mongodb://localhost:27017", options: opts)
        expect(connStr.compressors).to(equal(["zlib"]))
        expect(connStr.options?["zlibcompressionlevel"]?.int32Value).to(equal(6))

        // options parsed correctly from string
        connStr = try ConnectionString("mongodb://localhost:27017/?compressors=zlib&zlibcompressionlevel=6")
        expect(connStr.compressors).to(equal(["zlib"]))
        expect(connStr.options?["zlibcompressionlevel"]?.int32Value).to(equal(6))

        // options struct overrides string
        opts.compressors = []
        connStr = try ConnectionString("mongodb://localhost:27017/?compressors=zlib", options: opts)
        expect(connStr.compressors).to(beEmpty())

        opts.compressors = [try .zlib(level: 6)]
        connStr = try ConnectionString(
            "mongodb://localhost:27017/?compressors=zlib&zlibcompressionlevel=4",
            options: opts
        )
        expect(connStr.compressors).to(equal(["zlib"]))
        expect(connStr.options?["zlibcompressionlevel"]?.int32Value).to(equal(6))

        // duplicate compressors should error
        opts.compressors = [.zlib, try .zlib(level: 1)]
        expect(try ConnectionString("mongodb://localhost:27017", options: opts))
            .to(throwError(errorType: MongoError.InvalidArgumentError.self))

        // unfortunately, we can't error on an unsupported compressor provided via URI. libmongoc will generate a
        // warning but does not provide us access to the see the full specified list.
    }

    // TODO: Test string conversion behavior after changing to MongoConnectionString
    func testInvalidOptionsCombinations() throws {
        // tlsInsecure and conflicting options
        var opts = MongoClientOptions(tlsAllowInvalidCertificates: true, tlsInsecure: true)
        expect(try ConnectionString("mongodb://localhost:27017", options: opts))
            .to(throwError(errorType: MongoError.InvalidArgumentError.self))

        opts = MongoClientOptions(tlsAllowInvalidHostnames: true, tlsInsecure: true)
        expect(try ConnectionString("mongodb://localhost:27017", options: opts))
            .to(throwError(errorType: MongoError.InvalidArgumentError.self))

        // one in URI, one in options struct
        opts = MongoClientOptions(tlsAllowInvalidCertificates: true)
        expect(try ConnectionString("mongodb://localhost:27017/?tlsInsecure=true", options: opts))
            .to(throwError(errorType: MongoError.InvalidArgumentError.self))

        opts = MongoClientOptions(tlsAllowInvalidHostnames: true)
        expect(try ConnectionString("mongodb://localhost:27017/?tlsInsecure=true", options: opts))
            .to(throwError(errorType: MongoError.InvalidArgumentError.self))

        opts = MongoClientOptions(tlsInsecure: true)
        expect(try ConnectionString("mongodb://localhost:27017/?tlsAllowInvalidHostnames=true", options: opts))
            .to(throwError(errorType: MongoError.InvalidArgumentError.self))
        expect(try ConnectionString("mongodb://localhost:27017/?tlsAllowInvalidCertificates=true", options: opts))
            .to(throwError(errorType: MongoError.InvalidArgumentError.self))

        // directConnection cannot be used with SRV URIs
        opts = MongoClientOptions(directConnection: true)
        expect(try ConnectionString("mongodb+srv://test3.test.build.10gen.cc", options: opts))
            .to(throwError(errorType: MongoError.InvalidArgumentError.self))

        // directConnection=true cannot be used with multiple seeds
        expect(try ConnectionString("mongodb://localhost:27017,localhost:27018", options: opts))
            .to(throwError(errorType: MongoError.InvalidArgumentError.self))

        // The cases where the conflicting options are all in the connection string are already covered by the URI
        // options tests, so here we only check behavior for cases where 1+ option is specified via the options struct.

        // loadBalanced=true cannot be used with multiple seeds
        opts = MongoClientOptions(loadBalanced: true)
        expect(try ConnectionString("mongodb://localhost:27017,localhost:27018", options: opts))
            .to(throwError(errorType: MongoError.InvalidArgumentError.self))

        // loadBalanced=true cannot be used with replica set option
        expect(try ConnectionString("mongodb://localhost:27017/?replicaSet=xyz", options: opts))
            .to(throwError(errorType: MongoError.InvalidArgumentError.self))
        opts.replicaSet = "xyz"
        expect(try ConnectionString("mongodb://localhost:27017", options: opts))
            .to(throwError(errorType: MongoError.InvalidArgumentError.self))

        // loadBalanced=true cannot be used with directConnection=true
        opts = MongoClientOptions(directConnection: true, loadBalanced: true)
        expect(try ConnectionString("mongodb://localhost:27017", options: opts))
            .to(throwError(errorType: MongoError.InvalidArgumentError.self))

        opts = MongoClientOptions(directConnection: true)
        expect(try ConnectionString("mongodb://localhost:27017/?loadBalanced=true", options: opts))
            .to(throwError(errorType: MongoError.InvalidArgumentError.self))

        opts = MongoClientOptions(loadBalanced: true)
        expect(try ConnectionString("mongodb://localhost:27017/?directConnection=true", options: opts))
            .to(throwError(errorType: MongoError.InvalidArgumentError.self))
    }
}
