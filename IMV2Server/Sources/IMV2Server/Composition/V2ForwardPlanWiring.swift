import IMV2ServerInfrastructure
import IMV2ServerApplication
import IMV2ServerContracts

extension V2OwnerAwareForwardPlanPort {
    public init(router:any V2RoomShardRouting,rooms:V2RoomRefForwardPort) {
        self.init(router:router,execute:{try await rooms.execute($0,deadline:$1)})
    }
}
