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
  gem "net-connector", "~> 0.16.0", require: false
end
