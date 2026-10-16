> 本文保留模块从 Motor 提取前的领域设计、覆盖范围、限制与验证记录，供兼容迁移和故障分析使用。
> 当前独立 gem 的安装、依赖、开发与发布入口以 [README-zh.md](../README-zh.md) 为准。
> 涉及 `Motor::*`、`Sync`、`Baseline::Check`、数据库、Rails、Rake 运维任务及私有实机证据的内容均属于 Motor 宿主集成，不随 gem 提供；历史验证记录不代表当前用户设备已经验证。

# VXLAN 设备采集与入库

这个目录保存 Motor 自有的 VXLAN 业务实现，参考 Netstack 的 NX-OS 能力和已验证的完整性规则，提供配置关联核验，不搬入 Fabric 规划、报表、CLI 或远程下发引擎。Rails 通过 `config.paths` 自动加载 `lib/vxlan`；数据模型仍使用现有 `Motor::Vxlan*` 类和 Rails 可推导的关联。不新增数据表；prefix-list 以节点、名称、地址族作为唯一身份，已有记录默认 IPv4。

## 业务链路

```text
Motor::Device
  → Motor::Devices::Connector（凭据、平台、严格主机密钥、超时、会话生命周期）
  → CtxDriver::Reader（net-connector 单命令采集边界）
  → Vxlan::Collector（同一设备逐条读取）
  → Configuration / RuntimeParser / L2routeParser（维度与 Observation 适配）
  → CiscoNxos::Profile / Parsers::Show*（平台与型号策略、按命令解析）
  → Snapshot / Observation
  → Vxlan::Sync（锁设备、复核来源与版本、事务）
  → ConfigurationInventory / L2routeInventory / vxlan_segments
```

