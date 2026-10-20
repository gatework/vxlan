# VXLAN 修复建议

采集 `collect` 默认保存逐设备诊断与只读核查命令。只有指定 `--scripts` 才导出候选配置、回退草稿和受支持的类型化执行计划；诊断/导出均不连接额外设备、不修改已有报告：

```sh
bundle exec ruby bin/vxlan review --batch /absolute/path/to/batch --scripts
# 可指定独立的私有输出根目录
bundle exec ruby bin/vxlan review --batch /absolute/path/to/batch --output /private/reviews
```

默认输出到 `<batch>/reviews/<UTC时间>/`。退出码 0 表示建议文件生成成功，不表示网络健康或故障已修复；2 表示参数、输入结构或发布错误。

输出采用与 net-connector topology 一致的批次分工（`summary.json` 的 `layout_version: 3`），不生成 Markdown 报告：

```text
<批次>/
  summary.txt            总览、设备入口、Fabric 差异
  summary.json           完成状态、计数、来源与产物索引
  plan.json              所有设备诊断、Fabric 证据、按 ID 索引的单项增量
  plan.json.sha256       聚合计划校验
  events.jsonl           本次审查事件，明确 executed: false
  devices/<设备>-<IP>.txt 每台一份诊断、前提、影响、回退和验收步骤
  evidence/<设备>-<IP>.json 采集证据，仅供程序回放和审计
  scripts/<设备>-<IP>.cfg 仅 --scripts 且有候选命令时生成
```

先读总览，再定位设备，最后审阅配置建议并选择计划项。没有建议的设备也保留一份简短诊断，避免“未命中”与“未审查”混淆；不会生成空配置文件。离线审查没有设备会话，因此不伪造 `logs/`。在线采集的原始结构化快照继续保存在 `evidence/*.json`，审查通过来源哈希引用它们。

`devices/` 只放用户阅读的 TXT；机器证据集中到 `evidence/`。开发阶段统一使用新结构，离线 `review` 只读取 `evidence/*.json`，不支持旧目录回退。

编排顺序：输入校验 → 单设备诊断和 Fabric 比较 → 合并建议 → 设备文本与候选脚本 → 聚合计划/哈希/事件 → 最后确认摘要完成。在线收尾将审查摘要嵌入采集摘要的 `review` 字段，保留采集完整性状态。计划中的 `audits` 保存完整建议，`fabric` 保存共同业务差异及覆盖，`changes` 只包含受支持的单项增量。

候选 cfg 保留设备命令；条件回退以注释保存。cfg 用于审阅，不是 apply 的输入。自动化读取 summary.json 和 plan.json，不再依赖旧版 recommendations/data/plans 目录。下发只接受带校验文件的聚合计划及明确的计划 ID，不接受独立单项文件。

`candidate` 是有本机证据支持、仍需确认业务意图的候选；`blocked` 缺少关键参数或有冲突；`investigate` 是定位、补采或核对设计的任务。空响应和部分配置不会推导“配置不存在”。所有目录 0700，文件 0600，可能包含内部设备及终端信息。

应用候选前重新采集并核对证据、版本、拓扑和审批窗口；原报告 SHA256 只用于定位本次证据，不能证明设备当前状态。分项验证效果；若命令超时或效果不明，先回读，不能自动重放。回退只在确认本次增量已生效且无并行修改时使用，业务通断须另行验收。只有独立 `apply` 命令可以下发受支持的类型化计划，且必须通过下述交互确认；不会自动保存 running-config。

支持配置规则：VLAN/NVE/EVPN/VRF 关联缺失及层次冲突。只有完整配置、唯一 VLAN、明确 L2 角色、本机一致的 BGP 复制和 auto RD/RT 策略满足时，生成条件性的增量候选；缺 VLAN、混合 RT、未知 VRF 等保留待补参数。存在 VLAN 映射但缺少 NVE/EVPN 时一起补齐候选，回退只删除新增子节点。

运行规则覆盖 NVE VNI、NVE peer、BGP 未建立状态。当前不提供完整 underlay/vPC 健康审计，也不根据主机名或默认 fabric_key 推断跨设备一致性。

