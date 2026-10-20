# VXLAN 命令行使用说明

脚本的配置、帮助、进度和报告方式参考 net-connector/examples。**Vxlan 核心不依赖 net-connector**；正式实现位于 `lib/vxlan/cli/`，负责清单、凭据、连接、并行和报告；`bin/vxlan` 只加载并调用同一入口。支持 Cisco NX-OS，使用模块声明的固定查询，不执行配置下发。

## 安装与入口

Ruby 4.0.6 或更新版本。在源码目录执行 `bundle install` 会从 RubyGems 安装 `ctx_parser`、`ctx_driver` 及开发/示例依赖，不加载相邻工作树。

```sh
bundle install
ruby bin/vxlan collect --help
ruby bin/vxlan parse --examples
bundle exec ruby examples/offline.rb
```

也可以在 `bin/` 中执行 `ruby vxlan collect --help`，或从任意目录指定入口绝对路径。源码入口加载相邻 `lib/`，依赖使用当前 RubyGems/Bundler 环境；不切换 Gemfile、不搜索相邻仓库。安装后使用 `vxlan collect` 和 `vxlan parse`。

`bin/` 的公开内容是 `vxlan` 与本说明；现场 `vxlan.yml`、`.env`、`vxlans/` 由用户按需创建，不进入版本库或安装包。配置和凭据模板统一位于 `lib/vxlan/cli/templates/`，使用 `--init` 生成，不维护重复模板。

离线解析和帮助不加载 net-connector。采集配置与联网入口可选依赖 `net-connector ~> 0.14.2`（已包含 `.env` 加载依赖 dotenv）。本仓库 Gemfile 的 `examples` 组已声明连接器，不进入 vxlan.gemspec 的运行依赖。只安装 vxlan gem 的宿主需要自行声明相应可选依赖。

## 正式命令

安装后使用统一入口（联网及读取环境文件仍需可选依赖）：

```sh
gem install vxlan
gem install net-connector -v '~> 0.14.2'
vxlan --help
vxlan collect --init --non-interactive
vxlan collect --inventory-only
vxlan parse --file running.cfg --complete
```

配置目录从低到高依次为：`/etc/net-connector` → `/usr/local/etc/net-connector` → `$XDG_CONFIG_HOME/net-connector`（默认 `~/.config/net-connector`）→ 当前入口脚本目录 → 启动目录；重复目录只读一次，不向父目录搜索。每个目录先加载共享 `net-connector.yml`，再加载专用 `vxlan.yml`；`--config` 或 `VXLAN_CONFIG` 指定的文件最后覆盖。每层 `.env` 同样叠加，`--env-file` 最后加载；显式文件不存在即报错，自动候选不存在则跳过。

共享文件使用 `common`、`vxlan`、`wireless`、`backup`、`topology` 分区；`common` 只承载 `netdisco`、`inventory`、`ssh`。例如三项目可共用一个文件：

```yaml
common:
  ssh:
    host_key_policy: strict
    known_hosts: keys/known_hosts
  netdisco:
    url: https://netdisco.example.test
vxlan:
  parallel: 4
wireless:
  parallel: 4
```

单个 YAML 文件禁止重复键和多个文档，避免设备范围被静默覆盖或忽略。映射递归覆盖，数组整体替换，`false`、空数组和显式 `null` 保留给领域校验。专用配置的非空 `devices` 不会被公共 Netdisco 配置切换成动态清单；专用配置同时声明冲突来源会被拒绝。YAML 和 `.env` 中声明路径相对各自来源文件，CLI 与进程环境路径相对启动目录。报告默认写启动目录 `vxlans/`。

常用选项使用 `-h / --help`；`--help-all` 补充全部参数和环境约定；`--examples` 显示带用途说明的命令范例。这些操作不读取配置、清单或凭据，不创建文件。

## 离线解析

```sh
ruby bin/vxlan parse --file running.cfg --complete
ruby bin/vxlan parse --dimension nve_peers --file nve.txt --complete --json
cat bgp.txt | ruby bin/vxlan parse --dimension bgp_neighbors --complete
```

`--complete` 是调用方声明“输入已完整采集”，默认未声明，因而保留不完整证据。完整传输中仍有未知语法或冲突时，结果仍可能是 `partial`。默认只打印状态、记录数、诊断代码；`--json` 显式导出解析事实，可能包含运行配置中的敏感字段，请由宿主管理其输出权限。支持维度由 `--help` 列出；configuration 使用配置解析器，其余使用 RuntimeParser。

