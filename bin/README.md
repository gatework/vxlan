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

离线解析和帮助不加载 net-connector。联网示例可选依赖 `net-connector ~> 0.14.1`；读取 `.env` 时需要 `dotenv ~> 3.0`。本仓库 Gemfile 的 `examples` 组已声明它们，不进入 vxlan.gemspec 的运行依赖。只安装 vxlan gem 的宿主需要自行声明相应可选依赖。

## 正式命令

安装后使用统一入口（联网及读取环境文件仍需可选依赖）：

```sh
gem install vxlan
gem install net-connector -v '~> 0.14.1'
gem install dotenv -v '~> 3.0'
vxlan --help
vxlan collect --init --non-interactive
vxlan collect --inventory-only
vxlan parse --file running.cfg --complete
```

默认读取**启动目录**的 `vxlan.yml` 和 `.env`，报告写入启动目录 `vxlans/`。例如在 `bin/` 运行就使用 `bin/vxlan.yml`、`bin/.env`、`bin/vxlans/`；从项目根目录运行就使用根目录下同名文件。已有文件保持不变。使用 `--config`、`--env-file`、`--directory` 可明确指定其他路径。

YAML 中的相对路径基于配置文件所在目录；CLI 参数与进程环境路径基于启动目录。命令不会改变工作目录，也不会根据安装位置选择配置。

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

创建启动目录中缺失的 `vxlan.yml` 和 `.env`，保留已有文件。每个文件先写临时文件，再排他发布，权限为 0600；创建文件后提示检查配置及凭据，再立即退出，不读取清单、不连接设备。缺失配置时，交互终端提供创建选项；自动化不询问、不读取 stdin、不自动创建文件，直接提示 `--init`。`--interactive` 要求真实终端，`--non-interactive` 禁用问答；不会在自动化中消费 stdin。

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

公开参数优先级是 **CLI > YAML > 环境默认值**。环境默认包括 `VXLAN_FABRIC`、`VXLAN_PARALLEL`（缺失时使用 `NC_PARALLEL`）、`VXLAN_DIRECTORY`；`VXLAN_CONFIG` 指定默认配置路径，`--config` 可以覆盖，空白的 `VXLAN_CONFIG` 沿用入口默认值；`--env-file` 指定其他环境文件。CLI/进程环境中的显式配置文件路径相对启动目录解析，YAML 中的输出目录、known_hosts 和 netdisco_config 路径相对配置文件所在目录解析，不通过 `chdir` 改变宿主目录。

SSH 默认严格校验主机密钥。为实际设备准备 known_hosts，或在已接受首次信任风险时显式设置 `host_key_policy: accept_new`；始终拒绝已变更密钥。端口可用 `ssh.port` 设置。默认并发 4，允许 1～500，单台设备始终顺序查询。宿主调度独立于连接器内部类，创建线程的闸门和异常回收保证失败或中断后不遗留工作线程；文件描述符不足时在设备连接前提高本进程软限制或明确拒绝过高并发。配置预检不等于设备认证成功。

## 筛选、预览与执行

```sh
ruby bin/vxlan collect --inventory-only --json
ruby bin/vxlan collect --show-config
ruby bin/vxlan collect --hosts 192.0.2.0/24 --name leaf --exclude-name spare --inventory-only
ruby bin/vxlan collect --host 192.0.2.10 --dimensions configuration,nve_peers -p 4
ruby bin/vxlan collect --name leaf --verbose
ruby bin/vxlan collect --json --quiet
```

地址筛选只匹配清单已有设备，支持 IP/CIDR；不支持扫描或范围展开。同类 CLI 条件取并集并覆盖对应 YAML 条件；地址和名称取交集，排除优先，名称为忽略大小写的子串。`--host` 同样是清单筛选，不能代替 devices 清单。`--plan` 与 `--inventory-only` 等价，不读取设备凭据或创建报告目录；`--show-config` 输出公开配置，不展开环境密码。静态清单预览不需要 net-connector。

可选复用 net-connector 的 Netdisco YAML：

```yaml
netdisco_config: /path/to/net-connector/examples/backup.yml
devices: []
```

这只复用设备发现和已配置的筛选策略，选择 ready 的 `cisco_nxos` 设备；不沿用其中的备份/TFTP 任务。Netdisco 的 HTTP/PostgreSQL/缓存参数和 `ND_*` 凭据由 net-connector 处理。VXLAN 采集的 SSH 参数、设备凭据、并发与报告仍由本 CLI 配置负责。Netdisco 来源与非空静态 devices 互斥。

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

## 结果与退出码

默认 stdout 输出中文摘要和报告路径，进度输出 stderr 并及时 flush。`--verbose` 显示逐台结果，`--quiet` / `--no-progress` 关闭进度；`--json` 将 stdout 留给自动化摘要，仍可使用 stderr 进度。

报告目录为 `vxlans/<UTC 批次>/`，同秒批次也不覆盖：

```text
summary.json
summary.txt
devices/
  LEAF-01-192.0.2.10.json
  LEAF-01-192.0.2.10.txt
```

逐设备 JSON 显式保存不可变 Snapshot 的结构化事实、各维度诊断和来源指纹；文本显示设备身份、记录数及诊断代码。摘要不包含配置事实或命令正文。目录权限 0700、文件权限 0600，逐文件原子发布；单设备完成后立即保存，因此中断仍保留已完成结果，摘要列出 pending 设备。报告写入失败会明确返回错误，不宣称成功。

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
