# VXLAN 源码示例

正式命令的配置、环境变量、筛选、报告和退出码见 [bin 使用说明](../bin/README.md)。实现和模板统一位于 `lib/vxlan/cli/`，示例只调用同一 CLI，不维护独立采集流程。

```sh
bundle install
bundle exec ruby examples/collect.rb --help
bundle exec ruby examples/parse.rb --examples
bundle exec ruby examples/offline.rb
```

| 文件 | 用途 |
| --- | --- |
| `collect.rb` | 只读批量采集入口，显式提供源码示例默认路径 |
| `parse.rb` | 文件或 stdin 解析入口 |
| `offline.rb` | 无输入、无网络的合成 OSPF 演示 |

`collect.rb` 保留原有约定：配置为 `examples/vxlan.yml`，环境文件为项目根 `.env`，报告为 `examples/vxlans/`；YAML 相对路径基于项目根目录。初始化使用 `--init --non-interactive`，只创建缺失文件并退出。显式 CLI 路径基于启动目录。

正式 `bin/vxlan` 使用启动目录默认值，方便源码运行、安装和独立部署；请勿混淆两种入口。也可以在 `examples/` 中运行 `bundle exec ruby collect.rb --help`。示例只在直接执行时运行，require 不触发采集；帮助和离线解析不加载连接器。
