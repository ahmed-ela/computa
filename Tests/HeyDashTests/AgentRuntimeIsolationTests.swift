import Foundation
import XCTest
@testable import HeyDash

/// Pure configuration fixtures: no process launch, environment mutation, or files.
final class AgentRuntimeIsolationTests: XCTestCase {
    func testChildHomeIsPrivateWithoutChangingNativeUserHome() {
        let original = FileManager.default.homeDirectoryForCurrentUser
        let root = "/private/owned/runtime"
        let childHome = AgentRuntimeIsolation.processHomeURL(codexHomePath: root)
        let environment = AgentRuntimeIsolation.environment(inheriting: ["HOME": "/foreign", "CODEX_HOME": "/foreign/.codex"],
            userHomePath: childHome.path, codexHomePath: root)
        XCTAssertEqual(childHome.path, root + "/ProcessHome")
        XCTAssertEqual(environment["HOME"], childHome.path)
        XCTAssertEqual(environment["CODEX_HOME"], root)
        XCTAssertEqual(FileManager.default.homeDirectoryForCurrentUser, original)
    }
    func testEmptyParentEnvironmentProducesOnlyExplicitHomesAndSystemPath() {
        XCTAssertEqual(
            AgentRuntimeIsolation.environment(
                inheriting: [:], userHomePath: "/Users/fixture",
                codexHomePath: "/Users/fixture/Library/Application Support/HeyDash/AgentHome"
            ),
            [
                "HOME": "/Users/fixture",
                "CODEX_HOME": "/Users/fixture/Library/Application Support/HeyDash/AgentHome",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            ]
        )
    }

    func testArbitraryParentCredentialsOverridesAndHooksAreNeverInherited() {
        let untrustedKeys = [
            "HOME", "CODEX_HOME", "PATH", "CODEX_CONFIG", "CODEX_API_KEY",
            "CODEX_OSS_BASE_URL", "CODEX_OSS_PORT", "CODEX_FUTURE_OVERRIDE",
            "OPENAI_API_KEY", "OPENAI_BASE_URL", "OPENAI_ORG_ID", "OPENAI_PROJECT_ID",
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy",
            "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH", "LD_PRELOAD",
            "BASH_ENV", "ENV", "SHELL", "ZDOTDIR", "PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP",
            "PYTHONINSPECT", "NODE_OPTIONS", "RUBYOPT", "PERL5OPT", "GIT_CONFIG_GLOBAL",
            "SSL_CERT_FILE", "SSL_CERT_DIR", "SSH_AUTH_SOCK", "XDG_CONFIG_HOME",
            "LC_UNKNOWN", "UNRECOGNIZED_FUTURE_KEY",
        ]
        let inherited = Dictionary(uniqueKeysWithValues: untrustedKeys.map { ($0, "untrusted-fixture") })
        XCTAssertEqual(
            AgentRuntimeIsolation.environment(
                inheriting: inherited, userHomePath: "/Users/actual-fixture",
                codexHomePath: "/private/fixture/AgentHome"
            ),
            [
                "HOME": "/Users/actual-fixture", "CODEX_HOME": "/private/fixture/AgentHome",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            ]
        )
        XCTAssertEqual(inherited["HOME"], "untrusted-fixture")
    }

    func testOnlyExplicitTemporaryDirectoryAndLocaleKeysAreRetainedVerbatim() {
        let allowed = [
            "TMPDIR": "/private/var/fixture temporary/", "LANG": "en_US.UTF-8",
            "LC_ALL": "", "LC_COLLATE": "C", "LC_CTYPE": "UTF-8", "LC_MESSAGES": "en_US.UTF-8",
            "LC_MONETARY": "en_US.UTF-8", "LC_NUMERIC": "C", "LC_TIME": "en_GB.UTF-8",
        ]
        var inherited = allowed
        inherited["OPENAI_API_KEY"] = "untrusted-fixture"
        var expected = allowed
        expected["HOME"] = "/Users/fixture"
        expected["CODEX_HOME"] = "/private/fixture/AgentHome"
        expected["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        XCTAssertEqual(
            AgentRuntimeIsolation.environment(
                inheriting: inherited, userHomePath: "/Users/fixture",
                codexHomePath: "/private/fixture/AgentHome"
            ),
            expected
        )
    }

    func testCallerCanAddOnlyItsExplicitEndpointAfterSanitization() {
        var environment = AgentRuntimeIsolation.environment(
            inheriting: ["CODEX_OSS_BASE_URL": "https://untrusted.invalid", "CODEX_OSS_PORT": "9999"],
            userHomePath: "/Users/fixture", codexHomePath: "/private/fixture/AgentHome"
        )
        environment["CODEX_OSS_BASE_URL"] = "http://127.0.0.1:1237/v1"
        XCTAssertEqual(environment, [
            "HOME": "/Users/fixture", "CODEX_HOME": "/private/fixture/AgentHome",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CODEX_OSS_BASE_URL": "http://127.0.0.1:1237/v1",
        ])
    }

    func testIsolationArgumentsUseSupportedExplicitFileStoresAndNoAncestorMarkers() {
        XCTAssertEqual(AgentRuntimeIsolation.configurationArguments, [
            "-c", "project_root_markers=[]",
            "-c", "cli_auth_credentials_store=\"file\"",
            "-c", "mcp_oauth_credentials_store=\"file\"",
            "-c", "features.shell_snapshot=false",
            "-c", "features.shell_snapshot_v2=false",
            "-c", "allow_login_shell=false",
        ])
    }

    func testWorkspaceIsInsideTheExplicitPrivateHomeIncludingSpacesAndUnicode() {
        for path in ["/private/fixture/AgentHome", "/Users/fixture/Library/Application Support/HeyDash/東京/"] {
            let workspace = AgentRuntimeIsolation.workspaceURL(codexHomePath: path)
            XCTAssertTrue(workspace.isFileURL)
            XCTAssertEqual(workspace.lastPathComponent, "Workspace")
            XCTAssertEqual(workspace.deletingLastPathComponent().standardizedFileURL,
                           URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL)
        }
    }
}