## 初始化、配置与环境

```sh
ruby bin/vxlan collect --init --non-interactive
```

创建用户配置目录中缺失的 `vxlan.yml` 和 `.env`（或显式 `--config` / `--env-file` 路径），保留已有文件。每个文件先写临时文件，再排他发布，权限为 0600；创建文件后提示检查配置及凭据，再立即退出，不读取清单、不连接设备。缺失配置时，交互终端提供创建选项；自动化不询问、不读取 stdin、不自动创建文件，直接提示 `--init`。`--interactive` 要求真实终端，`--non-interactive` 禁用问答；不会在自动化中消费 stdin。

初始化同样先读取已有 `.env`：其中的 `VXLAN_CONFIG` 选择待创建路径，公开参数作为模板默认值；进程环境优先于 `.env`，CLI 覆盖公开参数，凭据不会复制进 YAML。

模板默认无设备：填写明确目标后才能采集，不自动扫描文档地址或展开网段。

```yaml
fabric: LAB
parallel: 4
directory: vxlans
dimensions: [configuration, nve_peers, nve_vnis, bgp_neighbors, vpc, port_channels]
ssh:
  host_key_policy: strict
  command_timeout: 60
  login_timeout: 15
devices:
  - host: 192.0.2.10
    name: LEAF-01
    model: N9K-C93180YC-FX
  - host: 192.0.2.11
    name: LEAF-02
```

将文档地址替换为真实目标。`devices` 仅接受 `host`、`name`、`model`；地址须为 IP，同一规范化地址不得重复。YAML 不接受密码、任意命令或未声明字段。默认采集全部 12 个维度，大型 MAC/L2RIB 表可通过 dimensions 按需选择。选择了 configuration 时，无论它在列表中何处，均先采集配置来判断未启用功能；最终维度结果保持请求顺序。

`.env` 示意：

```dotenv
NC_DEVICE_USERNAME=operator
NC_DEVICE_PASSWORD='replace-me'
# 可选，已具备查询权限时无需启用密码：
# NC_ENABLE_PASSWORD='replace-me'
```

用户名必须明确；没有密码时允许 SSH key/agent，脚本不会在终端交互索取密码。按平台覆盖使用 `NC_CISCO_NXOS_USERNAME`、`NC_CISCO_NXOS_PASSWORD`。密码包含 `#`、`$` 时请使用单引号。已有进程环境优先于 `.env`。

公开参数优先级是 **CLI > 原始进程环境 > YAML > .env > 内置默认值**。环境默认包括 `VXLAN_FABRIC`、`VXLAN_PARALLEL`（缺失时使用 `NC_PARALLEL`）、`VXLAN_DIRECTORY`；`VXLAN_CONFIG` 指定默认配置路径，`--config` 可以覆盖，空白的 `VXLAN_CONFIG` 不指定额外文件；`--env-file` 指定其他环境文件。CLI/进程环境中的显式配置文件路径相对启动目录解析，YAML 中的输出目录、known_hosts 和 netdisco_config 路径相对配置文件所在目录解析，不通过 `chdir` 改变宿主目录。

SSH 默认严格校验主机密钥。为实际设备准备 known_hosts，或在已接受首次信任风险时显式设置 `host_key_policy: accept_new`；始终拒绝已变更密钥。端口可用 `ssh.port` 设置。并发继承公共 `NC_PARALLEL`，未配置时为 4，允许 1～500，单台设备始终顺序查询。宿主调度独立于连接器内部类，创建线程的闸门和异常回收保证失败或中断后不遗留工作线程；文件描述符不足时在设备连接前提高本进程软限制或明确拒绝过高并发。配置预检不等于设备认证成功。

## 筛选、预览与执行

```sh
ruby bin/vxlan collect --inventory-only --json
ruby bin/vxlan collect --show-config
ruby bin/vxlan collect --hosts 192.0.2.0/24 --name leaf --exclude-name spare --inventory-only
ruby bin/vxlan collect --host 192.0.2.10 --dimensions configuration,nve_peers -p 4
ruby bin/vxlan collect --name leaf --verbose
ruby bin/vxlan collect --json --quiet
```

