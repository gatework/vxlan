# ctx_cli 公共命令行能力抽取设计

日期：2026-10-22。状态：本地实现与验证完成；实际接口见 ctx_cli/README.md，验证结果及原有缺口见实施计划。

## 目标与已确认范围

用户希望把 vxlan/lib/vxlan/cli 一类宿主入口中的公共能力抽到独立 ctx_cli，减少 baseline、vxlan、backup、wireless 的样板代码，代码范式与工程规范参照 ctx_parser。

用户已明确：baseline 只迁移现有脚本的公共逻辑，暂不增加 baseline 命令。此次不新增设备能力，不创建远程仓库，不提交、推送或发布。

成功标准是公共行为有一个实现，消费模块保留必要的领域声明和适配；既有命令、参数、配置优先级、报告语义及错误退出行为保持可验证。不能只建一个无人使用的工具库，也不能以统一命名为理由改厂商解析器。

## 当前依据

| 位置 | 已有职责及共性 |
| --- | --- |
| vxlan/lib/vxlan/cli.rb、wireless/lib/wireless/cli.rb | 懒加载分发、帮助、版本、参数错误、注入标准流 |
| 两个模块的 cli/options.rb | 文件发现、公开环境映射、默认值合并、公共参数、初始化、终端检查、领域校验 |
| 两个模块的 cli/parse.rb | 参数解析、帮助/示例、文件或 stdin、元数据/JSON 输出、完整性退出码 |
| 两个模块的 cli/collect.rb | 初始化和预览分支、全批预检、进度、调度、Runner 批次交付、失败和取消收尾 |
| 两个模块的 cli/apply.rb | 终端要求、精确确认及输出相同；计划格式、选择、校验、命令与会话租约不同 |
| net-connector-trunk/lib/net/connector/config.rb | 四类入口共用的配置发现、YAML/.env 安全读取、路径来源、配置快照 |
| net-connector-trunk/lib/net/connector/netdisco/cli/{options,setup}.rb | backup/TFTP/topology 公共选项、终端交互、初始化策略 |
| net-connector-trunk/lib/net/connector/netdisco/config/initializer.rb | 排他创建、私有权限、文件和目录同步，以及备份专有问答 |
| baseline/script/coverage.rb | 已有参数分支、输出和退出边界；矩阵生成属于 baseline |
| baseline/examples/*.rb | 大多直接演示领域 API，基本没有 CLI 框架代码，不能强行包装 |

设计开始时 ctx_runner 已有实现，承接 Collection/Query/Observation/Batch/Report/Execution；本次在它的现有契约上接入。net-connector-trunk 另有清单筛选未提交改动，Inventory::Selection/Filters 继续是唯一筛选实现。所有这些工作均保留，不回滚、不整体覆盖。

baseline/spec/backup_verification_spec.rb 是已有未跟踪测试，但对应 script/verify_backups.rb 当前不存在。它是实施前已存在的独立缺口，不以本次抽取名义补建备份回放产品，也不能把该仓库全套测试称为通过。

实施前已在各实际 checkout、Ruby 4.0.6、当前锁定/安装依赖下验证：VXLAN 的 cli_spec.rb + spec/cli 为 128 examples / 0 failures，Wireless 同范围为 108 / 0；net-connector 的 cli_backup、cli_setup、config_initializer、cli_config 为 45 tests / 476 assertions / 0 failures；baseline coverage --check 为 33 metrics / 8 platforms 且内容最新。baseline 的备份回放 spec 为 4 failures，根因仍是上述脚本缺失。这些是修改前基线，不是 ctx_cli 实现后的验证结果。

## 方案选择

采用独立小型 gem 加明确对象组合：CtxCli 命名空间、显式 require、构造参数注入、普通 OptionParser 扩展块；公共流程只有一个实现，领域策略作为协作者传入。

不采用复制模板作为主要复用方式：它会继续复制错误修复。不采用一个包含所有业务模式的万能 CLI 基类或工作流 DSL：它会让 backup 的成功策略、无线 AP 租约和 VXLAN Fabric 规则变成大量隐式开关。

工程以 ctx_parser 为参照：目录映射命名空间、中文代码注释、英文 RSpec/Changelog、RuboCop Omakase、显式打包清单、离线 examples、独立安装验证、固定 action 提交及发布前验证。明确差异是 ctx_cli 核心最低 Ruby 3.4，开发 Ruby 4.0.6，CI 覆盖两者；这是为了保持 net-connector 已有 Ruby 3.4 契约，而不是提高其最低版本。ctx_cli 不依赖 ctx_parser/ctx_runner，避免把它们的 Ruby 4.0.6 门槛传给 backup。

## 依赖和职责边界

- ctx_cli 只依赖自己直接使用的标准库 gem 和 dotenv。require 不读取配置、不修改 ENV、不消费 stdin、不建目录、不加载设备驱动或 Rails。
- net-connector 依赖 ctx_cli 的宿主配置和终端能力；ctx_cli 不反向依赖 net-connector，避免循环。
- VXLAN/Wireless 显式依赖 ctx_cli；领域核心 require 不加载 CLI，帮助与离线解析不加载网络传输。
- ctx_runner 保留采集、报告检查点、完成判定与执行记账。ctx_cli 仅编排终端入口；Runner/进度/调度器通过协作者注入。
- Inventory::Selection/Filters 保留在 net-connector；不在 ctx_cli 再实现地址、厂商、名称或型号选择。
- baseline 只在现有脚本的宿主入口使用 ctx_cli，核心 Baseline API 不依赖 CLI 行为。若只用于开发脚本，依赖放 Gemfile；不凭空增加核心运行时依赖。

## 公共能力和契约

### Application 与 Command

Application 负责命令分发、全局帮助和版本，命令通过惰性 callable 加载。返回退出码，不调用 exit；标准流与 argv 归调用方所有。入口只声明名称、版本、帮助正文和各子命令工厂。

Command 负责每次解析的新参数快照、OptionParser 调用及帮助/示例短路。构造块接收 parser 和 values，入口在其中追加领域参数；#parse 返回值容器，#informational? 处理信息分支。领域执行与错误退出码留在宿主，不通过继承搜索隐式 hook。

公共参数分组采用普通方法向 OptionParser 注册配置路径、并发、初始化、交互、JSON/进度、帮助等选项。字段名和选项说明可以显式注入。厂商、Fabric、AP、TFTP 和成功策略仍由宿主登记。列表按明确逗号分隔，拒绝空项，不依赖 Ruby 全局分隔符。

### Configuration

从当前 Net::Connector::Config 迁入通用文件加载实现。名称、配置环境键、共享文件名/目录、允许的共享命名空间与字段、路径字段及特殊字面量均由宿主显式给定；公共库不硬编码 vxlan、wireless、backup、topology 的业务字段。

保持 CLI > 进程环境 > YAML > .env > 默认值的有效优先级。文件读取与工具字段转换分开；领域 Options 保留 schema、环境编码和最终校验。数组整层替换，false/nil 与缺失分开；被覆盖的低优先级坏值不提前误报。YAML/.env 相对路径按各自来源解析，命令行路径按启动目录解析。显式文件缺失不能回退。保留来源路径与字段归属，不在 sources 中展示秘密。

保持批次快照、不修改 ENV、不冻结调用方输入、拒绝 YAML 别名/重复键/多文档/.env 命令替换等现有约束。Net::Connector::Config 保留原入口和配置政策作为薄适配，不保留第二份文件加载实现。既有 net-connector.yml、环境变量和默认搜索位置不改名。

### Initialization 与 Terminal

Initialization 只负责发布调用方已经校验的公开配置或模板：目录 0700、文件 0600，先写完并同步临时文件，再排他发布并同步父目录；不覆盖已有文件。普通已有文件、符号链接、目录、竞争创建、取消及发布后同步失败分别处理。发布后的持久性未确认不能返回成功；清理故障不能掩盖原始故障。

备份的逐字段问答和策略验证留在 net-connector 的 Initializer，底层文件发布委托给公共实现。VXLAN/Wireless 的初始化也使用同一实现；仍然在初始化后退出，不读取远端清单或连接设备，不把当前凭据保存进模板。

Terminal 封装真实终端检查、逐行读取、普通问答、隐藏密码和精确 token 确认；不拥有或关闭注入的 IO。默认自动化不读 stdin；backup 的 stdin-credentials 协议继续独占输入。apply 必须检查原有要求的全部终端流，并比较宿主提供的完整 token，不添加 --yes、不截断 token。

### Input 与 Output

Input 统一显式文件或调用方 stdin 的读取，仅关闭自行打开的文件。Output 提供显式 JSON 与文本输出及安全诊断；不推断任意对象的敏感性，不把异常 message/cause 自动串入输出，不把业务结果成功与输出成功混为一谈。

VXLAN/Wireless Parse 使用 Command/Input/Output；维度校验、配置/运行解析分支、平台与 AP 参数、健康说明仍在领域模块。baseline 的 coverage 脚本复用参数与输出边界，生成内容、--check、原退出码及默认写入目标保持一致；不把领域示例里的单句 puts 全部替换为无价值包装。

### Collection 入口编排

公共 Collection 承接 VXLAN/Wireless 已重复的入口顺序与失败收尾，但不实现 Runner 或连接器。它显式接收 adapter、options/progress 工厂、batch 类和标准流。Batch#run/Completion 负责业务收尾；CLI 只映射诊断和退出码。每次 run 创建独立状态，失败不能改写上次批次。

adapter 的协议为：

- inventory(options, progress:)：返回 targets 和筛选前 total；不读取设备凭据。
- prepare(targets, options)：预检全批凭据、端点与资源，返回仅本批使用的上下文；失败发生在报告创建和设备连接之前。
- report(options)：创建领域报告；公共流程据此构造注入的 Runner Batch。
- execute(targets, options) { |target| ... }：使用注入调度器或现有连接器 Pool；返回前必须回收工作线程。
- collect(target, options, context:, progress:)：返回领域 snapshot；每设备会话及 AP/Fabric 等策略仍属于领域。
- after_collect(report, options)：明确的收尾接口；VXLAN 在这里执行现有 Fabric 汇总，Wireless 使用空实现。

options 工厂构造当前领域 Options；Options 暴露现有 informational?/validate_interaction!/load_environment/initialize_files/missing?/load/config/flags/values/sources/public_values 协议。

公共流程是：解析和信息短路 → 文件初始化/加载 → 公开配置或清单预览 → 空清单结束 → 全批预检 → 创建报告 → 调度采集并交付 Batch → 领域汇总 → Batch 收尾 → 输出。错误分类、取消优先级、已完成证据保留和摘要恢复行为以现有消费测试为准。无法保证已回收工作线程的调度器不能使用该协议。

backup/TFTP/topology 不强行接入此采集流程：其 Planner、BackupRun、成功策略、TFTP 回执和归档继续由 net-connector 负责；它们复用配置、选项、交互和初始化能力。apply 只复用终端/参数/展示组件，计划模式、哈希文件、单项选择、ChangePlan 验证与操作租约不移动。

## 实施顺序

1. 保存各仓库初始差异清单，跑现有定向契约，记录既有失败；建立 ctx_cli 的工程、公开边界测试和离线例子。
2. 迁移通用配置读取与安全初始化，保留 net-connector 的旧入口适配；先运行其配置、初始化及 backup CLI 测试。
3. 抽取参数、终端、输入输出和分发；接入 VXLAN/Wireless parse/options/apply，以及 backup/topology 的相应公共片段。
4. 抽取 VXLAN/Wireless Collection 的入口流程，保留领域适配，并使用既有失败、取消、并发和 PTY 回归验证。
5. baseline 只调整 coverage 脚本宿主边界；检查生成的 metric-coverage.md 字节不变及原退出行为。
6. 更新 README、AGENTS、Unreleased、Gemfile/gemspec、候选包校验与联调入口；实际 checkout 和隔离安装分别验证。

源码联调使用显式 CTX_CLI_PATH（沿用现有 CTX_RUNNER_PATH 约定），不自动把相邻源码加入加载路径。不改生产代码偷偷探测 ../ctx_cli。未发布版本先构建并安装候选包；隔离安装脚本显式接受候选 ctx_cli/ctx_runner 包，不假设公共索引已有它们。

## 验收与完成边界

- ctx_cli：RSpec、RuboCop、离线 examples、构建、隔离安装、Ruby 3.4/4.0.6 的可用本地检查；远程 CI 未实际运行时只交付配置，不称 CI 通过。
- 配置：各层覆盖、静态/动态清单优先级、来源路径、空 selector、未知字段、凭据隔离、可变输入和污染的 Ruby 全局分隔符。
- 初始化/终端：帮助零副作用、非 TTY 不消费输入、现有文件不覆盖、竞争/符号链接、私有权限、目录同步失败、精确确认与取消。
- 采集：预检先于副作用、预览不需要凭据、无目标非成功、单设备失败隔离、重复/零次会话回调、线程回收、报告/输出失败、取消优先级和重复运行状态隔离。
- 消费者：VXLAN/Wireless 完整 rake；net-connector script/ci；baseline 现有测试与 coverage --check，已有缺失回放脚本的失败单独报告；不得跳过后把全套称为通过。
- 打包：直接从当前 checkout 运行现有 bin/examples；独立 GEM_HOME/GEM_PATH 安装候选包，清理 Bundler/RUBYLIB 影响，确认加载来源与文件清单。
- 完成说明提供抽出能力、各消费者实际接入点、样板代码减少的前后差异、执行的验证和未验证边界。不声称真实设备效果，不发布版本。

接口内部的小型对象拆分、测试文件布局、必要的错误类型和方法命名由实施者根据现有测试决定；不得借此扩大业务功能、变更 CLI 契约、引入循环依赖或放宽失败判定。
