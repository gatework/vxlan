# vxlan Evidence Contracts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** 沿已有解析和采集链路建立可追溯验收，修复已复现的证据缺口并集中规则。
**Architecture:** 保留 Profile/Registry 与现有 Collector/CLI 职责；仅对证据、身份和发布边界做局部重构。测试样本与预期独立于生产实现。
**Tech Stack:** Ruby、RSpec、RuboCop、JSON/YAML、隔离 gem 安装。
**Spec:** ../specs/2026-10-19-evidence-contracts.md

## Global Constraints

- Ruby >= 4.0.6；本机验证使用 Homebrew Ruby 4.0.7。
- 保留现有 WIP、公开入口和独立 gem 边界；不提交、不发布、不连接设备。
- 私有原文仅在本机临时目录回放；仓库只保存脱敏/官方派生样本与来源说明。
- 用户已要求方案并执行，连续实施，不另设审批阶段。

## Review Focus

- 来源未知样本不能当作实机完整性证明。
- 同一身份的不同文本表达必须遵循明确冲突策略。
- 声明了端口/统计表却没有其必需内容时，不能 complete。
- summary.txt 或 summary.json 失败时，CLI 退出码、stdout 与存盘结果不能声明假成功。
- 声明扩展演练只使用测试替身，不新增业务平台或命令。

## Task 1: 解析契约与独立样本

**Files:** spec/fixtures/evidence/*、spec/evidence_contract_spec.rb；对应现有命令解析器/作用域文件；docs/evidence-contracts.md。
**Interfaces:** 继续使用现有 parse(..., complete:) 和 status/records/issues；输入样本及预期通过 manifest.json 绑定。
- BGP 原始主表/统计表及其 VRF 作用域，重点验证缺失/重复统计及等价 IPv6。
- 配置邻居原始名称与标准地址身份的关系，检查等价写法是否仍绕过配置冲突隔离。

- [x] 盘点历史 fixture 来源；建立 SHA-256、官方来源/派生转换及字面量预期清单。
- [x] 添加缺失证据、等价身份、作用域隔离回归，观察真实失败并记录。
- [x] 局部修复根因，复用已有地址/记录/命令机制；运行相关 RSpec 验证。
- [x] 对选定命令的历史保存回显及旧 fixtures 做修改前后差分，所有差异逐项解释。

## Task 2: 批次报告失败契约

**Files:** lib/vxlan/cli/report.rb、lib/vxlan/cli/collect.rb、spec/cli/report_spec.rb、spec/cli/collect_spec.rb。
**Interfaces:** 保留 finish 返回 summary、现有 Error 安全诊断、退出码 2/130；新增发布状态字段若必要必须文档化。
- [x] 注入 summary.txt/summary.json 的 rename、fsync 故障，检查盘上 JSON、stdout、退出码及已保存设备事实。
- [x] 先观察失败，再调整发布顺序及安全恢复；不重放设备查询，不让恢复覆盖原始取消。
- [x] 运行真实线程池既有取消回归，补充必要的无 sleep 同步用例。

## Task 3: 规则唯一性与验收

**Files:** 现有 parser_registry/CLI options 声明消费点；spec/evidence_contract_spec.rb；docs/evidence-contracts.md；CHANGELOG.md。
**Interfaces:** 规则变更通过既有声明和公共入口传播；不引入新共享 gem 或通用测试框架。
- [x] 用测试声明替身演练平台/维度/别名变化，发现并消除实际重复规则。
- [x] 在临时源码副本中种入关键错误（绕过完整性/身份/发布校验），定向测试必须检测到；记录补丁和结果。
- [x] bundle exec rake、build、script/verify_package.rb、git diff --check；记录运行版本及加载来源。
- [x] 新上下文独立审查后修复重要问题；填入证据矩阵及未验证边界。

## Execution ledger

开始前基线源码已复制到本机临时目录，供差分与变异比较；本文件随执行更新，不依赖提交范围追踪 WIP。

### 进展与裁定

- Task 1: complete。新增独立预期样本回放成功；缺陷先红后绿；历史原文正确去除回执框架后差分 0。
- Task 2: complete。报告文本/最终 JSON/目录同步/持续 ENOSPC/取消/重复 finish 回归通过；独立审查补出的三类缺口均修复。
- Ruling: 最终写入未提交时不重复恢复安全检查点；已提交失败和取消才恢复。极端存储拒绝下仅 best effort，保留明确恢复未确认诊断，不能承诺绝对离线一致性。
- Ruling: 不新建通用共享层；别名通过现有 Registry 匹配，配置身份通过局部 canonical 索引复用原有冲突规则。
- Task 3: 全量验收 286 examples / 0 failures，RuboCop 75 文件通过；4 个正式变异被实际断言捕获，负向控制排除非断言异常。严格回放 0 差异。独立审查通过，安装包隔离安装、脱离源码加载、CLI/离线入口和文件清单核验通过；Task 3: complete。
