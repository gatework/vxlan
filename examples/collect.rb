# frozen_string_literal: true

require "vxlan/cli"

# 示例与正式入口共用系统、用户、脚本和工作目录的配置发现。
if $PROGRAM_NAME == __FILE__
  exit Vxlan::CLI.run([ "collect", *ARGV ], command: "ruby examples/collect.rb")
end
