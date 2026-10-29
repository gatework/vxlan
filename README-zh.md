# vxlan

[English](README.md) | [源码](https://github.com/gatework/vxlan) | [变更记录](CHANGELOG.md)

以纯 Ruby 解析 Cisco NX-OS VXLAN/EVPN 配置和运行观察。按命令拆分的解析器保留完整性与关联关系，供库存及审查工具使用。

## 能力

- 接口、VRF、VLAN/VNI 映射、NVE、BGP、策略及 prefix-list 配置事实。
- CDP、NVE peer/VNI、BGP EVPN、OSPF、vPC、接口、聚合口、MAC 表及 L2RIB 运行观察。
- 平台/型号策略及公共解析组件。
- 独立命令采集和安全快照，持久化由宿主负责。

## 安装

要求 **Ruby 4.0.6 或更新版本**。在应用的 `Gemfile` 中添加：

```ruby
gem "vxlan"
```

然后执行 `bundle install`；也可直接执行 `gem install vxlan`。Ruby 加载入口为 `vxlan`，公开命名空间为 `Vxlan`；gem 包名与 Ruby 命名空间分别维护。

模块运行依赖：[`ctx_parser`](https://github.com/gatework/ctx_parser), [`ctx_driver`](https://github.com/gatework/ctx_driver), [`ctx_runner`](https://github.com/gatework/ctx_runner), [`ctx_cli`](https://github.com/gatework/ctx_cli)。gemspec 不限制依赖版本；应用应提交经过验证的 `Gemfile.lock`，保持部署可复现。使用本库不需要启动 Rails 或配置兄弟模块的本地路径。

发布产物和校验值见 [GitHub Releases](https://github.com/gatework/vxlan/releases)，已发布版本以 [RubyGems](https://rubygems.org/gems/vxlan) 为准。

## 离线示例

在开发检出目录安装依赖后执行：

```sh
bundle exec ruby examples/offline.rb
```

示例使用合成数据，不访问网络。完整代码见 [examples/offline.rb](examples/offline.rb)：

```ruby
require "vxlan"

# 使用合成 NX-OS OSPF 回显；文档地址不作为实时目标。
output = <<~CLI
  OSPF Process ID UNDERLAY VRF default
  Total number of neighbors: 1
  Neighbor ID Pri State Up Time Address Interface
  192.0.2.2 1 FULL/ - 1d 192.0.2.3 Eth1/1
CLI
observation = Vxlan::RuntimeParser.new(platform: :cisco_nxos).parse(:ospf_neighbors, output, complete: true)
puts "OSPF parse status: #{observation.status}"
puts "Neighbors: #{observation.records.size}"
observation.records.each { |record| p record }
# 单个已解析邻居仅是一项观测，不能证明整个 Fabric 健康。
```

## 正式命令行入口

安装包提供 `vxlan collect` 和 `vxlan parse`，正式实现在 `lib/vxlan/cli/`；`examples/` 保留薄入口与离线演示，两种入口共用实现。

```sh
gem install vxlan
# 联网采集与读取 .env 所需的可选依赖：
gem install net-connector -v '~> 0.18.0'
vxlan --help
vxlan collect --init --non-interactive
vxlan collect --inventory-only
vxlan parse --file running.cfg --complete
```

统一按 `/etc/net-connector` → `/usr/local/etc/net-connector` → `$XDG_CONFIG_HOME/net-connector`（默认 `~/.config/net-connector`）→ 脚本目录 → 启动目录 → 显式文件逐层覆盖。每层可放共享 `net-connector.yml`、专用 `vxlan.yml` 和 `.env`。参数优先级为 **命令行 > 进程环境 > YAML > .env > 默认值**，设备数组整体替换。文件内相对路径按来源目录解析。`--init` 在用户配置目录创建缺失模板，`--show-config` 附带来源路径；报告默认仍写启动目录 `vxlans/`。离线解析与帮助不加载连接器。详见[使用说明](bin/README.md)。

## 公开契约与限制

`Config.new.parse(text, complete: false)` 返回配置观察。`RuntimeParser.new(platform: :cisco_nxos, model: nil).parse(name, text, complete: false)` 返回具名运行观察。`ParserRegistry.fetch(platform, model:)` 提供按命令解析的声明式策略。

传输完整是解析完整的必要条件，不是充分条件。未知语法、身份冲突、不完整引用和无法证明为空的表格保留诊断。配置关联核查与语法完整性、运行健康分别表达。IPv6 prefix-list 事实不代表 IPv6 underlay 库存能力。

`Collector#collect(connector:, target:, fabric_key:, model: nil, dimensions:)` 使用宿主提供的 connector；设备身份、凭据、持久化、库存对账和并发策略由宿主负责。CLI 提供显式范围的 Fabric 审查、可选变更建议及受支持增量的交互下发；核心库独立于 Rails 和数据库。加载库或运行离线示例不会访问设备。

采集器在打开连接前复制目标身份、Fabric 身份和维度选择。`Observation` 的名称必须为 Symbol；`Snapshot` 的维度值必须是名称与键一致的 `Observation`。两种对象的字符串插值均使用只含元数据的 `inspect` 表示。

接口、NVE、路由、VRF 和 vPC 等单值配置发生冲突时，移除歧义字段并保留部分证据。VRF 冲突的接口、配置冲突的 BGP 邻居或模板在推导地址或继承事实前被排除；未解析的 peer-template 不生成邻居投影。不支持的路由嵌套也保持 `partial`。运行回显含分页或终端编辑控制符时，因无法信任行边界，返回无记录的 `partial`。Port-channel 成员冲突检查同时覆盖续行及不同聚合组。

详细厂商语义、历史验证记录和 Motor 专用集成说明保留在[架构参考](docs/architecture-zh.md)。其中宿主集成代码需要 Motor，不属于独立 gem API。适配层位于 [Motor 仓库](https://github.com/gatework/motor/tree/main/backend/lib) 的 `backend/lib/baseline`、`backend/lib/vxlan` 和 `backend/lib/wireless`。

生命周期 connector 是宿主适配器，提供 `open { |session| }`，VXLAN 和 Wireless 还要求 `platform`；原生 `Net::Connector::Base` 实例并不提供这一宿主生命周期协议。已连接的原生会话可传入 `CtxDriver::Reader` 或 `Vxlan::Collector#collect_session`，不会隐式连接或重试。

原生会话由宿主用 `native.with_operation(:vxlan)` 包围整次采集，防止其他任务插入命令。需要在收尾失败后保留事实时，在操作块内登记 snapshot，分别处理关闭或租约退出故障。批量 CLI 拥有此生命周期，报告分别记录已采集证据与文件保存状态；私有目录及取消行为见[CLI 使用说明](bin/README.md)。

`Collector#collect_session(session:, target:, fabric_key:, platform: :cisco_nxos, model: nil, dimensions:)` 可借用已打开的驱动会话，不负责连接、关闭、提权或重连。选中配置时先采集配置，再处理依赖配置的运行维度；结果顺序仍与请求相同。

## 领域术语

NVE 的 `n/a` Router MAC 保留为 `nil`，CDP 的空 `DC_UUID` 也保留未知值。vPC 的 `down*` 解析为 `state: "down"`，同时保留 `forwarding_via_peer_link: true`；仅拼接已识别的同一成员续行。BGP 按表头声明解析已支持的路由类型列，兼容省略重复 `PfxRcd` 的格式，类型统计仍不得超过主表前缀总数。空命令正文、没有明确空表或总数证据的 L2RIB 结果仍为部分证据。

VLAN ID、VNI、VRF、NVE 成员是不同身份。配置审查通过 VNI 关联 VLAN 映射与 NVE 成员，不推断运行可达性。`BgpNeighbors` 枚举应用 peer-template 继承后的配置邻居，不代表已建立的 BGP 会话。`PrefixListReferences` 表达 route-map 选择器及路由使用方的引用关系，引用本身不能证明路由被接受。

关联诊断包括：显式 EVPN 或 VRF 定义与 NVE 成员二层/三层角色矛盾时的 `vni_layer_conflict`，以及三层 NVE 成员没有对应 VNI 的配置 VRF 时的 `nve_l3_without_vrf`。VLAN 映射本身不能证明二层角色，支持通过 VLAN 承载的三层 VNI。这些诊断仅基于完整配置证据生成，不改变语法解析状态。

路由事实保留协议及所属作用域。`network` 必须位于匹配的 IPv4/IPv6 进程或 VRF 地址族中；邻居策略映射属于邻居或 peer-template 的地址族。不支持的路由地址族及位置错误的设置保持部分证据，不生成对应策略使用方。

prefix-list 或 route-map 在同种类、同名称内出现重复序号时，排除该序号的全部声明，后续声明不能恢复。独立序号仍作为部分事实保留，来源捕获路径使用最终结果索引；部分策略条目不能证明整份策略的行为。

## 开发与测试

共享类按实际职责命名，平台信息放在命名空间中。直接对应设备命令的解析器保留文件名和类名。

`CiscoNxos::ConfigurationState` 持有单次解析期间的可变事实，通过 `finalize_facts` 归约；`Vxlan::Config` 是公开解析入口。内部方法名区分文本解析（`parse_next_hops`）、诊断记录（`unparsed_records`）和冲突排除（`exclude_ambiguous_records!`，移除重复身份的全部记录）。

```sh
bundle install
bundle exec rake
bundle exec ruby examples/offline.rb
bundle exec rake build
```

`bundle exec rake` 执行 RSpec、RuboCop 及离线示例。测试放在 `spec/`，沿用项目 RSpec 约定；样例采用合成或脱敏证据。新增解析格式时补充成功、不完整、不支持及非法输入回归。离线测试不代表所有设备版本均通过实机验证。

使用声明的最低 Ruby 版本检查兼容性。方法用途统一使用简明中文注释；复杂实现还需说明业务规则、实现思路及关键分支。保持公开返回值与错误契约。真实回显和凭据不可进入示例、fixture、日志或发布包。

运行 `bundle exec ruby -Ilib benchmark/tables.rb`，比较 500、2,000、5,000 条数据下的本地解析及引用构建开销。每组核对结果，报告三次采样中的最快耗时与对象分配数。合成输入不代表设备或网络性能。

## 发布

本目录可独立维护为 [vxlan](https://github.com/gatework/vxlan) 仓库。更新 `VERSION` 和 `CHANGELOG.md`，运行上述验证与构建命令，检查包内文件，再创建 `vVERSION` 标签。

CI 在 Linux、macOS 上执行测试、lint、示例、构建和隔离安装。`main` 的 CI 通过后推送 `vVERSION` 标签，工作流将已验证的 Linux 产物发布到 RubyGems 和 GitHub Release，附带 `SHA256SUMS` 并回读下载字节。GitHub `release` environment 可配置 `RUBYGEMS_API_KEY` secret；未配置时使用 RubyGems Trusted Publishing，绑定本仓库、`release.yml` 和 `release` environment。失败时重跑失败的发布 job，以复用原 CI 产物；同版本已存在时必须校验字节一致。详见[发布说明](docs/release.md)。

先发布依赖模块。标签、构建成功或工作流文件都不等于已经发布，需单独确认 RubyGems 的实际结果。版本变化见 [CHANGELOG.md](CHANGELOG.md)。

## 许可证

MIT，见 [LICENSE](LICENSE)。

## 修复建议

`vxlan collect` 默认输出逐设备诊断，使用 `--scripts` 可选导出配置建议；`vxlan review --batch DIR` 可离线补生成既有报告的候选配置、条件回退和只读验收命令。导出不会执行变更；独立 `apply --plan FILE --item ID` 必须在真实终端明确确认，配置漂移或失败即停止。详见[修复建议说明](docs/remediation.md)。 业务分层、会话所有权与执行边界见[架构说明](docs/architecture-zh.md)。

报告阅读顺序与 net-connector topology 一致：`summary.txt` → `devices/*.txt` → `scripts/*.cfg`。不生成 Markdown 报告。所有可执行增量汇总于带 SHA256 校验的 `plan.json`，通过 `vxlan apply --plan plan.json --item ID` 选择一项并交互确认。


## API 迁移

`RuntimeParser.new(platform:, model: nil)` 固定解析平台；`parse(name, text, complete: false, command: nil)` 与 `parse_many(names, text, complete: false, command: nil)` 返回领域 Observation。`Snapshot.new(observations: ...)`、`#observations`、`#observation(name)` 是统一 Ruby API，旧 `dimensions` 成员及 Wireless `dimension` 入口已移除。已知未请求维度返回 `not_requested`，未知名称抛出 `ArgumentError`；持久化 JSON 仍保留 `dimensions` 字段。

动态清单使用 `Netdisco::Catalog`；选中地址的任何重复记录（包括另一平台）都会阻止连接。范围外冲突只输出安全诊断。平台 `NC_<PLATFORM>_ENABLE_PASSWORD` 优先于 `NC_ENABLE_PASSWORD`。
