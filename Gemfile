# frozen_string_literal: true

source "https://rubygems.org"
gemspec

gem "rake"
gem "rspec-core"
gem "rspec-expectations"
gem "rspec-mocks"
gem "rubocop-rails-omakase", require: false

# 可选 CLI 网络/环境文件依赖与集成验证；纯解析安装无需连接器。
group :examples do
  gem "net-connector", ">= 0.21.0", "< 0.23", require: false
end

# 公共业务层候选源码联调；发布包仍使用 gemspec 中的版本依赖。
gem "ctx_runner", path: ENV.fetch("CTX_RUNNER_PATH") if ENV["CTX_RUNNER_PATH"]

# 公共 CLI 候选源码联调；安装包不探测相邻源码。
gem "ctx_cli", path: ENV.fetch("CTX_CLI_PATH") if ENV["CTX_CLI_PATH"]