命令语法参考：[Cisco NX-OS VXLAN BGP EVPN](https://www.cisco.com/c/en/us/td/docs/dcn/nx-os/nexus9000/103x/configuration/vxlan/cisco-nexus-9000-series-nx-os-vxlan-configuration-guide-release-103x/m_configuring_vxlan_bgp_evpn.html)。现场软件版本及业务设计仍须核对。

## 交互式下发

```sh
bundle exec ruby bin/vxlan apply --plan /path/to/batch/plan.json --item <设备报告中的计划ID> --env-file /path/to/.env
```

必须使用真实终端；不存在 `--yes`，管道输入不能确认。完整展示设备、前提、影响、配置与回退后，需准确输入 `APPLY <IP> <计划SHA256前12位> <计划ID>` 才连接设备。SSH 严格校验已知主机密钥，凭据沿用 NC_DEVICE_* / 平台 NC_*；使用统一目录顺序加载 `.env`，`--env-file` 覆盖所发现的文件，进程环境变量始终优先。

确认后先重读完整配置并核对已解析配置事实的指纹和动作前提；已解析事实变化、部分证据或未经支持的动作均拒绝写入。指纹不覆盖解析器尚未建模的配置行，不能替代全量配置审查。文件中的命令会由类型化动作重新渲染核对，不能编辑为任意脚本。每条命令前持久化意图，执行后保存回执状态。失败或中断立即停止并标记 uncertain，不自动重试、重连或回退；先人工回读确定实际效果。

成功只表示目标配置回读符合计划，仍需业务流量验收。执行日志位于 `vxlan-executions/<UTC>/execution.json`，包含计划摘要和步骤状态、不含密码或原始回显。回退草稿只供审阅，不提供自动执行入口；计划也不执行保存配置。

回读还会比较执行前后的已建模业务上下文：只有所选动作涉及的字段允许变化。若补齐 VLAN/VNI 的同时既有 ACL、Anycast MAC 或其他配置变化，即使命令回执成功、目标关联出现，也保留 uncertain。新建目录的父目录同步失败时，在连接设备前停止。

聚合计划必须用 `--item` 明确选择一项；无选择或未知 ID 都不会连接设备，确认文本同时绑定整个文件哈希、目标和所选项。先核对同目录 `plan.json.sha256`，文件改变会拒绝执行。每次仅执行单设备单项增量。应用一项后同设备其他旧计划会因配置指纹变化而过期，应重新采集/审查生成新计划，不能连续盲目运行旧计划。跨 Leaf 的参考事实来自报告批次；本入口只重新验证目标设备，参考设备、版本支持和业务意图仍由确认人核对。

## Fabric 业务一致性

```yaml
fabrics:
  example:
    leaves: [192.0.2.11, 192.0.2.12]
    borders: [192.0.2.21, 192.0.2.22]
    spines: [192.0.2.31, 192.0.2.32]
```

```sh
bundle exec ruby bin/vxlan review --batch /path/to/batch --fabric-policy /path/to/fabrics.yml --scripts
bundle exec ruby bin/vxlan collect --config /path/to/vxlan.yml --fabric-policy /path/to/fabrics.yml --scripts
```

配置 YAML 可声明 `fabric_policy: fabrics.yml`，路径相对配置文件。策略明确列出 Leaf、Border、Spine，未使用的角色可以省略；地址不能重复或跨 Fabric/角色。任何成员配置不完整均阻止该 Fabric 的跨设备计划，未归属设备和缺少证据的成员在总览中显式列出。框架不把主机名或默认 fabric_key 当成权威边界。

Leaf 和 Border 分别比较已部署相同 VNI 的 VLAN/SVI、IPv4 网关、VRF、Anycast 模式/MAC、MTU、启停和 ACL 方向、定义、有序规则；Spine 出现 L2 业务承载时提示角色冲突，停止其候选生成。业务目录联合 VLAN、NVE、EVPN 识别已开始部署的业务，区分完整、不完整与未部署，不要求所有 VLAN 铺满所有 Leaf。复制方式（包括继承的全局组播）、EVPN RT 和租户路由声明也参与一致性检查；这些约束冲突时不再叠加网关或 ACL 变更。`summary.txt` 汇总业务问题，`plan.json` 保留完整对比事实，逐设备方案位于 devices/。ACL 序号重排、备注不当作转发语义差异；规则顺序保留，协议/端口别名未做等价求解。

当前可交互执行的 Fabric 增量：补挂内容一致的 IPv4 SVI ACL、补建缺失 ACL 后挂载、补齐无网段冲突的单个网关地址，以及为已有 VLAN 补齐缺失的 VNI 关联。关联补齐要求同业务其他成员全部完整且一致、本机只有一个符合网关/VRF/Anycast/ACL 的未映射 VLAN、已有 NVE/EVPN 匹配，并通过整个 Fabric 的跨 VNI 网段重叠检查；不会根据 VNI 数字猜测 VLAN，也不创建 VLAN。不覆盖已有 ACL、修改 VRF 或迁移网关。少数节点已有 ACL 并不证明其业务意图正确：候选明确要求确认统一策略；同名 ACL 内容冲突时全部保留待决，不散播任一版本。

现场策略 `bin/fabric-policy.yml` 覆盖 CKG3、SHA2、SZX8、SZX9 的 83 台设备：67 台 Leaf、8 台 Border、8 台 Spine；部署范围按用户确认保留。业务边界、部署目录、关联推导和有限变更分别由 `Fabric::Scope`、`Service::Catalog`、`Service::Mapping`、`ChangePlan` 承担，`Fabric::Review` 编排规则，报告层只呈现结果。EVPN/NVE 候选仍只导出审阅草稿，不自动转换成可执行计划。

命令依据：[Cisco NX-OS IPv4 ACL](https://www.cisco.com/c/en/us/td/docs/dcn/nx-os/nexus9000/103x/configuration/security/cisco-nexus-9000-nx-os-security-configuration-guide-103x/m-configuring-ip-acls.html)。现场版本、TCAM/资源支持与业务允许/拒绝流量须在维护窗口验证。
