# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "open3"
require "rbconfig"
require "rubygems/package"
require "tmpdir"

# 只接收明确的本地校验、注册表发布或 GitHub 发布操作。
abort "Usage: ruby script/release.rb --check|--push|--github" unless ARGV.one? && %w[--check --push --github].include?(ARGV.first)
Dir.chdir(File.expand_path("..", __dir__))
spec = Gem::Specification.load("vxlan.gemspec")
abort "Cannot load gemspec" unless spec
artifact = "pkg/#{spec.full_name}.gem"
abort "Expected exactly one release gem" unless Dir["pkg/*.gem"] == [ artifact ]
package = Gem::Package.new(artifact)
package.verify
spec.date = package.spec.date
spec.rubygems_version = package.spec.rubygems_version
abort "Gem metadata differs from source" unless package.spec.to_ruby == spec.to_ruby
abort "Gem file list differs from source" unless package.contents.sort == spec.files.sort
Dir.mktmpdir("gem-source-check-") do |dir|
  package.extract_files(dir)
  spec.files.each do |file|
    extracted = File.join(dir, file)
    abort "Gem content differs: #{file}" unless File.binread(extracted) == File.binread(file)
    abort "Gem permissions differ: #{file}" unless File.stat(extracted).mode & 0o777 == File.stat(file).mode & 0o777
  end
end
sha = Digest::SHA256.file(artifact).hexdigest
abort "Checksum differs" unless File.read("pkg/SHA256SUMS") == "#{sha}  #{File.basename(artifact)}\n"
abort "Missing changelog entry" unless File.read("CHANGELOG.md").include?("## #{spec.version} (")
if ENV["GITHUB_REF_TYPE"]
  abort "Release requires the matching version tag" unless ENV["GITHUB_REF_TYPE"] == "tag" && ENV["GITHUB_REF_NAME"] == "v#{spec.version}"
end
puts "Verified #{File.basename(artifact)} SHA256 #{sha}"
exit if ARGV.first == "--check"
abort "Release requires the matching version tag" unless ENV["GITHUB_REF_TYPE"] == "tag" && ENV["GITHUB_REF_NAME"] == "v#{spec.version}"

# 注册表请求具有有限超时，不将网络错误误判成版本不存在。
def registry_get(path)
  uri = URI("https://rubygems.org#{path}")
  Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 30) { |http| http.get(uri.request_uri) }
end

# 已有版本必须仍可用且字节相同；绝不通过重新构建覆盖同版本。
def verify_metadata(response, sha)
  metadata = JSON.parse(response.body)
  abort "Published version differs or was yanked" unless metadata["sha"] == sha && metadata["yanked"] == false
end

metadata_path = "/api/v2/rubygems/#{spec.name}/versions/#{spec.version}.json"
if ARGV.first == "--push"
  response = registry_get(metadata_path)
  case response
  when Net::HTTPNotFound
    system(RbConfig.ruby, "-S", "gem", "push", artifact, "--host", "https://rubygems.org", exception: true)
  when Net::HTTPSuccess
    verify_metadata(response, sha)
    puts "Same artifact already published; verifying download"
  else
    abort "RubyGems preflight failed: HTTP #{response.code}"
  end
end

# 上传后只重试读取；可见性延迟不触发第二次上传。
verified = false
24.times do |attempt|
  response = registry_get(metadata_path)
  if response.is_a?(Net::HTTPSuccess)
    verify_metadata(response, sha)
    download = registry_get("/gems/#{spec.full_name}.gem")
    if download.is_a?(Net::HTTPSuccess)
      abort "Published bytes differ" unless Digest::SHA256.hexdigest(download.body) == sha
      verified = true
      break
    end
    abort "Download failed: HTTP #{download.code}" unless download.is_a?(Net::HTTPNotFound)
  elsif !response.is_a?(Net::HTTPNotFound)
    abort "Read-back failed: HTTP #{response.code}"
  end
  sleep 5 unless attempt == 23
end
abort "RubyGems read-back timed out; verify the existing artifact before retrying" unless verified
puts "Verified RubyGems version and downloaded bytes: #{spec.full_name}"
exit if ARGV.first == "--push"

repo = ENV.fetch("GITHUB_REPOSITORY")
abort "Unexpected release repository" unless repo == "gatework/vxlan"
tag = "v#{spec.version}"
release_json, status = Open3.capture2e("gh", "release", "view", tag, "--repo", repo, "--json", "assets,isDraft")
unless status.success?
  system("gh", "release", "create", tag, "--repo", repo, "--verify-tag", "--title", tag, "--notes-file", "CHANGELOG.md", exception: true)
  release_json, status = Open3.capture2e("gh", "release", "view", tag, "--repo", repo, "--json", "assets,isDraft")
  abort "Cannot read created release" unless status.success?
end
release = JSON.parse(release_json)
abort "Release is still a draft" if release.fetch("isDraft")
assets = release.fetch("assets").map { |asset| asset.fetch("name") }
[ artifact, "pkg/SHA256SUMS" ].each do |file|
  name = File.basename(file)
  system("gh", "release", "upload", tag, file, "--repo", repo, exception: true) unless assets.include?(name)
  Dir.mktmpdir("release-readback-") do |dir|
    system("gh", "release", "download", tag, "--repo", repo, "--dir", dir, "--pattern", name, exception: true)
    abort "GitHub release asset differs: #{name}" unless File.binread(File.join(dir, name)) == File.binread(file)
  end
end
puts "Verified GitHub Release assets: #{repo} #{tag}"
