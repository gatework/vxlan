# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rubocop/rake_task"

RSpec::Core::RakeTask.new(:spec) do |task|
  task.ruby_opts = [ "-Ilib" ]
end
RuboCop::RakeTask.new(:lint)

desc "Run offline examples with the installed dependencies"
task :examples do
  Dir["examples/**/*.rb"].sort.each { |path| ruby "-Ilib", path }
end

task default: [ :spec, :lint, :examples ]
# 在 Bundler 构建、打标签或上传版本前，先完成验证。
release = Rake::Task[:release]
prerequisites = release.prerequisites.dup
release.clear_prerequisites.enhance([ :default, *prerequisites ])
