import Darwin
import TerminalCore
import Testing

@Suite(.serialized)
struct DescriptorHygieneTests {
    @Test func sweepMarksBothEndsOfAnOpenPipe() {
        var descriptors: [Int32] = [-1, -1]
        #expect(pipe(&descriptors) == 0)
        defer {
            close(descriptors[0])
            close(descriptors[1])
        }

        #expect(DescriptorHygiene.isCloseOnExec(descriptors[0]) == false)
        DescriptorHygiene.markCloseOnExec()
        #expect(DescriptorHygiene.isCloseOnExec(descriptors[0]) == true)
        #expect(DescriptorHygiene.isCloseOnExec(descriptors[1]) == true)
    }

    @Test func invalidDescriptorIsReported() {
        #expect(DescriptorHygiene.markCloseOnExec(-1) == false)
        #expect(DescriptorHygiene.isCloseOnExec(-1) == nil)
    }

    @Test func sweepLeavesStandardDescriptorsUnchanged() {
        let descriptors: [Int32] = [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO]
        let before = descriptors.map { fcntl($0, F_GETFD) }
        DescriptorHygiene.markCloseOnExec()
        let after = descriptors.map { fcntl($0, F_GETFD) }
        #expect(after == before)
    }

    @Test func aSecondSweepMarksNothing() {
        var descriptors: [Int32] = [-1, -1]
        #expect(pipe(&descriptors) == 0)
        defer {
            close(descriptors[0])
            close(descriptors[1])
        }

        DescriptorHygiene.markCloseOnExec()
        #expect(DescriptorHygiene.markCloseOnExec() == 0)
    }
}
