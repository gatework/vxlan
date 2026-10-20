# VXLAN CLI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement task-by-task.

**Goal:** 将现有脚本实现迁入 lib，提供可安装 bin/vxlan，并清理旧文件。
**Architecture:** Vxlan::CLI 延迟分发 collect/parse；五个实现直接迁移，无代理兼容层。examples 为薄入口。
**Tech Stack:** Ruby >=4.0.6、RSpec、OptionParser、现有 Collector/net-connector。
**Spec:** docs/superpowers/specs/2026-10-19-command-line-design.md

## Global Constraints
- 保留当前全部 WIP，不提交、不发布、不连接设备。
- 依赖选择未收到回复，本次维持 net-connector/dotenv 可选安装约定；CLI 不强制加载连接器。
- 本会话直接执行；使用完整 WIP 隔离副本，结束前检查源文件哈希后回传。
- 退出码 0/1/2/130、报告及线程回收语义保持。

## Review Focus
- 外部 cwd：安装入口默认文件在用户目录。
- 自定义 YAML：相对路径按 YAML 所在目录。
- 源码脚本：保留项目根路径约定。
- 只加载 CLI/解析：不加载连接器、不读取凭据。
- 安装包：模板完整、真实可执行入口可用、初始化不覆盖。

### Task 1: 正式入口与迁移
Files: lib/vxlan/cli.rb、lib/vxlan/cli/*.rb、examples/*.rb、spec/cli/*。
Interface: Vxlan::CLI.run(argv, env:, out:, error:, input:, **collect_options) -> Integer。
- [x] 新增 spec/cli_spec.rb，验证帮助/版本/未知命令/离线解析/无提前加载；运行观察失败。
- [x] 迁移五个实现，Collection 改 Collect，迁移测试至 spec/cli，删除旧路径。
- [x] 实现 CLI.run 与 bin/vxlan；薄示例调用同一入口，保留 require 无执行。
- [x] 新旧用例通过；不提交。

### Task 2: 路径、模板与打包
Files: cli/options.rb、cli/templates/*、vxlan.gemspec、script/verify_package.rb、spec/cli_spec.rb。
Interface: Options/Collect 接受 config:, env_file:, directory:, base:, command: 可选关键字；base 默认 nil 表示 YAML 目录。
- [x] 新增外部 cwd 初始化、YAML 相对路径与源码路径测试；观察失败。
- [x] 模板单一来源；安装默认 cwd，源码显式旧默认，帮助显示实际入口。
- [x] gemspec 登记 bin/vxlan、模板及直接使用的标准库；保留可选网络依赖。
- [x] 构建、隔离安装，在 GEM_HOME/bin/vxlan 验证帮助/版本/parse/初始化/静态清单。

### Task 3: 文档与完整验证
Files: README*.md、examples/README.md、CHANGELOG.md、设计状态。
- [x] 文档改为正式 CLI 与薄示例职责、清楚说明两种路径默认及可选依赖。
- [x] 完整 rake、gem build、隔离安装、独立审查；修复重要问题后重复相关检查。
- [x] 哈希保护回传所有新增/修改/删除文件；源目录再次 rake、残留引用检查。

## Ledger
Ruling: 用户继续完善视为执行授权，沿用本会话直接实施方式，不重复询问方案审批。
Ruling: 保留可选依赖，不以未回复问题阻塞可独立完成的目录和入口重组。
Pre-flight: Task 2 consumes Task 1 Collect keyword interface; 同步迁移调用与测试，默认 base:nil。

Task 1: complete — baseline 248/0；入口 RED 3/3 failed，迁移后全部通过。原支持类测试迁入 spec/cli，parallel/report 主体仅命名空间调整。
Task 2: complete — 路径 RED 5 failed；正式入口、模板、标准库依赖与 package 检查已实现。macOS /var→/private/var 的 cwd 实路径在测试中按 File.realpath 比较。
Task 3: complete — 255/0、70 lint clean；构建及隔离 GEM_HOME 安装成功，正式入口及源码示例通过；原始 RubyGems connector 0.14.1 下 49/0。
Review: fresh-context reviewer independently ran 49/0，没有实现重要问题；发现源码 bundle exec vxlan 文档无法找到命令，已实际验证并改用 bundle exec bin/vxlan。
Ruling: 使用完整 WIP 隔离 clone 而非干净 HEAD worktree，确保未提交入口与测试一并保留；无提交/重置/暂存。

Ruling: .gitignore 同时覆盖正式入口在仓库启动时生成的 /vxlan.yml 与 /vxlans/，避免新默认路径留下未忽略的现场产物。

Final: 38 个新增/修改/删除文件已按基线哈希校验回传；未涉及的原 WIP 哈希完全保留。源仓库 rake 255/0、70 files lint clean；git diff --check 通过。只读安装目录下的正式命令验证成功；未提交、未发布、未连接真实设备。

## Follow-up: bin 与参考 examples 的操作体验

用户明确选择统一 vxlan collect/parse、启动目录默认配置/.env/报告，已有 bin/.env 与 bin/vxlan.yml 保留。
- 完成 -h/--help-all/--examples、--plan/--inventory-only、--no-progress/--quiet、强制交互终端检查与初始化退出提示；启动进度显示实际配置路径。
- 对齐空白 VXLAN_CONFIG 的默认回退（进程与 .env 均覆盖）；回归先失败再修复。
- 正式使用说明集中 bin/README.md，examples 只说明薄示例；模板仍单一来源，包文件白名单只允许 bin/vxlan 与 bin/README.md。
- bin 现场配置和报告忽略；既有现场文件内容哈希保持一致。
- 验证：259 examples/0 failures，70 files lint clean，构建与只读安装目录下正式命令 smoke 通过。RubyGems 安装后的 gemspec 不保留完整 files，因此包清单由 Gem::Package.spec 检查，安装后使用实际文件存在检查。

Independent follow-up review: CLI/文档未发现阻断问题；发现并修复 package verifier 环境隔离与 installed spec.files 断言问题。对照测试：旧脚本在受控 VXLAN_CONFIG 外部临时路径写入且 exit1；修复后清理 VXLAN_*、NC_PARALLEL，带污染环境完整隔离安装 exit0，外部临时配置/报告均未创建。最终 rake 259/0、70 lint clean、diff check clean，现场文件哈希不变。
