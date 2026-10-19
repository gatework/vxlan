# frozen_string_literal: true

require "vxlan/cli"

# 源码示例保留项目路径；安装后的 vxlan 命令使用用户工作目录。
if $PROGRAM_NAME == __FILE__
  root = File.expand_path("..", __dir__)
  exit Vxlan::CLI.run([ "collect", *ARGV ],
    config: File.join(__dir__, "vxlan.yml"), env_file: File.join(root, ".env"),
    directory: File.join(__dir__, "vxlans"), base: root, command: "ruby examples/collect.rb")
end
