// The independent-process business probe is implemented in the G4 work package.
@main enum VirtualActorBusinessProbe {
    static func main() throws { throw ProbeUnavailable.notImplemented }
    enum ProbeUnavailable: Error { case notImplemented }
}