地址筛选只匹配清单已有设备，支持 IP/CIDR；不支持扫描或范围展开。同类 CLI 条件取并集并覆盖对应 YAML 条件；地址和名称取交集，排除优先，名称为忽略大小写的子串。`--host` 同样是清单筛选，不能代替 devices 清单。`--plan` 与 `--inventory-only` 等价，不读取设备凭据或创建报告目录；`--show-config` 输出公开配置以及 `sources` 中的配置文件、环境文件和 YAML 字段来源，不展开环境密码。所有采集配置入口使用共享 net-connector 加载器；静态预览不建立网络连接。

可选复用 net-connector 的 Netdisco YAML：

```yaml
netdisco_config: /path/to/net-connector/examples/backup.yml
devices: []
```

这只复用设备发现和已配置的筛选策略，选择 ready 的 `cisco_nxos` 设备；只校验并传递外部文件的 `netdisco` / `inventory` 分区，以及对应公共环境字段。清单字段或未知顶层名称有误仍会停止；其他已知分区的备份、拓扑、SSH、TFTP 策略不参与清单预检。Netdisco 的 HTTP/PostgreSQL/缓存参数和 `ND_*` 凭据由 net-connector 处理。VXLAN 采集的 SSH 参数、设备凭据、并发与报告仍由本 CLI 配置负责。Netdisco 来源与非空静态 devices 互斥。

## 宿主复用已打开会话

已有宿主可以直接使用借用入口，无需创建CLI 的传输适配器：

```ruby
# native 是宿主已经连接的 NX-OS 原生设备，宿主独占整个采集过程。
snapshot = nil
native.with_operation(:vxlan) do
  snapshot = Vxlan::Collector.new.collect_session(
    session: native, target: { host: "192.0.2.10" }, fabric_key: "LAB",
    dimensions: [:configuration, :nve_peers]
  )
end
# 会话仍由宿主持有；本方法不打开、关闭、提权或重连。
```

这里的 net-connector 适配由 ctx_driver 在该可选依赖已加载时处理；其他驱动会话只需实现 `connected?` 和单命令 `send_commands` 回执协议。

原生连接器负责登录、脚本执行、超时与关闭；vxlan 负责查询顺序、解析和领域观测；正式 CLI 负责清单、并发和报告。没有额外的 VXLAN 连接器类型或转发 API。联网脚本在同一操作租约中完成整台设备采集。借用其他驱动时由宿主提供等价的独占机制。

上例在操作块内登记 snapshot：若退出租约或关闭连接时失败，宿主仍可保留已得事实，并单独报告收尾故障。不要仅在 `Net::Connector.open` 成功返回后才登记事实。自动批量脚本通过 Collector 的生命周期入口保留维度及关闭失败状态。

公共并发可在 `~/.config/net-connector/.env` 只设置一次，例如 `NC_PARALLEL=50`。YAML 的 `parallel` 是显式覆盖；要继续继承公共配置，应省略该字段。`--init` 不把公共并发或内置默认值固化进 YAML，后续公共值调整可直接生效；显式 `--parallel` 或本工具专用并发环境变量仍可初始化独立覆盖。

## 结果与退出码

采集与配置备份共用批次进度组件，进度、异常、结束摘要和报告路径统一写入 stderr。交互终端原地刷新登录/采集/排队、耗时及预计剩余；重定向时每 25 台及最后一台输出进度，异常设备即时提示。`--verbose` 增加逐台结果与安全命令事件；`--quiet` / `--no-progress` 关闭人类进度及摘要。`--json` 单独向 stdout 输出自动化摘要。终端输出故障不会重放设备查询，报告保留 `output_error` 并标记未完成。

报告目录为 `vxlans/<UTC 批次>/`，同秒批次也不覆盖：

```text
summary.json
summary.txt
devices/
  LEAF-01-192.0.2.10.txt
evidence/
  LEAF-01-192.0.2.10.json
```

`evidence/` 的逐设备 JSON 保存不可变 Snapshot 的结构化事实、各维度诊断和来源指纹；`devices/` 的文本显示设备身份、记录数及诊断代码。摘要不包含配置事实或命令正文。目录权限 0700、文件权限 0600，逐文件原子发布；单设备完成后立即保存，因此中断仍保留已完成结果，摘要列出 pending 设备。报告写入失败会明确返回错误，不宣称成功。

