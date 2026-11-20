import XCTest
@testable import GPUWatchCore

final class SSHTargetTests: XCTestCase {

    // MARK: - Injection defence

    func testDestinationStartingWithDashIsRejected() {
        let host = Fixtures.host(destination: "-oProxyCommand=touch /tmp/pwned")
        XCTAssertThrowsError(try SSHTarget.make(from: host)) { error in
            guard let validation = error as? SSHTarget.ValidationError else {
                return XCTFail("expected a validation error, got \(error)")
            }
            XCTAssertEqual(validation.field, .destination)
            XCTAssertTrue(validation.reason.contains("'-'"))
        }
    }

    func testUsernameStartingWithDashIsRejected() {
        let host = Fixtures.host(username: "-oProxyCommand=evil")
        XCTAssertThrowsError(try SSHTarget.make(from: host))
    }

    func testPortOutsideRangeIsRejected() {
        XCTAssertThrowsError(try SSHTarget.make(from: Fixtures.host(port: 0)))
        XCTAssertThrowsError(try SSHTarget.make(from: Fixtures.host(port: 70000)))
        XCTAssertThrowsError(try SSHTarget.make(from: Fixtures.host(port: -22)))
    }

    func testIdentityFileMustBeAnAbsolutePath() {
        XCTAssertThrowsError(try SSHTarget.make(from: Fixtures.host(identityFile: "keys/id_rsa")))
    }

    func testIdentityFileStartingWithDashIsRejected() {
        XCTAssertThrowsError(try SSHTarget.make(from: Fixtures.host(identityFile: "-bad")))
    }

    func testShellMetacharactersInDestinationAreRejected() {
        for bad in ["host; rm -rf /", "host$(whoami)", "host`id`", "host && echo", "ho st"] {
            XCTAssertThrowsError(
                try SSHTarget.make(from: Fixtures.host(destination: bad)),
                "\(bad) must be rejected"
            )
        }
    }

    func testEmptyDestinationIsRejected() {
        XCTAssertThrowsError(try SSHTarget.make(from: Fixtures.host(destination: "   ")))
    }

    // MARK: - Accepted forms

    func testSSHConfigAliasIsAccepted() throws {
        let target = try SSHTarget.make(from: Fixtures.host(destination: "dgx-prod-01"))
        XCTAssertEqual(target.destination, "dgx-prod-01")
    }

    func testIPv4AndIPv6LiteralsAreAccepted() throws {
        // 192.0.2.0/24 is reserved for documentation (RFC 5737), so this
        // fixture cannot collide with anyone's real network.
        XCTAssertEqual(
            try SSHTarget.make(from: Fixtures.host(destination: "192.0.2.12")).destination,
            "192.0.2.12"
        )
        XCTAssertEqual(
            try SSHTarget.make(from: Fixtures.host(destination: "[fe80::1%en0]")).destination,
            "[fe80::1%en0]"
        )
    }

    func testUserAtHostIsSplitWhenUsernameIsEmpty() throws {
        let host = Fixtures.host(destination: "ops@gpu-1", username: nil)
        let target = try SSHTarget.make(from: host)
        XCTAssertEqual(target.username, "ops")
        XCTAssertEqual(target.destination, "gpu-1")
    }

    func testUserAtHostIsRejectedWhenUsernameAlreadySet() {
        let host = Fixtures.host(destination: "ops@gpu-1", username: "root")
        XCTAssertThrowsError(try SSHTarget.make(from: host))
    }

    func testTildeIsExpandedInIdentityFile() throws {
        let target = try SSHTarget.make(from: Fixtures.host(identityFile: "~/.ssh/id_ed25519"))
        XCTAssertEqual(target.identityFile, NSHomeDirectory() + "/.ssh/id_ed25519")
    }

    // MARK: - Argument construction

