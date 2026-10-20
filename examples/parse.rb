# frozen_string_literal: true

require "vxlan/cli"

exit Vxlan::CLI.run([ "parse", *ARGV ], command: "ruby examples/parse.rb") if $PROGRAM_NAME == __FILE__
