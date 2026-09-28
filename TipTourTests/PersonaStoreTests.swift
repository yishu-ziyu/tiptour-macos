//
//  PersonaStoreTests.swift
//  TipTourTests
//
//  persona.md is the user's file: it is created when missing, read again on
//  every call, and never overwritten when it cannot be read.
//

import Foundation
import Testing
@testable import TipTour

struct PersonaStoreTests {
    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("persona-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("persona.md")
    }

    @Test func aMissingFileIsCreatedWithTheDefaultSoTheUserCanFindIt() throws {
        let file = try temporaryFile()
        let store = PersonaStore(fileURL: file)

        let read = store.read()
        #expect(read.isDefault)
        #expect(read.text == PersonaStore.defaultText)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("长期伙伴"))
    }

    @Test func anEditCountsFromTheNextRead() throws {
        let file = try temporaryFile()
        let store = PersonaStore(fileURL: file)
        _ = store.read()

        try "你说话再短一点。\n".write(to: file, atomically: true, encoding: .utf8)
        let read = store.read()
        #expect(read.text == "你说话再短一点。")
        #expect(!read.isDefault)
    }

    @Test func anEmptiedFileFallsBackToTheDefaultWithoutBeingOverwritten() throws {
        let file = try temporaryFile()
        try "  \n".write(to: file, atomically: true, encoding: .utf8)

        #expect(PersonaStore(fileURL: file).read().text == PersonaStore.defaultText)
        #expect(try String(contentsOf: file, encoding: .utf8) == "  \n")
    }

    @Test func anUnreadableFileIsKeptAsideNotOverwritten() throws {
        let file = try temporaryFile()
        let garbage = Data([0xFF, 0xFE, 0xFD, 0x00, 0xC3])
        try garbage.write(to: file)

        #expect(PersonaStore(fileURL: file).read().isDefault)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        let aside = try #require(siblings.first { $0.hasPrefix("persona.unreadable-") })
        #expect(try Data(contentsOf: file.deletingLastPathComponent().appendingPathComponent(aside)) == garbage)
    }

    @Test func aLongPersonaIsCut() throws {
        let file = try temporaryFile()
        try String(repeating: "长", count: 5000).write(to: file, atomically: true, encoding: .utf8)

        #expect(PersonaStore(fileURL: file).read().text.count == PersonaStore.maximumLength)
    }

    @Test func theIdentityNamesHerAndTheUserOnlyWhenKnown() {
        let named = PersonaStore.identity(persona: "P", companionName: "小满", userAddress: "奕枢")
        #expect(named.contains("你的名字是「小满」"))
        #expect(named.contains("称呼用户「奕枢」"))

        let unnamed = PersonaStore.identity(persona: "P", companionName: "", userAddress: "")
        #expect(unnamed.contains("不要自己编一个名字"))
        #expect(unnamed.contains("不要自己编一个称呼"))
    }
}
