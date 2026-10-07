import XCTest
@testable import ComicViewer

@MainActor
final class SourcePluginStoreTests: XCTestCase {
    private func manifest(_ id: String = "fixture.source") throws -> SourcePluginManifest {
        try JSONDecoder().decode(SourcePluginManifest.self, from: Data("""
        {"id":"\(id)","name":"Fixture","version":"1.0"}
        """.utf8))
    }

    func testReloadChangesHashAndPreservesEnabledState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try manifest()
        let store = SourcePluginStore(baseDirectory: root, validate: { _ in manifest }, didChange: { _ in })
        let source = root.appendingPathComponent("working.js")
        let original = try await store.install(script: "original", sourceURL: source)
        store.setEnabled(original.id, enabled: false)
        let changed = try await store.install(script: "changed", sourceURL: source, expectedID: original.id)
        XCTAssertNotEqual(original.scriptHash, changed.scriptHash)
        XCTAssertFalse(changed.enabled)
        XCTAssertEqual(store.script(for: changed), "changed")
        let restored = SourcePluginStore(baseDirectory: root, validate: { _ in manifest }, didChange: { _ in })
        XCTAssertEqual(restored.plugins.first?.scriptHash, changed.scriptHash)
    }

    func testIdentityChangeDoesNotReplaceInstalledPlugin() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try manifest(), b = try manifest("other.source")
        let store = SourcePluginStore(baseDirectory: root, validate: { $0 == "old" ? a : b }, didChange: { _ in })
        let installed = try await store.install(script: "old", sourceURL: root.appendingPathComponent("source.js"))
        do {
            _ = try await store.install(script: "new", sourceURL: installed.sourceURL, expectedID: installed.id)
            XCTFail("Identity change should fail")
        } catch {}
        XCTAssertEqual(store.plugins, [installed])
        XCTAssertEqual(store.script(for: installed), "old")
    }

    func testRegistryWriteFailurePreservesOldScriptAndMemory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try manifest()
        let store = SourcePluginStore(baseDirectory: root, validate: { _ in manifest }, didChange: { _ in })
        let original = try await store.install(script: "old", sourceURL: root.appendingPathComponent("source.js"))
        let registry = root.appendingPathComponent("source-plugins.json")
        try FileManager.default.removeItem(at: registry)
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        do {
            _ = try await store.install(script: "new", sourceURL: original.sourceURL)
            XCTFail("Writing over a directory should fail")
        } catch {}
        XCTAssertEqual(store.plugins, [original])
        XCTAssertEqual(store.script(for: original), "old")
    }

    func testSettingsApplyRejectsInvalidValueWithoutChangingMemory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let setting = SourcePluginSetting(id: "flag", title: "Flag", description: nil, type: "bool", defaultValue: .bool(false), options: nil)
        let plugin = SourcePlugin(id: "test", name: "Test", version: "1", homepage: nil, description: nil,
                                  tags: nil, capabilities: nil, settings: [setting], sourceURL: root,
                                  fileName: "test.js", installedAt: Date(), enabled: true)
        let store = SourcePluginSettingsStore(baseDirectory: root, didChange: { _ in })
        try store.apply(["flag": .bool(true)], for: plugin)
        XCTAssertThrowsError(try store.apply(["flag": .string("wrong")], for: plugin))
        XCTAssertEqual(store.value(for: plugin, key: "flag"), .bool(true))
        let restored = SourcePluginSettingsStore(baseDirectory: root, didChange: { _ in })
        XCTAssertEqual(restored.value(for: plugin, key: "flag"), .bool(true))
    }
    func testChangedSettingTypeFallsBackToNewDefault() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func plugin(_ type: String, _ value: SourcePluginSettingValue) -> SourcePlugin {
            SourcePlugin(id: "fixture", name: "Fixture", version: "1", homepage: nil, description: nil,
                tags: nil, capabilities: nil,
                settings: [SourcePluginSetting(id: "value", title: "Value", description: nil, type: type, defaultValue: value, options: nil)],
                sourceURL: root, fileName: "test.js", installedAt: Date(), enabled: true)
        }
        let store = SourcePluginSettingsStore(baseDirectory: root, didChange: { _ in })
        try store.apply(["value": .string("old")], for: plugin("string", .string("default")))
        XCTAssertEqual(store.value(for: plugin("bool", .bool(false)), key: "value"), .bool(false))
    }

}