    func testArgumentsAreAlwaysNonInteractiveAndNeverDisableHostKeyChecking() {
        let target = try! SSHTarget.make(from: Fixtures.host(port: 2222, identityFile: "~/.ssh/id_rsa"))
        let arguments = target.probeArguments(remoteCommand: "true")
        let joined = arguments.joined(separator: " ")

        XCTAssertTrue(joined.contains("BatchMode=yes"))
        XCTAssertTrue(joined.contains("ConnectTimeout=\(CheckTimeoutBudget.connectTimeoutSeconds)"))
        XCTAssertTrue(joined.contains("ConnectionAttempts=1"))
        XCTAssertTrue(arguments.contains("-T"))
        XCTAssertTrue(joined.contains("StrictHostKeyChecking=yes"))

        // The three settings that would silently weaken host verification.
        XCTAssertFalse(joined.contains("StrictHostKeyChecking=no"))
        XCTAssertFalse(joined.contains("StrictHostKeyChecking=accept-new"))
        XCTAssertFalse(joined.contains("UserKnownHostsFile=/dev/null"))
        XCTAssertFalse(joined.contains("UpdateHostKeys=yes"))
    }

    func testOptionParsingIsTerminatedBeforeTheDestination() {
        let target = try! SSHTarget.make(from: Fixtures.host())
        let arguments = target.probeArguments(remoteCommand: "true")
        let separator = arguments.firstIndex(of: "--")
        let destination = arguments.firstIndex(of: target.destinationArgument)

        XCTAssertNotNil(separator)
        XCTAssertNotNil(destination)
        XCTAssertEqual(separator! + 1, destination!, "'--' must immediately precede the destination")
    }

    func testRemoteCommandIsExactlyOneArgument() {
        let target = try! SSHTarget.make(from: Fixtures.host())
        let arguments = target.probeArguments(remoteCommand: RemoteProbe.nvidiaScript)
        XCTAssertEqual(arguments.last, RemoteProbe.nvidiaScript)
        XCTAssertEqual(arguments.filter { $0 == RemoteProbe.nvidiaScript }.count, 1)
    }

    func testPortAndIdentityArePassedAsSeparateArguments() {
        let target = try! SSHTarget.make(from: Fixtures.host(port: 2222, identityFile: "/tmp/k"))
        let arguments = target.probeArguments(remoteCommand: "true")
        XCTAssertTrue(arguments.contains("-p"))
        XCTAssertTrue(arguments.contains("2222"))
        XCTAssertTrue(arguments.contains("-i"))
        XCTAssertTrue(arguments.contains("/tmp/k"))
    }
}

final class RemoteProbeTests: XCTestCase {
    func testScriptContainsNoUserSuppliedText() {
        // The script is a constant, so nothing a user types can reach the remote
        // shell. Guard the constant itself.
        XCTAssertTrue(RemoteProbe.nvidiaScript.contains("command -v nvidia-smi"))
        XCTAssertFalse(RemoteProbe.nvidiaScript.contains("\"$("))
        XCTAssertTrue(RemoteProbe.nvidiaScript.hasSuffix("exit 0"))
    }

    func testScriptUsesTheDocumentedQueryFields() {
        let expected = "--query-gpu=index,uuid,name,temperature.gpu,utilization.gpu,memory.used,memory.total"
        XCTAssertTrue(RemoteProbe.nvidiaScript.contains(expected))
        XCTAssertTrue(RemoteProbe.nvidiaScript.contains("--format=csv,noheader,nounits"))
    }

    func testEveryScriptEndsWithExitZeroAndAnEndMarker() {
        // The property that makes a driver failure distinguishable from an SSH
        // failure has to hold for every vendor, not just the one that existed
        // first.
        for script in [RemoteProbe.nvidiaScript, RemoteProbe.amdScript, RemoteProbe.autoScript] {
            XCTAssertTrue(script.hasSuffix("exit 0"), script)
            XCTAssertTrue(script.contains(RemoteProbe.endMarker), script)
        }
    }

    func testScriptSelectionFollowsTheHostVendor() {
        XCTAssertEqual(RemoteProbe.script(for: .nvidia), RemoteProbe.nvidiaScript)
        XCTAssertEqual(RemoteProbe.script(for: .amd), RemoteProbe.amdScript)
        XCTAssertEqual(RemoteProbe.script(for: .auto), RemoteProbe.autoScript)
    }

