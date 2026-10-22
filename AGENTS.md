# VXLAN 开发指南

本文件适用于本仓库；更深目录的指南可补充局部约定。修改前核对 Git 状态，保留暂存、未暂存及未跟踪工作。

## 职责与结构

- `CiscoNxos::Parsers` 和 `syntax/` 解析 NX-OS 文本；保留镜像 CLI 命令的文件名、类型和目录，不为命名统一改动这些入口。
- `Config`、`RuntimeParser`、`ParserRegistry` 选择配置/运行解析策略；`ConfigurationState` 关联配置事实，不负责连接、资产持久化或健康策略。
- `Collector` 借用连接器提供的会话；`ctx_driver::Reader` 处理单命令回执，底层 net-connector/expect-pty 管理设备对话、IO 与进程。
- `Observation`、`Snapshot` 保存不可变事实和来源；`Config::Evidence` 规定完整配置证据边界。
- `Service::Catalog/Mapping`、`SubnetIndex`、`AclPolicy` 表达业务身份与依赖；`Fabric::Scope/Review` 只比较明确 Fabric/角色内已部署的业务。
- `Recommendations` 提供待确认建议；`ChangePlan` 仅处理支持的类型化增量；CLI 的 parse/collect/review/apply 负责宿主编排和私有报告。

## 核心契约

- 完整采集、完整语法解释、Fabric 一致性与业务健康分别表达。空表、未请求、部分输出和功能未配置不能混为成功。
- 缺失推导及变更计划要求唯一、完整且完成配置审查的记录；部分事实仍可报告已观察到的问题。
- 单设备顺序采集，不重放失败命令；断链后跳过剩余查询，保留已经完成的证据。借用会话不主动连接或关闭。
- Fabric 与角色由显式策略确定，不按地址相似性、设备多数或配置相同猜测。地址组只比较引用该对象的设备，保留未定义依赖。
- ACL 身份包含有序动作及依赖对象；未知依赖不能证明一致。网段冲突限定 VRF、地址族、VNI 及接口范围。
- 外部回调前固定请求与来源；不可变结果不能共享调用方的可变容器。处理字节、编码与文本时使用显式分隔符，不依赖 `$;`、`$/`、`$,`。
- apply 先回读并核对配置指纹，再执行明确选择的单项；失败后不自动回退或重放，CLI 成功不代替配置回读及业务验收。
- 报告目录 0700、文件 0600；原子替换和目录同步分开处理，持久性未确认不能发布 complete。错误、inspect 和报告诊断不展开凭据或原始配置。

## 开发与验证

- 使用 `.ruby-version`、gemspec 和锁文件指定的 Ruby/Bundler，沿用 RuboCop、中文代码注释与现有 RSpec 习惯。
- 根目录 `bundle exec rake` 执行完整测试、lint、离线示例和 CLI 帮助；macOS shell 选错系统 Ruby 时用 `zsh -ic 'bundle exec rake'`。
- 复用已有测试，缺陷先复现；跨层改动同时核对成功、部分失败、取消、资源所有权和副作用，不以内部方法调用替代行为断言。
- `benchmark/tables.rb` 测解析/关联，`benchmark/fabric.rb` 测完整 Fabric 审查。用 `bundle exec ruby -Ilib benchmark/fabric.rb`；基线通过 `-I/path/to/baseline/lib` 加载独立副本，核对输出的来源路径。合成基准不代表实机或网络收益。
- `bundle exec rake build` 后运行 `ruby script/verify_package.rb pkg/vxlan-<version>.gem`；脚本另支持连接器和 expect 候选包。源码联调与隔离安装分别验证。
- CLI 修改后从实际 checkout 运行普通入口；不要只靠额外加载路径掩盖安装或配置错误。
- 更新 CHANGELOG 和相关文档。审查/修复不自动授权提交、推送、发布或改变仓库可见性。

## 公共业务流程

采集会话约束、共享查询与事实外壳由 `ctx_runner` 提供；VXLAN/Wireless 的批量交付、报告检查点和变更执行也由 Runner 统一维护。领域规则、厂商命令、健康评估及操作租约留在当前模块，不复制公共状态机。

源码联调使用 `CTX_RUNNER_PATH=../ctx_runner bundle exec rake`；普通安装验证不设置该变量。首次发布依赖顺序为 ctx_parser → ctx_driver → ctx_runner → 消费模块。未发布 Runner 时先构建安装候选包，隔离包验证显式传入候选，不能依靠相邻源码路径。

## 公共 CLI

配置读取、私有初始化、终端边界和公共参数使用 ctx_cli；不要复制对应实现。领域策略与设备能力留在当前仓库，ctx_runner 继续决定业务完成状态。`CTX_CLI_PATH=../ctx_cli` 显式源码联调；普通入口与安装验证使用候选 gem，不能隐式探测相邻目录。
包验证的第五个位置参数为 ctx_cli 候选；前四个仍为当前包、net-connector、expect-pty、ctx_runner。首次发布前须构建安装依赖候选；未发布版本不得靠在线索引假定可用。