采集通过 [`CtxDriver::Reader`](https://github.com/gatework/ctx_driver) 使用 net-connector 的 `send_commands`，统一验证单命令响应、记录来源摘要并隔离失败；不自己实现 SSH、提示符处理或登录。单脚本解析异常不丢弃已完成维度，断线后标记剩余命令 skipped。配置下发继续由 `Motor::Devices::Script` 和 Netconf 的审批快照、执行认领及设备复核负责；执行开始后的未知结果保留为未知，不自动重放。采集任务不隐式下发配置、自动保存 running-config 或修改设备配置。

## 调用

```ruby
result = Vxlan::Sync.new.call(device: Motor::Device.find(device_id), fabric_key: "LAB")
result.counts
result.observation.complete?

# 仅刷新两类 L2RIB 路由；其他维度保持原有证据和数据。
Vxlan::Sync.new.call(device: device, fabric_key: "LAB",
  dimensions: %i[l2route_macs l2route_mac_ips])

# 离线解析不建立设备会话，不写数据库。
observation = Vxlan::Configuration.new.parse(configuration_text, complete: true)
observation.status
observation.records
```

保留已有运维入口，避免现有调用脚本失效：

```sh
bundle exec rake 'motor:netstack:vxlan[456,LAB]'
```

默认支持 Cisco NX-OS 的配置、CDP、NVE peer/VNI、BGP EVPN 邻居、OSPF 邻居、vPC、接口、Port-channel、MAC 地址表、L2RIB MAC 和 MAC-IP。命令集中在 `Collector::COMMANDS`。新增设备输出格式时，应先补脱敏 fixture 和完整/截断用例，再修改对应解析器；不能把未知输出判定为空结果。

Cisco N9K 的具体策略位于 [`lib/vxlan/cisco_nxos`](../lib/vxlan/cisco_nxos/profile.rb)，按命令拆分为 `parsers/show_ip_ospf_neighbors.rb` 等独立文件。直接调用 `Vxlan::CiscoNxos::Parsers::ShowIpOspfNeighbors.parse(cli_output, complete: true)` 即可离线解析。`ParserRegistry.fetch(:cisco_nxos, model: device.model)` 选择平台与型号策略；命令清单和解析类统一在 `CiscoNxos::Profile` 中声明。原解析入口继续转换为 `Vxlan::Observation`。公共接口、结果对象和扩展方式见 [`../ctx_parser`](https://github.com/gatework/ctx_parser)。

配置解析按职责组合：`ShowRunningConfig` 编排命令解析，`ConfigurationParsing::Interfaces/Routing/Policies` 分别解释接口/NVE、路由上下文及策略语法，`CtxParser::ConfigurationParser` 管理逐行状态、嵌套来源路径与捕获，`CiscoNxos::Configuration` 在全部块解析后归约特性列表、校验 BGP 模板引用并关联 SVI/VLAN/VNI 网段。接口地址与网段使用 `CtxParser::Values.ipv4_prefix` 的同一校验。重复身份仍排除歧义记录；语法未知、引用不完整与来源行号继续进入原有 `Result`，供入库边界判断。

设备连接默认关闭旧版 SSH 算法协商。确认单台旧设备确有算法兼容需求后，可在其现有 `settings["connector"]["legacy_ssh"]` 中显式保存布尔值 `true`；省略或 `false` 保持关闭，字符串、NULL 等非布尔值会在连接前拒绝。该设置直接传给 net-connector，主机密钥仍严格核验 `storage/net_connector/known_hosts`，不启用 Telnet 回退。连接异常仅保留允许列表中的诊断码（例如 `unsupported_host_key_algorithm`），未知码归为 `connection_failed`；VXLAN 未采集维度保存该原因，不保存底层异常文案或 cause。

## 数据一致性

设备 I/O 在数据库事务外完成。入库时锁定已有设备，复核设备版本、节点来源、Fabric 及原快照；并发期间已变更的设备或节点、旧结果和同时间不同结果均拒绝写入。节点证据和所有派生清单在同一事务提交，任何写入失败全部回滚。重复投递相同快照保持现有行身份，也可重建缺失的派生行。

配置的 vPC、Underlay、Overlay、VNI、features、prefix-list 只在完整配置时刷新。三层网段同样只在完整配置时更新和清理。部分配置保存在节点证据中，不能把未读到的 anycast、ACL 或被截断的前缀覆盖到权威清单。L2RIB 两种路由各自判定完整性，部分结果保留旧可选字段并合并下一跳，完整结果才清理该类型缺失行。配置失败不阻止已成功采集的运行路由入库。

`vxlan_nodes.observations` 的每个维度保留 `latest`；新结果不完整时额外保留 `last_complete`。未请求维度不变。新 VXLAN 观察统一使用 `name/status/records/issues/evidence/started_at/completed_at`；既有历史 JSON 无需回填，后续按维度替换，旧 `last_complete` 保持原形状。展示方须同时显示本次状态和旧数据时间，不能把保留数据显示成实时成功。无线与 VXLAN 共用 `Motor::InventoryObservations` 的时间比较和证据合并规则。

配置中的凭据及原始 CLI 正文不持久化。命令证据只保存命令名、字节数和摘要，诊断不附原始配置行。`complete: true` 表示调用者已确认完整接收；解析器仍会因未知语法、歧义身份或不完整输出降为 `partial`。单有表头不能证明空清单。

## 验证

```sh
RAILS_ENV=test bundle exec rspec spec/vendor/vxlan spec/lib/motor/netstack \
  spec/services/motor/devices/script_spec.rb spec/services/motor/netconf/executor_spec.rb
RAILS_ENV=test bundle exec rails zeitwerk:check
bundle exec rubocop
```

测试覆盖离线解析、实际数据库投影、并发冲突及替身设备会话。另有 2026-10-16 全量 83 台 N9K 的真实只读采集及离线重放证据，保存在本机私有 `storage/network-audits`，不把包含凭据的真实配置提交到仓库。

## 配置覆盖与关联核验

NVE 的内联 `member vni ... mcast-group ...` 与嵌套组播声明归一为相同事实；全局 multicast default 仅用于没有显式组播、BGP 复制或 L3 关联的成员。无效组播、冲突成员和未知语法保持 partial。`interface breakout` 单独进入 `breakouts`，不伪装成接口；`no feature` 进入 `disabled_features`。

接口事实包含 MTU、OSPF network type、switchport 模式/access VLAN、L3 VNI `ip forward`；NVE 和 BGP 保留 `advertise virtual-rmac`、`advertise-pip`、`advertise l2vpn evpn`、标准/扩展社区和显式关闭状态。BGP 邻居描述、route-map 的方向和 next-hop-self 的 all 语义保留在正确的 VRF/邻居/地址族中。

`BgpNeighbors` 为 Overlay 投影和策略引用共用模板归约，显式子邻居配置覆盖继承方向；不同 VRF、邻居和地址族的调用位置保持独立。Prefix-list 支持 IPv4/IPv6、address/next-hop/route-source 选择器及邻居/network/重分发/retain/export 调用关系。IPv4 事实继续位于 `prefix_lists`，IPv6 位于 `ipv6_prefix_lists`，历史观察无需重写。

`ip unnumbered` 保留借用接口关系；同 VRF 的唯一 Loopback IPv4 地址归约到 `unnumbered_addresses`。Underlay 清单使用该物理接口和借用的 /32 主机地址，不猜测链路子网。缺失、歧义、循环或跨 VRF 引用保持 partial；IPv6 Underlay 未被伪装成已支持的 IPv4 清单。

NX-OS 的 `ConfigurationDocument` 与 Baseline 共用 `CtxParser::Banner` 状态机，banner 正文不会生成配置事实；EOF 未闭合会产生 `incomplete_banner`。

完整配置的 `review_findings` 输出 VLAN/VNI/NVE/EVPN 关联核查项，不改变语法完整性，也不直接表示运行故障。`review_status` 为 partial 时不根据缺失数据生成关联结论。这样保留“配置收到且语法已理解”和“业务关联需要核实”两个事实。

## Prefix-list 地址族迁移

迁移 `20261016020000` 增加 `address_family`，默认 `ipv4`，由模型和 PostgreSQL 同时约束到 IPv4/IPv6；组合唯一索引允许双栈同名列表。RailsAdmin 列表和详情显示地址族，并提供中英文标签。

部署时先排空旧 VXLAN 采集 worker，执行迁移并切换到新代码后再恢复采集。旧代码只按名称定位列表，不应与已经写入双栈数据的新 worker 重叠。迁移会保留原行身份和数据；存在 IPv6 历史时 rollback 明确拒绝删除地址族，需先导出并协调处理。当前本机 development/test 已执行迁移。
