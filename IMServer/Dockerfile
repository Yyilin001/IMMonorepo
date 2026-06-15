# ================================
# 构建镜像
# ================================
FROM swift:6.1-noble AS build

# 安装操作系统更新
RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get install -y libjemalloc-dev libssl-dev libsasl2-dev

RUN git config --global http.version HTTP/1.1 \
    && git config --global url."https://gh-proxy.com/https://github.com/".insteadOf "https://github.com/"

# 设置构建目录
WORKDIR /build

# 先只解析依赖。
# 这样会创建一个可复用的缓存层，
# 只要 Package.swift/Package.resolved
# 文件没有变化，就可以重复利用。
COPY ./Package.* ./
RUN --mount=type=cache,target=/root/.cache/org.swift.swiftpm \
    swift package resolve \
        $([ -f ./Package.resolved ] && echo "--force-resolved-versions" || true)

# 将整个仓库复制到容器中
COPY . .

RUN mkdir /staging

# 构建应用，启用优化、静态链接，并使用 jemalloc
# 注意：jemalloc 的静态版本与 Swift 静态运行时不兼容。
RUN --mount=type=cache,target=/build/.build \
    swift build -c release \
        --product IMServer \
        --static-swift-stdlib \
        -Xlinker -ljemalloc && \
    # 将主可执行文件复制到暂存目录
    cp "$(swift build -c release --show-bin-path)/IMServer" /staging && \
    # 将 SPM 打包的资源复制到暂存目录
    find -L "$(swift build -c release --show-bin-path)" -regex '.*\.resources$' -exec cp -Ra {} /staging \;


# 切换到暂存目录
WORKDIR /staging

# 将静态版 Swift 回溯工具复制到暂存目录
RUN cp "/usr/libexec/swift/linux/swift-backtrace-static" ./

# 如果目录存在，则复制 Public 目录和 Resources 目录中的资源
# 默认确保该目录及其内容都不可写。
RUN [ -d /build/Public ] && { mv /build/Public ./Public && chmod -R a-w ./Public; } || true
RUN [ -d /build/Resources ] && { mv /build/Resources ./Resources && chmod -R a-w ./Resources; } || true

# ================================
# 运行镜像
# ================================
FROM ubuntu:noble

# 确保所有系统包都是最新的，并且只安装必要的软件包。
RUN export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true \
    && apt-get -q update \
    && apt-get -q dist-upgrade -y \
    && apt-get -q install -y \
      libjemalloc2 \
      ca-certificates \
      tzdata \
      libcurl4 \
# 如果你的应用或其依赖导入了 FoundationNetworking，也需要安装 `libcurl4`。
      # libcurl4 \
# 如果你的应用或其依赖导入了 FoundationXML，也需要安装 `libxml2`。
      # libxml2 \
    && rm -r /var/lib/apt/lists/*

# 创建一个以 /app 为主目录的 vapor 用户和用户组
RUN useradd --user-group --create-home --system --skel /dev/null --home-dir /app vapor

# 切换到新的主目录
WORKDIR /app

# 从构建阶段复制已编译的可执行文件和暂存资源
COPY --from=build --chown=vapor:vapor /staging /app

# 提供内置崩溃报告器所需的配置，并设置一些合理的默认行为。
ENV SWIFT_BACKTRACE=enable=yes,sanitize=yes,threads=all,images=all,interactive=no,swift-backtrace=./swift-backtrace-static

# 确保后续所有命令都以 vapor 用户身份运行
USER vapor:vapor

# 让 Docker 绑定到 8080 端口
EXPOSE 8080

# 镜像运行时启动 Vapor 服务，默认在生产环境监听 8080 端口
ENTRYPOINT ["./IMServer"]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
