import Vapor

func routes(_ app: Application) throws {
    try app.register(collection: RootRoutes())
    try app.register(collection: HelloController())
    try app.register(collection: AuthController())
    try app.register(collection: IMConversationController())
    try app.register(collection: UserController())
    try app.register(collection: MediaController())
    try app.register(collection: FileController())
}
