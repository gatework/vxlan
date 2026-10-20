# frozen_string_literal: true

require_relative "vxlan/version"

module Vxlan
end

require_relative "vxlan/observation"
require_relative "vxlan/snapshot"
require_relative "vxlan/config"
require_relative "vxlan/runtime_parser"
require_relative "vxlan/bgp_neighbors"
require_relative "vxlan/config/review"
require_relative "vxlan/prefix_list_references"
require_relative "vxlan/collector"
require_relative "vxlan/recommendations"
require_relative "vxlan/fabric/review"
