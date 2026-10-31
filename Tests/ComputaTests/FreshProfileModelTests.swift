import XCTest
@testable import Computa

@MainActor
final class FreshProfileModelTests: XCTestCase {
    func testFreshProfileSelectsNormalChatInstantWithoutInventingAvailability() throws {
        let preferences = isolatedTestPreferences()
        let state = AppState(tasks: [], preferences: preferences)
        let instant = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/instant", label: "Instant")

        XCTAssertEqual(state.defaultModel, instant.modelID)
        XCTAssertEqual(WebsiteModelCatalog.inferenceSelection(for: state.defaultModel)?.choice, instant)
        XCTAssertTrue(state.websiteModelChoices.isEmpty)
        XCTAssertNil(preferences.data(forKey: WebsiteModelCatalog.preferenceKey))
        XCTAssertNil(preferences.string(forKey: "LocalCodex.defaultModelID"))
        let option = try XCTUnwrap(WebUISnapshot(state: state).modelOptions.first { $0.id == instant.modelID })
        XCTAssertEqual(option.available, false)
        XCTAssertFalse(state.setDefaultModel(instant.modelID))

        state.createTask()
        let task = try XCTUnwrap(state.selectedTask)
        XCTAssertEqual(task.model, instant.modelID)
        XCTAssertFalse(state.setTaskModel(instant.modelID, taskID: task.id))
    }

    func testDiscoveredInstantBecomesAvailableAndRemainsAvailableAfterReopening() async throws {
        let preferences = isolatedTestPreferences()
        let instant = WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/instant", label: "Instant")
        var discovered: [String] = []
        let state = AppState(tasks: [], preferences: preferences, websiteModelDiscovery: { provider in
            discovered.append(provider)
            return [instant]
        })
        state.createTask()
        let taskID = try XCTUnwrap(state.selectedTaskID)
        XCTAssertEqual(state.modelOptions.first { $0.id == instant.modelID }?.available, false)

        await state.refreshWebsiteModels(provider: "chatgpt")

        XCTAssertEqual(discovered, ["chatgpt"])
        XCTAssertEqual(state.websiteModelChoices, [instant])
        XCTAssertEqual(state.defaultModel, instant.modelID)
        XCTAssertEqual(state.modelOptions.first { $0.id == instant.modelID }?.available, true)
        XCTAssertTrue(state.setTaskModel(instant.modelID, taskID: taskID))
        let reopened = AppState(tasks: [], preferences: preferences)
        XCTAssertEqual(reopened.defaultModel, instant.modelID)
        XCTAssertEqual(reopened.modelOptions.first { $0.id == instant.modelID }?.available, true)
    }

    func testFreshDefaultDoesNotReplaceSavedLocalAPIOrWebsiteSelectionsOrHistory() throws {
        let savedModels = [
            LocalModelCatalog.defaultModelID,
            APIProviderCatalog.appModelID(providerID: "cerebras", modelID: "gpt-oss-120b"),
            WebsiteModelChoice(provider: "chatgpt", key: "chat/latest/high", label: "High").modelID,
            WebsiteModelChoice(provider: "gemini", key: "fixture-pro", label: "Fixture Pro").modelID,
            WebsiteModelChoice(provider: "claude", key: "fixture-sonnet", label: "Fixture Sonnet").modelID,
        ]
        let entry = TimelineEntry(kind: .assistant, title: "Recorded answer", body: "Keep this history", turnID: "historic-turn")
        let history = savedModels.enumerated().map { index, model in
            AgentTask(id: "history-\(index)", title: "Saved", summary: "", status: .completed,
                      workspace: "/tmp", model: model, entries: [entry])
        }

        for model in savedModels {
            let preferences = isolatedTestPreferences()
            preferences.set(model, forKey: "LocalCodex.defaultModelID")
            let state = AppState(tasks: history, preferences: preferences)
            XCTAssertEqual(state.defaultModel, model)
            XCTAssertEqual(preferences.string(forKey: "LocalCodex.defaultModelID"), model)
            XCTAssertEqual(state.tasks.map(\.model), savedModels)
            XCTAssertEqual(state.tasks.map(\.entries), history.map(\.entries))
            state.createTask()
            XCTAssertEqual(state.selectedTask?.model, model)
        }
    }
}
