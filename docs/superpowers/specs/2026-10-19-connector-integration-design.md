# VXLAN 与设备连接器集成设计

状态：用户已确认并授权继续；已按本方案实施，验证记录见同日期实施计划。

## 用户约束

- net-connector 负责设备登录、会话、脚本执行；vxlan 集成领域业务。
- 拒绝重复样板代码，模块功能专注领域，简单、容易集成。
- 先设计，再落实代码。保留两个工作树已有改动，不提交、不发布、不连接真实设备。

## 结论与分层

直接使用现有接口集成。VXLAN 是运行在 NX-OS 等平台上的网络功能，当前已有 `:cisco_nxos` 连接器；本轮无需在 net-connector 内增加 VXLAN 模块或新设备类型。

调用关系：VXLAN 示例/宿主 → `Vxlan::Collector` → `CtxDriver::Reader/Session` → net-connector 原生设备 → SSH/PTY。离线解析不经过连接器。

| 所属 | 保留的职责 |
| --- | --- |
| net-connector | 登录、密钥信任、提示符/分页、超时、脚本回执、操作租约、关闭 |
| ctx_driver | 单命令回执适配、正文/来源指纹、失败隔离、断链后抑制查询 |
| vxlan/lib | 固定查询与采集顺序、解析、Observation/Snapshot、完整性和配置关联判断 |
| vxlan/examples | 环境/YAML、清单筛选、连接所有权、并发、进度、报告及退出码 |

这些职责在当前源码基本成立。本轮补齐集成可靠性，不重做已完成的脚本功能，不把 examples 的宿主策略提升为核心公共 API。不新增连接器业务门面、通用作业框架或第二套结果模型。

## 最小集成接口

沿用 `Vxlan::Collector#collect(connector:, target:, fabric_key:, model: nil, dimensions: ...)` 与 `#collect_session(session:, target:, fabric_key:, platform: :cisco_nxos, model: nil, dimensions: ...)`，返回现有 Snapshot；保留现有 platform 参数契约。

- 自管连接：现有 `VxlanExamples::NativeConnector#open` 使用 `Net::Connector.open(:cisco_nxos, ...)`，在原生设备 `with_operation(:vxlan)` 中 yield。Collector 可以直接接收 native，由现有 Reader 适配；移除该路径多余的手工 `CtxDriver::Session.new` 包装。
- 借用连接：宿主负责 `Net::Connector.open` 和 `native.with_operation(:vxlan)`，内部调用 collect_session。方法不新增自动连接、关闭、提权或重连。使用者须按真实设备传递平台，参数默认值不代表设备识别。
- 不新增 `Vxlan::Connector`、`Net::Connector::Vxlan`、parse 转发门面、第二种回执协议或 installed CLI。未来出现多个真实宿主共享同一能力时，再评估抽取。

宿主最小用法：

```ruby
Net::Connector.open(:cisco_nxos, **access) do |native|
  native.with_operation(:vxlan) do
    Vxlan::Collector.new.collect_session(
      session: native, target: { host: native.host }, fabric_key: "LAB",
      dimensions: [:configuration, :nve_peers]
    )
  end
end
```

片段说明资源所有权，不声明 open 的返回值能同时交付关闭错误与业务值。批量示例依然走 Collector#collect，利用其已存在的观测保存与关闭失败分类。

## 保持的功能

保留 collect.rb、parse.rb、offline.rb 及已有参数、环境变量、路径基准和退出码。不新增第二套 YAML，不改变 CLI > YAML > 环境默认值，不迁移目录规则。

12 个维度、配置优先查询、返回顺序、未启用功能判断均复用 Collector/Profile；离线 complete:false 默认值不变。完整证据不代表 Fabric 健康。保留静态/Netdisco 清单、IP/CIDR及名称过滤、默认并发4/上限500、SSH strict、显式JSON、中文摘要、私有报告、初始化不覆盖文件等现有功能。

## 需要落实的改进

### 1. 会话范围与失败保真

修改现有 NativeConnector 的 open 块，在一次采集内持有原生操作租约，避免其他线程在两个维度之间插入命令。不给 Collector 的通用会话协议增加连接器特有方法。

为 Collector#collect 补回归：连接失败、查询失败、关闭失败、租约退出/日志收尾失败。Collector 已在 connector.open 的 yield 内登记 observations 和 session_finished；仅在复现证明不足时修改 collector.rb。完成的维度不能因收尾失败被删除，collection 维度保持失败码，不能将其判为成功批次。不新增一套 CompletionError/Snapshot 包装。

