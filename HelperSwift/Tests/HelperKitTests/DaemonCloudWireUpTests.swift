import XCTest
@testable import HelperKit

/// Phase 4E Slice 4 — integration smoke for the daemon cloud-sync
/// wiring. Assembles the same actors (`SupabaseRPCCaller`,
/// `EventUploader`, `RemoteAgentCloud`) the daemon main loop
/// constructs and drives a tick cycle through them with a stubbed
/// RPC caller. Verifies the wire-up is correct without spawning
/// the full daemon process.
final class DaemonCloudWireUpTests: XCTestCase {

    final class StubRPCCaller: RPCCallable, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [String] = []

        func call(_ rpcName: String, params: [String: Any]) async throws -> Any {
            lock.lock()
            calls.append(rpcName)
            lock.unlock()
            if rpcName == "remote_helper_pull_commands" {
                return [Any]()
            }
            return [String: Any]()
        }
    }

    private static let pairedCloud = HelperConfigStore.CloudConfig(
        deviceId: "11111111-2222-3333-4444-555555555555",
        helperSecret: "stub-secret",
        supabaseURL: "https://example.supabase.co",
        supabaseAnonKey: "stub-anon-key"
    )

    func test_paired_helper_drives_tick_through_pull_commands() async throws {
        let stub = StubRPCCaller()
        let uploader = EventUploader(
            helperConfig: { Self.pairedCloud },
            rpcCaller: stub
        )
        let manager = ManagedSessionManager(transport: PtyTransport())
        let cloud = RemoteAgentCloud(
            helperConfig: { Self.pairedCloud },
            rpcCaller: stub,
            sessionManager: manager,
            uploader: uploader,
            broker: nil
        )
        let result = await cloud.tick(maxCommands: 10)
        XCTAssertEqual(result.commandsProcessed, 0)
        XCTAssertTrue(stub.calls.contains("remote_helper_pull_commands"))
    }

    func test_unpaired_helper_skips_pull_commands_silently() async throws {
        let stub = StubRPCCaller()
        let unpaired = HelperConfigStore.CloudConfig(
            deviceId: "", helperSecret: "", supabaseURL: "", supabaseAnonKey: ""
        )
        let uploader = EventUploader(
            helperConfig: { unpaired },
            rpcCaller: stub
        )
        let manager = ManagedSessionManager(transport: PtyTransport())
        let cloud = RemoteAgentCloud(
            helperConfig: { unpaired },
            rpcCaller: stub,
            sessionManager: manager,
            uploader: uploader,
            broker: nil
        )
        let result = await cloud.tick(maxCommands: 10)
        XCTAssertEqual(result.commandsProcessed, 0)
        XCTAssertFalse(stub.calls.contains("remote_helper_pull_commands"))
    }

    func test_cloud_task_loop_is_cancellable() async throws {
        // Mirrors the daemon's cancellation path on SIGTERM.
        let stub = StubRPCCaller()
        let uploader = EventUploader(
            helperConfig: { Self.pairedCloud },
            rpcCaller: stub
        )
        let manager = ManagedSessionManager(transport: PtyTransport())
        let cloud = RemoteAgentCloud(
            helperConfig: { Self.pairedCloud },
            rpcCaller: stub,
            sessionManager: manager,
            uploader: uploader,
            broker: nil
        )
        let task = Task { [cloud, uploader] in
            while !Task.isCancelled {
                _ = await cloud.tick(maxCommands: 5)
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            _ = await uploader.flush()
            await cloud.shutdown()
        }
        // Let it run a few ticks then cancel.
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        await task.value   // should not hang
    }
}