    func testAMDQueryReadsByFlagsAndAsksForCSV() {
        // The parser depends on --csv, and the flags are what make each metric
        // present at all. Losing one would silently drop a reading.
        for flag in [
            "--showproductname", "--showuniqueid", "--showtemp", "--showuse",
            "--showmemuse", "--showmeminfo vram", "--showpower", "--showmaxpower", "--csv"
        ] {
            XCTAssertTrue(RemoteProbe.rocmSMIArguments.contains(flag), flag)
        }
        XCTAssertTrue(RemoteProbe.amdScript.contains("command -v rocm-smi"))
    }

    func testAutoScriptWouldNotReachTheShellWithUserText() {
        // The auto script is the one with shell variables in it, so it is the
        // one most worth checking for an interpolated value.
        XCTAssertFalse(RemoteProbe.autoScript.contains("\"$("))
        XCTAssertTrue(RemoteProbe.autoScript.contains("GPUW_VENDOR=none"))
    }

    func testEnvelopeParsesSuccessfully() {
        let stdout = Fixtures.envelope(rows: [
            Fixtures.csvRow(index: 0, uuid: Fixtures.uuid(1))
        ])
        let envelope = ProbeEnvelope.parse(stdout: stdout)
        XCTAssertTrue(envelope.transportConfirmed)
        XCTAssertTrue(envelope.nvidiaSMIPresent)
        XCTAssertEqual(envelope.queryReturnCode, 0)
        XCTAssertTrue(envelope.sawQueryOutputMarkers)
        XCTAssertTrue(envelope.queryOutput.contains(Fixtures.uuid(1)))
    }

    func testAbsentNvidiaSMIIsDistinguishableFromTransportFailure() {
        let stdout = Fixtures.envelope(rows: [], nvidiaSMIPresent: false)
        let envelope = ProbeEnvelope.parse(stdout: stdout)
        XCTAssertTrue(envelope.transportConfirmed, "SSH worked")
        XCTAssertFalse(envelope.nvidiaSMIPresent, "but the driver is not installed")
    }

    func testNonZeroDriverExitIsCapturedWithoutLosingTransportConfirmation() {
        let stdout = Fixtures.envelope(
            rows: [],
            exitStatus: 9,
            stderrText: "NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver."
        )
        let envelope = ProbeEnvelope.parse(stdout: stdout)
        XCTAssertTrue(envelope.transportConfirmed)
        XCTAssertEqual(envelope.queryReturnCode, 9)
        XCTAssertTrue(envelope.queryOutput.contains("couldn't communicate"))
    }

    func testOutputWithoutEndMarkerIsNotConfirmed() {
        let envelope = ProbeEnvelope.parse(stdout: "__GPUW_BEGIN__\npartial output only")
        XCTAssertFalse(envelope.transportConfirmed)
    }
}

final class SSHFailureClassifierTests: XCTestCase {
    private func classify(_ stderr: String, status: Int32 = 255, confirmed: Bool = false)
        -> SSHFailureKind {
        SSHFailureClassifier.classify(
            result: SSHCommandResult(terminationStatus: status, stdout: "", stderr: stderr),
            transportConfirmed: confirmed
        ).kind
    }

    func testHostKeyFailuresAreIdentified() {
        XCTAssertEqual(
            classify("Host key verification failed."),
            .hostKeyVerification
        )
        XCTAssertEqual(
            classify("@\n@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@"),
            .hostKeyVerification
        )
    }

    func testAuthenticationFailuresAreIdentified() {
        XCTAssertEqual(classify("ops@gpu-1: Permission denied (publickey)."), .authenticationFailed)
        XCTAssertEqual(classify("Received disconnect: Too many authentication failures"), .authenticationFailed)
    }

    func testNetworkFailuresFallThroughToUnreachable() {
        for message in [
            "ssh: connect to host gpu-1 port 22: Connection refused",
            "ssh: connect to host gpu-1 port 22: Operation timed out",
            "ssh: Could not resolve hostname gpu-1",
            "No route to host",
            "Network is unreachable"
        ] {
            XCTAssertEqual(classify(message), .unreachable, message)
        }
    }

    func testConfirmedTransportIsNeverClassified() {
        // Even with alarming stderr, a confirmed end marker means ssh worked.
        XCTAssertEqual(
            classify("Host key verification failed.", confirmed: true),
            .unknown
        )
    }

    func testNonSSHExitStatusIsNotATransportFailure() {
        XCTAssertEqual(classify("", status: 1), .unknown)
    }

