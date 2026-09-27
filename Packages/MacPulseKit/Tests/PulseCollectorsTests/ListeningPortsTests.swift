import Foundation
import Testing
@testable import PulseCollectors

@Suite struct ListeningPortsTests {
    let sample = """
    Active Internet connections (including servers)
    Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)          rxbytes      txbytes  rhiwat  shiwat    pid   epid state  options
    tcp46      0      0  *.49201                *.*                    LISTEN                 0            0  131072  131072         rapportd:612    00100 00000006 0000000000
    tcp6       0      0  *.49201                *.*                    LISTEN                 0            0  131072  131072         rapportd:612    00100 00000006 0000000000
    tcp4       0      0  127.0.0.1.58312        *.*                    LISTEN                 0            0  131072  131072 Code Helper (Plu:84517    00100 00000106 00000000001244c9
    tcp6       0      0  ::1.5432               *.*                    LISTEN                 0            0  131072  131072       postgres:901      00100 00000106 0000000000
    tcp4       0      0  192.168.1.5.52100      17.1.2.3.443           ESTABLISHED       1200         3400  131072  131072          Safari:77       00102 00000000 0000000000
    """

    @Test func parsesListenersWithSpacesInNamesAndDedupes() {
        let ports = NetstatParser.listening(sample)
        #expect(ports.map(\.port) == [5432, 49201, 58312])
        let code = ports.first { $0.port == 58312 }
        #expect(code?.processName == "Code Helper (Plu" && code?.pid == 84517 && code?.address == "127.0.0.1")
        #expect(ports.first { $0.port == 5432 }?.address == "::1")
        #expect(ports.filter(\.isLoopbackOnly).map(\.port) == [5432, 58312])
    }

    @Test func splitAddressForms() {
        #expect(NetstatParser.splitAddress("*.8080")! == ("*", 8080))
        #expect(NetstatParser.splitAddress("fe80::1%lo0.631")! == ("fe80::1%lo0", 631))
        #expect(NetstatParser.splitAddress("*.*") == nil)
    }

    @Test func liveSampleHasOwnersAndNoDuplicates() {
        let ports = ListeningPortsCollector.sample()
        #expect(Set(ports.map(\.id)).count == ports.count)
        #expect(ports.allSatisfy { $0.pid > 0 })
    }

    @Test func runtimeDetection() {
        #expect(DevRuntime.detect(processName: "python3.13") == .python)
        #expect(DevRuntime.detect(processName: "node") == .node)
        #expect(DevRuntime.detect(processName: "java") == .java)
        #expect(DevRuntime.detect(processName: "com.docker.backend") == .docker)
        #expect(DevRuntime.detect(processName: "postgres") == .postgres)
        #expect(DevRuntime.detect(processName: "nodemon-helper") == nil)
        #expect(DevRuntime.detect(processName: "Safari") == nil)
    }
}
