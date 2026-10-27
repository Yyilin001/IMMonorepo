# 在 Apple Silicon Mac 上交叉编译 Linux 服务端

服务端继续运行在 Linux x86_64 上。Swift 编译器在 Mac 的 ARM CPU 上原生执行，直接生成 Linux ELF；Docker 只负责一次性 SDK 提取、运行验证和镜像打包。无需把整台 x86 Linux 虚拟机用作 Swift 编译机。

## 固定环境

- 开源 Swift **6.4.0** arm64 工具链，安装到 `~/Library/Developer/Toolchains/swift-6.4.0-RELEASE.xctoolchain`。不能替换为 Xcode Swift。
- SDK：`im-resource-swift64-jammy-x86_64`，目标 `x86_64-unknown-linux-gnu`。
- SDK 来源、生成器 revision、运行镜像 digest 和三个关键 Swift 运行库的校验值位于 [toolchain.json](../../scripts/linux-sdk/toolchain.json)。编译前会检查已安装 SDK 的运行库哈希。
- 选择 glibc SDK，使 Swift/Distributed/Foundation 与现有部署镜像一致。Static Linux SDK 的 musl 路线当前因 actor 的 `decodeNextArgument` 分发 thunk 缺失而不能通过完整链接；不向 SDK 注入伪造符号，也不降低并发检查来绕过构建错误。

一次性准备 SDK：

```sh
python3 scripts/prepare_v2_linux_sdk.py --docker-context colima-imv2-x86
python3 scripts/build_v2_linux_release.py --check
```

如果 SDK 已安装且校验通过，准备脚本不启动 Docker、不重新下载。首次生成时需要可用的 Docker、Git 和网络；生成器从固定的官方仓库 revision 构建，再从固定镜像提取 Linux 头文件和运行库。它不会在容器里编译业务源码。其他电脑可使用自己的 Docker context。

## 编译与增量缓存

```sh
python3 scripts/build_v2_linux_release.py
```

默认构建七个部署程序，使用 8 个 SwiftPM 并发任务，持久缓存位于仓库 `.build-linux-glibc-6.4.0`。Swift 优化器内部还可能使用额外线程；`--jobs` 不是进程的硬性 CPU 上限。

脚本不会清理缓存或删除旧产物。每次输出到 `build/native-linux-release/runs/<run>`，只有全部程序成功且源码未发生变化才更新 `current.json`。同一缓存禁止并发启动两个发布驱动。不要在同一份缓存中混用 `/tmp/...` 与 `/private/tmp/...` 两种路径：Clang PCM 中保存的绝对路径可能造成模块重复定义。默认缓存路径固定且规范化。

只验证一个产品时可以使用：

```sh
python3 scripts/build_v2_linux_release.py --product IMV2AccountServerApp
```

部分产品构建不会覆盖完整镜像的 `current.json`。源码变更、工具链、SDK、构建参数和依赖补丁都可能使受影响模块重新编译；不保证任意变更都只需几秒。

输出包含可执行文件、SwiftPM 资源 bundle、未剥离文件的位置与哈希、剥离后程序的哈希、源码快照哈希、构建耗时、ImageMagick policy 和仅打包用的 Dockerfile。剥离时核验程序头及全部可加载段不变，仅允许非运行用 section table 元数据变化。未剥离文件保留在缓存中，可用于符号化；不要在事故分析前手动删除。

## SwiftNIO 的 SDK 导入修正

SwiftNIO 2.104.0 中四处 `fts/stat` 使用在这个交叉 SDK 下需要显式导入定义模块 `_FoundationCShims` 或 `CDispatch`。

[补丁清单](../../scripts/linux-sdk/swift-nio-2.104.0-imports.json) 固定上游 revision、原始文件哈希和修正后的哈希。脚本先按 `Package.resolved` 解析，再仅修改专用缓存里的 checkout；不修改共享 SwiftPM 缓存、仓库 vendored 库或 Xcode 的依赖。revision、原始内容或修正后的内容不匹配时停止，升级依赖必须重新审查补丁。修正只增加导入，不改变文件操作或并发行为。

## Linux 运行验证与镜像

```sh
release_context="$(python3 -c 'import json; print(json.load(open("build/native-linux-release/current.json"))["run"])')"
docker build --platform linux/amd64 -t imv2localaccount-v2server \
  -f "$release_context/Dockerfile" "$release_context"
python3 scripts/verify_v2_linux_release.py "$release_context" \
  --runtime-image imv2localaccount-v2server
```

Dockerfile 不运行 `swift build`，保留现有镜像内程序路径、ImageMagick 限制和运行环境。打包时检查七个 ELF 的动态库，并运行图片 worker 自检。

独立验证脚本复核产物哈希，在无网络的临时 Linux amd64 容器内检查运行库、七个程序的加载依赖，并实际生成 320/1280 两档 PNG 预览和源尺寸信息。它只清理自己创建的临时容器，不操作数据库或线上服务。结果写入产物目录的 `runtime-verification.json`。这证明 Linux 加载与 worker 路径可运行，不代替数据库、选举、鉴权和消息收发的完整验收。

Apple Silicon 上的 `IMV2/scripts/run_v2_local_account_stack.sh` 已接入相同构建脚本；其他宿主机保留原有 Linux 容器构建路径。该脚本会启动本地环境，单纯编译请使用上面的 Python 构建命令。

构建成功不会自动上传镜像、更新 ECS 或发布 TestFlight；部署继续使用独立的健康检查与回滚流程。

## 资料与验证证据

- [Swift 官方交叉 SDK 生成器](https://github.com/swiftlang/swift-sdk-generator)：glibc SDK、固定容器来源以及原生 macOS 宿主。
- [Swift Static Linux SDK](https://www.swift.org/documentation/articles/static-linux-getting-started.html)：工具链匹配要求和 musl 的可移植性边界。
- [本次验证](../verification/native-linux-cross-build-20261027.json)。
