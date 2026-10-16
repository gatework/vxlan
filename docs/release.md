# Release

1. Update `lib/vxlan/version.rb` and `CHANGELOG.md`; run `bundle exec rake` and `bundle exec rake build`.
2. Run `ruby script/verify_package.rb pkg/vxlan-VERSION.gem`. This installs and loads the built gem outside Bundler and the checkout.
3. Commit and push `main`; wait for both Linux and macOS CI jobs.
4. Push the matching `vVERSION` tag. The Release workflow repeats CI, then publishes its exact Linux artifact to RubyGems and GitHub with `SHA256SUMS`.
5. Verify the workflow, registry version, tag commit, and downloaded checksums. A local build is not publication evidence.

Configure `RUBYGEMS_API_KEY` as an encrypted secret in the GitHub `release` environment, with noninteractive gem-push permission. Alternatively configure [Trusted Publishing](https://guides.rubygems.org/trusted-publishing/) for `gatework/vxlan`, `release.yml`, environment `release`, and omit that secret. Never commit credentials.

A failed publish is not permission to overwrite an existing version. Rerun the failed publish job to retain the original CI artifact. The script verifies an existing RubyGems version before proceeding and rejects different bytes or yanked versions. `workflow_dispatch` is restricted to version tags by the publish validation.

Raw device `*.log`, local secrets, and build outputs are ignored. Package files use an explicit gemspec allowlist; review both the Git index and gem contents before publishing. Tests and examples must use synthetic or sanitized evidence.
