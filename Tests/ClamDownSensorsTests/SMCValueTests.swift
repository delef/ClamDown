import Testing
@testable import ClamDownSensors

@Suite struct SMCValueTests {
    @Test func floatIsLittleEndian() {
        #expect(SMCValue(type: "flt ", bytes: [0x00, 0x28, 0xa7, 0x45]).number == 5349)
        #expect(SMCValue.float(36.5).number == 36.5)
    }

    @Test func integersAreBigEndian() {
        #expect(SMCValue(type: "ui8 ", bytes: [2]).number == 2)
        #expect(SMCValue(type: "ui16", bytes: [0x01, 0x02]).number == 258)
        #expect(SMCValue(type: "ui32", bytes: [0x00, 0x01, 0x00, 0x01]).number == 65537)
    }

    @Test func fixedPointTypes() {
        #expect(SMCValue(type: "sp78", bytes: [0x2a, 0x80]).number == 42.5)
        #expect(SMCValue(type: "sp78", bytes: [0xff, 0x00]).number == -1)
        #expect(SMCValue(type: "fpe2", bytes: [0x17, 0x70]).number == 1500)
    }

    @Test func shortOrUnknownValuesAreNil() {
        #expect(SMCValue(type: "flt ", bytes: [0, 0, 0]).number == nil)
        #expect(SMCValue(type: "ui16", bytes: [1]).number == nil)
        #expect(SMCValue(type: "sp78", bytes: []).number == nil)
        #expect(SMCValue(type: "hex_", bytes: [1, 2]).number == nil)
        #expect(SMCValue(type: "ioft", bytes: [0, 0, 0, 0, 0, 0, 0, 0]).number == nil)
    }

    @Test func keyCodesRoundTrip() {
        #expect(SMC.code("F0Tg") == 0x4630_5467)
        #expect(SMC.name(SMC.code("TaLP")) == "TaLP")
        #expect(SMC.name(SMC.code("#KEY")) == "#KEY")
    }

    @Test func dumpBytesDecode() {
        #expect(SMCKeyDump.Entry(key: "FNum", type: "ui8 ", bytes: "02").value == .byte(2))
        #expect(SMCKeyDump.Entry(key: "x", type: "ui8 ", bytes: "0").value == nil)
        #expect(SMCKeyDump.Entry(key: "x", type: "ui8 ", bytes: "zz").value == nil)
    }
}
