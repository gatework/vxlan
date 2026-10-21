# frozen_string_literal: true

require "ctx_runner/observation"

module Vxlan
  # 复用公共事实契约；领域保留公开类型与后续的专属约束。
  class Observation < CtxRunner::Observation; end
end