    func testCancellationAndTimeoutWin() {
        let cancelled = SSHFailureClassifier.classify(
            result: SSHCommandResult(
                terminationStatus: -1, stdout: "", stderr: "", cancelled: true
            ),
            transportConfirmed: false
        )
        XCTAssertEqual(cancelled.kind, .cancelled)

        let timedOut = SSHFailureClassifier.classify(
            result: SSHCommandResult(
                terminationStatus: -1, stdout: "", stderr: "", timedOut: true
            ),
            transportConfirmed: false
        )
        XCTAssertEqual(timedOut.kind, .timedOut)
    }
}

final class HostProbeRunnerTests: XCTestCase {
    func testDriverFailureDoesNotBecomeHostOffline() async {
        let runner = FakeSSHRunner()
        runner.setDefault(.result(
            terminationStatus: 0,
            stdout: Fixtures.envelope(
                rows: [],
                exitStatus: 9,
                stderrText: "NVIDIA-SMI has failed because it couldn't communicate with the NVIDIA driver."
            ),
            stderr: ""
        ))

        let probe = await HostProbeRunner(commands: runner).probe(host: Fixtures.host(), now: Date())
        XCTAssertTrue(probe.ssh.isOK, "SSH clearly worked")
        guard case let .failed(reason, _) = probe.query else {
            return XCTFail("expected a GPU query failure")
        }
        XCTAssertEqual(reason, .commandFailed)
        XCTAssertFalse(probe.queryWasComplete)
    }

    func testMissingNvidiaSMIIsItsOwnOutcome() async {
        let runner = FakeSSHRunner()
        runner.setDefault(.result(
            terminationStatus: 0,
            stdout: Fixtures.envelope(rows: [], nvidiaSMIPresent: false),
            stderr: ""
        ))

        let probe = await HostProbeRunner(commands: runner).probe(host: Fixtures.host(), now: Date())
        XCTAssertTrue(probe.ssh.isOK)
        guard case let .failed(reason, _) = probe.query else {
            return XCTFail("expected a GPU query failure")
        }
        XCTAssertEqual(reason, .gpuToolNotFound)
    }

    // MARK: - AMD

