import Foundation
import Testing

@testable import AmbeoCore

private struct Labelled: Decodable { @Stringified var label: String? }

private struct Flagged: Decodable { @Stringified var flag: Bool? }

@Suite("Stringified Decoding Tests") struct StringifiedDecodingTests {
  private func edit(_ json: String) throws -> AmbeoEndpoint.Player.Volume.Edit? {
    try JSONDecoder().decode(AmbeoEntry<AmbeoEndpoint.Player.Volume>.self, from: Data(json.utf8))
      .edit
  }

  @Test("String edit fields decode (observed firmware behaviour)") func strings() throws {
    let edit = try edit(
      #"{"value":{"type":"i32_","i32_":25},"edit":{"step":"1","min":"0","max":"100"}}"#
    )
    #expect(edit?.step == 1)
    #expect(edit?.min == 0)
    #expect(edit?.max == 100)
  }

  @Test("Numeric edit fields decode instead of silently falling back to defaults") func numbers()
    throws
  {
    // A firmware reply of `step: 2` must not degrade the media-key volume step to the fallback 1.
    let edit = try edit(#"{"value":{"type":"i32_","i32_":25},"edit":{"step":2,"min":5,"max":80}}"#)
    #expect(edit?.step == 2)
    #expect(edit?.min == 5)
    #expect(edit?.max == 80)
  }

  @Test("Integral doubles normalise for Int-typed fields") func integralDoubles() throws {
    let edit = try edit(#"{"edit":{"step":1.0,"min":0.0,"max":100.0}}"#)
    #expect(edit?.step == 1)
    #expect(edit?.min == 0)
    #expect(edit?.max == 100)
  }

  @Test("Non-integral doubles stay nil for Int-typed fields") func nonIntegralDoubles() throws {
    let edit = try edit(#"{"edit":{"step":1.5}}"#)
    #expect(edit?.step == nil)
  }

  @Test("Partial and empty edit objects decode instead of failing the whole entry")
  func partialEditObjects() throws {
    // Synthesized decoding required every key, so `{"edit":{"step":2}}` threw `keyNotFound: min`
    // and the caller lost min/max as well as step.
    let partial = try edit(#"{"edit":{"step":2}}"#)
    #expect(partial?.step == 2)
    #expect(partial?.max == nil)
    #expect(try edit(#"{"edit":{}}"#)?.step == nil)

    let preset = try JSONDecoder().decode(
      AmbeoEntry<AmbeoEndpoint.Audio.Preset>.self,
      from: Data(#"{"value":{"type":"string_","string_":"music"}}"#.utf8)
    )
    #expect(preset.value == "music")
    #expect(preset.edit?.enumPath == nil)
  }

  @Test("Null, objects, and arrays decode to nil without throwing") func unrepresentableShapes()
    throws
  {
    #expect(try edit(#"{"edit":{"step":null}}"#)?.step == nil)
    #expect(try edit(#"{"edit":{"step":{"a":1}}}"#)?.step == nil)
    #expect(try edit(#"{"edit":{"step":[1]}}"#)?.step == nil)
  }

  @Test("Numbers reach String-typed fields as their text form") func stringTypedField() throws {
    #expect(
      try JSONDecoder().decode(Labelled.self, from: Data(#"{"label":25}"#.utf8)).label == "25"
    )
    #expect(
      try JSONDecoder().decode(Labelled.self, from: Data(#"{"label":"25"}"#.utf8)).label == "25"
    )
  }

  @Test("JSON booleans reach Bool-typed fields") func boolTypedField() throws {
    #expect(try JSONDecoder().decode(Flagged.self, from: Data(#"{"flag":true}"#.utf8)).flag == true)
    #expect(
      try JSONDecoder().decode(Flagged.self, from: Data(#"{"flag":"false"}"#.utf8)).flag == false
    )
  }
}
