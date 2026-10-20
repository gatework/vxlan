# 证据契约与验收记录

本轮从代码规范审查收紧到三条纵向链路：解析事实与完整性、失败与报告收尾、声明规则一致性。方案见 [实施计划](superpowers/plans/2026-10-19-evidence-contracts.md)，约束见 [设计](superpowers/specs/2026-10-19-evidence-contracts.md)。已有 WIP 保留，未提交或发布。

## 来源与预期

新增样本和字面量预期见 `spec/fixtures/evidence/manifest.json`。每份样本带 SHA-256、命令、平台、转换说明及来源等级；预期不通过生产辅助方法生成。清单另记录 5 份历史 fixture 的哈希，来源统一标为 `historical_origin_unverified`，不能因测试名称包含 live 就当作已核实的实机样本。

BGP 样本从本机历史保存回显提取，清单原文 SHA-256 经独立审查在 17 份原始回显中唯一匹配。只去除已验证命令回显/提示符，替换 IPv4/AS 身份并规范化数据行空白，保留计数、时长与表边界；设备型号与版本未随来源记录，保持未知。

## 契约矩阵

| 边界 | 不变量 | 原始依据/输入 | 长期验收 |
| --- | --- | --- | --- |
| BGP 统计 | 已展示类型之和不得超过总前缀；允许未展示类型 | 保存回显派生 BGP 主表与统计表，人工逐列字面量预期 | evidence_contract_spec.rb；上下界和 Type-12；upper-bound 变异 |
| 配置身份 | 等价主机/动态前缀共享冲突身份，VRF 分离，事实键保留首次原文 | 合成对抗配置；沿用原 store_unique_fact 与来源失效机制 | evidence_contract_spec.rb；canonical-neighbor-key 变异 |
| 摘要收尾 | 文本未发布或最终 JSON 未提交时不能声明整批完成 | 真实临时文件、rename/fsync 故障注入 | report_spec.rb、collect_spec.rb；checkpoint/recovery 变异 |
| 取消与重复收尾 | 首次异常/取消优先；未提交失败保留安全检查点；旧成功摘要不能冒充新状态 | 最终 rename 后 Interrupt、后续 ENOSPC、重复 finish；Queue/Thread.raise 独立演练 | report_spec.rb、collect_spec.rb、parallel_spec.rb |

## 报告发布规则与能力边界

先原子发布 `incomplete`（或 `interrupted`）检查点，再发布人类可读文本，最后发布最终 JSON。文本显示证据状态并指向 JSON；JSON 为批次状态来源。检查点使用安全代码 `report_finalization_unconfirmed`，设备文件及已获取事实保持独立。

最终写入尚未替换时保留原检查点，避免多余恢复 I/O 反而破坏它。已经替换后同步失败或发生取消时，尽力恢复检查点；新一次 finish 若无法建立检查点，旧 complete 摘要尽力失效。恢复与删除均失败时 `Report#recovery_failed?` 为真，CLI 输出明确诊断，仍保留原始异常/退出码（持久化失败 2、取消 130），不重放设备查询。

**此协议不承诺存储拒绝所有恢复/删除时的绝对一致性。** 此时盘上旧 complete 仍可能存在，不能忽略本次非零退出码及恢复未确认诊断。删除也未增加目录同步保证，不能据此推断崩溃后的持久状态。两独立 gem 保留同构实现，未为去重引入新的共享依赖。

## 可复现验证

```sh
# 测试、静态检查、离线范例
bundle exec rake
# 临时副本定向植入错误，原工作树不受修改
bundle exec ruby script/verify_contracts.rb
```

变异运行先验证同一临时副本的基线通过，再要求植入错误后出现实际断言失败；语法/加载异常及零测试不算捕获。输出每个变异的检测结果与失败数。每个失败用例还检查异常类型，要求 RSpec 断言失败且没有非断言异常；各工具自带 NoMethodError 负向控制，确认它不会算作成功捕获。这是定向契约验证，不是全仓变异覆盖率。

```sh
# 只读回放本机已有完整回执，输出哈希和状态，不输出私有正文/设备路径
bundle exec ruby script/replay_evidence.rb /path/to/saved-captures bgp_neighbors
# 对比另一源码快照；输出含实际 library_root，脚本校验加载来源
EVIDENCE_LIBRARY=/path/to/baseline/lib bundle exec ruby script/replay_evidence.rb /path/to/saved-captures bgp_neighbors
```

本轮回放 17 份历史保存回显（17 complete）。原文包含命令回显和提示符，只有首行精确匹配已声明命令、末行符合单行提示符边界时才提取正文；原文/正文哈希分别记录。重构前后所有记录摘要、状态和诊断 **0 差异**。原始输入集合哈希：`0908195283f4ded37fef529396b007d74dc30590c78081de22c560daa290f07f`。私有原文及逐份结果仅保留本机临时目录，未进入仓库或安装包。

## 独立性与未验证范围

独立审查比较本轮起始源码快照与候选实现、重新验证样本预期，并额外复现真实线程二次取消及极端存储故障。新增别名仅为测试演练，不增加业务平台。没有新增设备采集；历史回放和官方样例不等于当前设备固件、SSH、AP 登录或生产部署验收。

## 本轮结果

Ruby 4.0.7：`bundle exec rake` 为 286 examples、0 failures，RuboCop 75 文件通过；4 个正式变异全部被断言捕获，1 个非断言异常负向控制正确排除。严格回放与起始快照 0 差异；独立审查的生产实现与验收工具问题均已复现并关闭。安装包已通过隔离安装、脱离源码加载、CLI/离线入口及打包文件清单验证。