    func testAMDHostIsReadWithTheROCmParser() async {
        let runner = FakeSSHRunner()
        runner.setDefault(.result(
            terminationStatus: 0,
            stdout: Fixtures.amdEnvelope(rows: [
                Fixtures.rocmOutput(rows: [Fixtures.rocmRow(index: 0, id: Fixtures.rocmID(1))])
            ]),
            stderr: ""
        ))

        let probe = await HostProbeRunner(commands: runner)
            .probe(host: Fixtures.host(vendor: .amd), now: Date())

        XCTAssertTrue(probe.ssh.isOK)
        guard case let .ok(samples, _) = probe.query else {
            return XCTFail("expected readable AMD samples, got \(probe.query)")
        }
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].uuid, Fixtures.rocmID(1))
        XCTAssertEqual(samples[0].model, "AMD Radeon RX 7900 XTX")
        XCTAssertEqual(samples[0].temperatureCelsius, 42.0, "edge sensor, not junction")
        XCTAssertEqual(samples[0].memoryTotalMiB ?? 0, 24560, accuracy: 0.001)
    }

    /// A ROCm row would be rejected outright by the NVIDIA parser (wrong field
    /// count), so reaching `.ok` here is proof the vendor marker — not a guess
    /// from the output's shape — chose the parser.
    func testAutoDetectionUsesTheParserForTheVendorThatAnswered() async {
        let runner = FakeSSHRunner()
        runner.setDefault(.result(
            terminationStatus: 0,
            stdout: Fixtures.amdEnvelope(rows: [
                Fixtures.rocmOutput(rows: [Fixtures.rocmRow(index: 0, id: Fixtures.rocmID(1))])
            ]),
            stderr: ""
        ))

        let probe = await HostProbeRunner(commands: runner)
            .probe(host: Fixtures.host(vendor: .auto), now: Date())

        guard case let .ok(samples, _) = probe.query else {
            return XCTFail("expected readable AMD samples, got \(probe.query)")
        }
        XCTAssertEqual(samples[0].uuid, Fixtures.rocmID(1))
    }

    func testVendorMarkerOverridesTheScriptsLegacyPresenceMarker() {
        // An auto script reports the vendor before the output block; a legacy
        // NVIDIA-only script reports presence with no vendor at all. The
        // explicit marker has to win, or a ROCm host would be read as NVIDIA.
        let stdout = [
            RemoteProbe.beginMarker,
            RemoteProbe.smiPresentMarker,
            "\(RemoteProbe.vendorPrefix)\(RemoteProbe.vendorAMDSuffix)",
            RemoteProbe.outBeginMarker,
            RemoteProbe.outEndMarker,
            RemoteProbe.endMarker
        ].joined(separator: "\n")

        let envelope = ProbeEnvelope.parse(stdout: stdout)
        XCTAssertEqual(envelope.vendor, .amd)
        XCTAssertFalse(envelope.nvidiaSMIPresent)
        XCTAssertTrue(envelope.toolPresent)
    }

    func testEachVendorSettingSendsItsOwnScript() async {
        for vendor in GPUVendor.allCases {
            let runner = FakeSSHRunner()
            _ = await HostProbeRunner(commands: runner)
                .probe(host: Fixtures.host(vendor: vendor), now: Date())

            let sent = runner.recordedInvocations.first?.remoteCommand
            XCTAssertEqual(
                sent,
                RemoteProbe.script(for: vendor),
                "\(vendor) should send its own script"
            )
        }
    }

    func testTransportFailureYieldsBothAxes() async {
        let runner = FakeSSHRunner()
        runner.setDefault(.result(
            terminationStatus: 255,
            stdout: "",
            stderr: "ssh: connect to host gpu-1.example.invalid port 22: Connection refused"
        ))

        let probe = await HostProbeRunner(commands: runner).probe(host: Fixtures.host(), now: Date())
        guard case let .failed(kind, _) = probe.ssh else {
            return XCTFail("expected an SSH failure")
        }
        XCTAssertEqual(kind, .unreachable)
        guard case let .failed(reason, _) = probe.query else {
            return XCTFail("expected a GPU query failure")
        }
        XCTAssertEqual(reason, .transportFailure)
    }

    func testNonZeroExitWithoutMarkerStillCountsAsReached() async {
        // e.g. a remote shell that rejected the one-liner: transport worked but
        // nothing meaningful came back.
        let runner = FakeSSHRunner()
        runner.setDefault(.result(terminationStatus: 2, stdout: "", stderr: "sh: syntax error"))

        let probe = await HostProbeRunner(commands: runner).probe(host: Fixtures.host(), now: Date())
        XCTAssertTrue(probe.ssh.isOK)
        guard case let .failed(reason, _) = probe.query else {
            return XCTFail("expected a GPU query failure")
        }
        XCTAssertEqual(reason, .malformedOutput)
    }

    func testLaunchFailureIsReportedAsAnSSHFailure() async {
        let runner = FakeSSHRunner()
        runner.setDefault(.failure(SSHProcessError.launchFailed("boom")))

        let probe = await HostProbeRunner(commands: runner).probe(host: Fixtures.host(), now: Date())
        XCTAssertTrue(probe.ssh.isFailure)
    }

    func testInvalidHostNeverSpawnsAProcess() async {
        let runner = FakeSSHRunner()
        let probe = await HostProbeRunner(commands: runner)
            .probe(host: Fixtures.host(destination: "-oProxyCommand=evil"), now: Date())
        XCTAssertTrue(probe.ssh.isFailure)
        XCTAssertEqual(runner.invocationCount, 0, "nothing should have been executed")
    }

    func testNonZeroDriverExitMakesTheReadingIncomplete() async {
        let runner = FakeSSHRunner()
        runner.setDefault(.result(
            terminationStatus: 0,
            stdout: Fixtures.envelope(
                rows: [Fixtures.csvRow(index: 0, uuid: Fixtures.uuid(1))],
                exitStatus: 9
            ),
            stderr: ""
        ))

        let probe = await HostProbeRunner(commands: runner).probe(host: Fixtures.host(), now: Date())
        XCTAssertTrue(probe.query.isOK, "rows came back and should still be shown")
        XCTAssertFalse(probe.queryWasComplete, "but absence must not be inferred from an errored run")
    }
}