报告根目录须为真实私有目录（0700），拒绝符号链接及组/其他用户可访问的既有目录；不会自动修改既有权限。文件先同步并原子替换，再同步所在目录；替换后同步失败会标为已提交、持久性未确认，保留文件，不重采设备。新建父目录的断电恢复不在此保证内。

摘要 `completed` 表示已采集结果数，逐台 `report_saved` 表示 JSON/TXT 均保存完成；false 表示保存未确认，可能已有部分文件。报告失败时仍尝试保存 incomplete 摘要并返回2；中断后的摘要再次失败仍返回130，安全错误输出 stderr。`pending` 仅列未登记采集结果的目标，不能把它等同于报告缺失。

调度器或执行过程异常退出时也尝试保存摘要，`execution_error` 只记录异常类型，保留已完成设备及 pending 清单。即使全部设备已有完整报告，执行收尾失败仍标为 incomplete 并返回2。连接器未实际提供会话时，核心采集器将全部请求维度标为 failed（`session_not_opened`），不会以空结果冒充完整证据。

`complete` 表示所选证据完整，**不代表 Fabric 健康**。配置关联问题在配置事实的 `review_findings` 中，独立于语法完整性。单设备失败不影响其他目标；断链不自动重放查询，关闭失败仍保留已经采集的事实。核心库本身不写这些报告。

| 退出码 | 含义 |
| --- | --- |
| 0 | 全部所选证据完整，或帮助/初始化/有效预览 |
| 1 | 部分/失败证据，或没有匹配设备 |
| 2 | 参数、配置、可选依赖、清单或报告错误 |
| 130 | 用户中断；已完成报告保留 |

`bundle exec rake` 只运行测试、lint、合成离线示例及新入口帮助，不会因增加联网脚本而自动连接设备。集成测试使用合成回执和本地 PTY，不能替代真实 NX-OS 现场验证。现场 YAML、`.env`、采集报告不进入版本库或安装包。

## 修复建议

`vxlan collect` 默认输出逐设备诊断，使用 `--scripts` 可选导出配置建议；`vxlan review --batch DIR` 可离线补生成既有报告的候选配置、条件回退和只读验收命令。导出不会执行变更；聚合计划使用 `apply --plan plan.json --item ID`，必须在真实终端明确确认，配置漂移或失败即停止。详见[修复建议说明](../docs/remediation.md)。


报告采用 topology 式编排，不生成 Markdown 报告：先读 `summary.txt`，再按设备查看 `devices/*.txt`，候选配置位于 `scripts/*.cfg`。`plan.json` 汇总全部诊断、Fabric 对比和按 ID 索引的增量，`plan.json.sha256` 用于校验；`events.jsonl` 记录审查事件，不代表已经下发。在线采集保留 `evidence/*.json` 原始结构化快照。默认不开启脚本导出，`--scripts` 才生成候选命令；没有候选命令的设备不生成空 cfg。离线审查没有设备会话，不创建伪日志目录。

Fabric 的 ACL 比较包含有序规则和引用地址组的成员。对象缺失、为空或语法未支持时不生成补挂计划；同名对象存在成员差异时列出共同成员和差异，需确认权威业务策略。创建 ACL 若还会影响其他接口的既有引用，则阻止单 SVI 下发。网关补齐要求共同业务的 VRF、Anycast 模式和 MAC 一致。历史证据未包含地址组时须重新采集，不能把未知依赖当作一致。

`fabric-policy.yml` 显式声明各 Fabric 的 `leaves`、`borders`、`spines`。Leaf 与 Border 按各自已部署的共同 VNI 比较；Spine 检查角色冲突。业务目录联合 VLAN/NVE/EVPN 识别不完整部署，总览显示覆盖范围、未纳入设备和缺证据成员。只有完整一致的对端与本机唯一业务接口相互印证、且全 Fabric 无跨 VNI 网段冲突时，才建议补齐已有 VLAN 的 VNI 关联；不会推导全量铺开 VLAN，也不按命名猜测角色。

每次采集独立合并进程环境与指定 `.env`，不改写调用者环境；凭据、清单与参数使用同一份本次有效环境。Fabric 策略在连接前加载、校验并固定，采集中途修改策略文件只影响下一批。下发只接受带校验文件的 `plan.json` 与 `--item ID`，不接受旧版独立单项计划。
