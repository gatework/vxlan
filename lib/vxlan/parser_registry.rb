# frozen_string_literal: true

require "ctx_parser/registry"
require_relative "cisco_nxos/profile"

module Vxlan
  # VXLAN 在本领域声明平台支持，公共解析库不依赖领域实现。
  ParserRegistry = CtxParser::Registry.new(profiles: { cisco_nxos: CiscoNxos::Profile })
end