借用入口由宿主管理收尾错误。文档说明：若要求收尾失败仍保留 Snapshot，应在操作块内登记返回值并分别处理异常，不依赖 open 成功返回后才赋值。正文敏感策略复用 ctx_driver/net-connector。

### 2. 并发中止与线程退出

维持 examples/support/parallel.rb 的有限并发和启动闸门，不依赖连接器工作树中尚未发布的内部调度类。这段宿主调度用于兼容已发布0.14.1，不在本轮把 Parallel::Pool 提升成跨gem公共协议。

修正任务内 Thread.exit/kill 绕过 rescue 后，finished 仍可能交付 nil 的情况：只有真正耗尽任务的 worker 才算正常结束；提前退出明确失败并回收全部线程。线程创建到登记、通知、kill/join 必须覆盖取消，次级收尾失败不得覆盖首个错误。不增加重试、取消令牌框架、整批 deadline 或全局线程设置。

### 3. 证据登记与报告失败

现有 Collection#collect 在写文件成功后才追加 @results；改为先登记已采集的安全结果，再保存。设备 JSON 成功而 TXT 失败时，保留已有 JSON，不重采设备；批次明确持久化失败，不能宣称全部成功。

报告错误不作为连接失败处理。复用现有少量方法/状态，必要时增加单一宿主内部 Report::Error，保存安全阶段/公开相对文件名，不携带正文、凭据或原始异常消息；不建立 Batch/Outcome/事件总线。进度“已采集”和“报告已保存”按实际完成点表述。

Interrupt 后先等待全部线程回收，再保存摘要；摘要再次失败仍返回130，stderr显示安全报告故障，不能让异常逃出 rescue 覆盖取消事实。已登记结果、已落盘文件与 pending 目标分别反映真实状态。普通报告错误返回2。

保持目录0700、文件0600、唯一批次及逐文件原子替换。现有 publish 只有文件 fsync + rename；补同目录同步，区分替换前失败与已替换但持久性未确认。只局部完善 Report#publish，不反向依赖连接器内部 Storage。已有报告根目录检查类型、符号链接及组/其他用户权限；不安全时在连接前拒绝，说明修正方法，不静默修改权限。新父目录同步及文件系统断电保证不在本轮承诺范围。

## 依赖与兼容性

- net-connector 保持 Ruby >=3.2，运行依赖不新增 vxlan/ctx_driver。
- vxlan/ctx_driver 当前 Ruby >=4.0.6，不修改最低版本。
- vxlan 仍仅在 Gemfile examples 组选择 net-connector ~>0.14.1 与 dotenv；核心 gemspec 不加入连接器。
- 发布版0.14.1和当前工作树同版本并非同一代码，分别验证，记录加载路径/版本。不得只测工作树就声称兼容发布版。
- 不为少量本地报告逻辑创建新基础gem，也不复制解析、会话执行或跨层报告模型。

## 实施顺序与验收

设计确认后用 writing-plans 写逐项实施计划；以下是实施顺序，每项先固定失败回归，再最小修改。

1. **原生连接贯通**：修改 examples/support/collection.rb 中 NativeConnector；扩展 spec/example_native_connector_spec.rb、spec/collector_spec.rb。本地PTY验证登录、配置优先/顺序、一次租约、关闭、关闭/租约收尾失败保留事实、断链不重放、借用不关闭。若复现证明连接器有通用缺陷，再单独修复，不预设必须改其产品代码。
2. **并发稳定性**：修改 examples/support/parallel.rb、spec/example_parallel_spec.rb。Queue 同步验证Thread.exit、Thread.kill、部分线程创建失败、中断及阻塞同伴收尾，全员join且不返回伪成功。
3. **报告与取消**：修改 examples/support/collection.rb、report.rb、spec/example_collection_spec.rb，必要时新增 spec/example_report_spec.rb。验证ENOSPC、JSON成功/TXT失败、目录同步失败、宽权限/链接目录、取消后摘要失败、敏感异常消息、已采集结果与pending不矛盾。
4. **文档与打包**：更新 examples/README.md、README.md/README-zh.md、CHANGELOG.md及已有离线门禁；必要时更新 script/verify_package.rb。执行 bundle exec rake、bundle exec rake build 和构建包安装验证；分别验证发布连接器与隔离加载的工作树连接器，记录 Gem.loaded_specs 和 loaded paths。若修改 net-connector，额外执行其相关Minitest、Ruby3.2门禁与 script/ci。

仅用合成文本、本地PTY、临时目录。离线帮助/示例不接设备。最终准确区分离线/PTY验证与未执行的真实NX-OS现场验证。

本方案的具体修复范围与接口取舍经用户确认后实施；公开接口、职责划分和简化原则保持。
