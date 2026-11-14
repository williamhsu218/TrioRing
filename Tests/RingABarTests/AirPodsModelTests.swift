import Testing
@testable import RingABar

struct AirPodsModelTests {
    @Test func usesAppleBluetoothModelForTheSymbol() {
        #expect(AirPodsOutput.symbol(forModelUID: "2027 4c") == "airpodspro")
        #expect(AirPodsOutput.symbol(forModelUID: "2014 004C") == "airpodspro")
        #expect(AirPodsOutput.symbol(forModelUID: "2019 4c") == "airpods.gen4")
        #expect(AirPodsOutput.symbol(forModelUID: "200A 4C") == "airpodsmax")
        #expect(AirPodsOutput.symbol(forModelUID: "2002 4c") == "airpods")
    }

    @Test func unrecognizedModelsUseTheGenericOutputIcon() {
        for uid in [nil, "2027 1234", "2025 4c", "ffff 4c", "2027", "AirPods Pro"] {
            #expect(AirPodsOutput.symbol(forModelUID: uid) == nil)
        }
    }
}
