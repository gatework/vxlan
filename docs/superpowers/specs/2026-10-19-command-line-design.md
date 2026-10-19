# VXLAN 命令行组织与发布设计

状态：已实现并通过离线、PTY 与隔离安装验证；取代上一阶段“宿主实现留在 examples/support”的目录选择，保留已经验证的领域与连接器边界。

## 用户目标

正式实现不放在 examples/support；examples 是优雅、简短的使用示例。后续通过 bin 发布后，用户可以直接使用命令。拒绝重复样板，功能专注、简单、容易集成。

本阶段仅组织现有解析/采集能力，提供可安装入口，不新增 VXLAN 配置下发或健康结论。已有未提交内容保留，不连接真实设备、不提交、不上传 RubyGems。

## 目录与职责

```text
bin/vxlan                           # 唯一安装入口，转交 CLI，返回退出码
lib/vxlan/cli.rb                     # collect/parse 分发、全局帮助及版本
lib/vxlan/cli/
  collect.rb                        # 现有 Collection，改为 CLI::Collect
  parse.rb                          # 现有离线入口
  options.rb                        # 采集参数/YAML/环境与初始化
  parallel.rb                       # 宿主有限并发及资源回收
  report.rb                         # 私有文件与批次报告
  templates/vxlan.yml                # 唯一公开配置模板
  templates/env.example              # 唯一凭据变量模板
examples/
  collect.rb                        # 调用同一 CLI，指定源码示例默认路径
  parse.rb                          # 调用同一 CLI
  offline.rb                        # 保留无输入纯解析演示
  README.md                         # 常用用法
spec/cli/                           # 原宿主测试迁入，按职责命名
```

直接迁移已有五个实现文件，不保留 support 代理文件、重复模板或 VxlanExamples 常量兼容层。NativeConnector 仍作为 collect 实现中的小型内部适配器，不新增层、不复制登录或执行逻辑。lib/vxlan.rb 不加载 CLI；显式 require vxlan/cli 才加载命令入口，分发时再加载对应 collect/parse 实现。

CLI 下的 helper 属于应用入口实现，不作为新的领域 API。Ruby 宿主继续调用现有 Collector/collect_session 与 Observation/Snapshot，不要求借用 CLI 或转换结果。

## 使用与接口

```sh
vxlan --help
vxlan --version
vxlan collect --init --non-interactive
vxlan collect --config vxlan.yml --inventory-only
vxlan collect --config vxlan.yml --dimensions configuration,nve_peers
vxlan parse --dimension nve_peers --file nve.txt --complete --json
```

公开分发入口 `Vxlan::CLI.run(argv, env: ENV, out: $stdout, error: $stderr, input: $stdin, ...)` 返回整数，不在库内 exit。bin 只 require 与 exit。示例脚本保留直接运行条件，require 不触发命令。

空参数显示全局帮助并返回0；未知子命令/多余位置参数返回2并给出帮助提示。--version使用Vxlan::VERSION。原有 collect/parse 选项、JSON stdout 与 stderr 进度、退出码0/1/2/130保持。帮助、版本、初始化、静态清单预览不访问设备；帮助和离线解析不主动 require net-connector。

examples/collect.rb 和 bin/vxlan 调用同一个 Collect，不复制业务处理。注入输出、环境、连接工厂/执行器的现有测试接口保留在 Collect，顶层 CLI 不增加第二套依赖注入框架。

## 路径与初始化

- 安装入口默认使用启动目录下 vxlan.yml、.env、vxlans/，从不往 gem 安装目录写配置或报告，也不 chdir。
- CLI显式路径与进程环境中的VXLAN_CONFIG相对启动目录解析；安装入口的YAML相对目录、known_hosts与netdisco_config相对该YAML目录。
- 源码 examples/collect.rb 显式传入原有默认配置、环境、输出及路径基准，使既有 examples/vxlan.yml、根目录.env、examples/vxlans 与项目根相对路径继续可用。使用清晰的关键字参数，不引入Context/Settings包装类。
- 默认值只在Options集中合并；模板只定义公开配置结构，init按入口默认路径生成实际配置，不复制模板内容到examples。已有文件排他保留，0600，初始化后退出。
- 帮助说明实际入口默认值，不再硬编码 ruby examples/collect.rb。源码帮助与安装帮助均有测试。

## 依赖与安装

本次保留现有可选依赖政策：`vxlan.gemspec` 不依赖 net-connector/dotenv。离线用户 `gem install vxlan`；联网或读取环境文件的用户另外执行 `gem install net-connector -v '~> 0.14.1'` 与 `gem install dotenv -v '~> 3.0'`。缺依赖在设备 IO 前提示安装方式。安装方式问题未收到具体选择，因此本次不改变现有依赖关系，后续如需一次安装联网能力再单独调整。

依赖方向仅 vxlan → net-connector，不向连接器加入 VXLAN 业务；纯解析入口不 require 连接器。

CLI直接使用的独立标准库gem按实际require声明（如json、optparse、yaml、fileutils、tempfile、time），不借开发依赖的传递安装。Ruby最低版本仍>=4.0.6，连接器最低版本按已验证0.14.1契约，不采用仅本地工作树具备的内部类。

## 迁移与验收

1. 先固定入口契约回归，再移动现有五个实现文件并改命名空间/require。保留采集、线程回收及报告失败行为，不夹带第二轮功能优化。
2. 添加CLI分发与bin入口；更新gemspec的bindir、executables和模板allowlist。只安装bin/vxlan，examples不登记为可执行文件。
3. 参数路径由显式默认值驱动，验证源码/安装两种上下文、外部cwd与只读gem安装目录、--init不覆盖文件、无环境文件/凭据的帮助和预览。
4. 迁移前248个用例继续通过；测试迁到spec/cli后，不通过examples/support加载产品实现。追加全局帮助/版本/错误子命令、两种入口输出一致、require无执行，以及默认纯解析加载不含net-connector。
5. 更新中英文README、examples说明、CHANGELOG与独立包验证脚本。保留“核心无连接器依赖”断言，验证可选依赖约定。
6. 完整rake、构建与隔离安装验证：真实GEM_HOME/bin/vxlan --help/--version/parse；在用户临时目录collect --init和inventory-only；合成PTY经过正式CLI/Collect；记录实际加载路径。所有验证无真实设备IO。

迁移完成后删除examples/support及旧模板，保留examples目录中的薄脚本与offline演示。新增任何类或转发层都需有现有职责无法直接表达的证据。
