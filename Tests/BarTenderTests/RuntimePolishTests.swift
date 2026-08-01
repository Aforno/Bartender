import Darwin
import Foundation
import XCTest
@testable import BarTender

final class RuntimePolishTests: XCTestCase {
    func testLoginPATHExtractionIgnoresShellStartupOutput() {
        let output = """
        Welcome back: loading tools
        /this/is/not/the/path
        __BARTENDER_PATH__=/custom/bin:/usr/bin:/bin
        """

        XCTAssertEqual(
            ShellEnvironment.extractLoginPATH(from: output),
            "/custom/bin:/usr/bin:/bin"
        )
        XCTAssertNil(ShellEnvironment.extractLoginPATH(from: "Welcome only"))
    }

    func testSensorWrapperRepairsExecutablePermissionsWhenContentsMatch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarTender-Wrapper-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let initialPath = try XCTUnwrap(
            ShellEnvironment.ensureSensorCLIWrapper(
                appExecutable: "/bin/echo",
                applicationSupportURL: root
            )
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: initialPath
        )

        let repairedPath = try XCTUnwrap(
            ShellEnvironment.ensureSensorCLIWrapper(
                appExecutable: "/bin/echo",
                applicationSupportURL: root
            )
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: repairedPath)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o755)
    }

    func testGeneratedSourceValidationUsesBashForBashShebang() async throws {
        let manifest = AppletManifest(
            name: "Bash Syntax",
            iconSystemName: "terminal",
            kind: .generatedTool,
            titleTemplate: "{{value}}",
            config: AppletConfig(
                generatedSource: """
                #!/bin/bash
                value=HELLO
                echo "${value,,}"
                """
            )
        )

        try await GeneratedToolSourceValidator.validate(manifest)
    }
}
