# frozen_string_literal: true

require "minitest/autorun"
require_relative "../fastlane/lib/sdk_release"

class SDKReleaseTest < Minitest::Test
  VERSION = "1.2.3"
  SDK_VERSION = "5.2.11"

  # Simulates Git, CocoaPods and Xcode without executing any external command.
  class Commands
    attr_reader :calls
    attr_accessor :existing_tag, :provenance, :fail_target, :wrong_version, :existing_spec, :wrong_runtime,
                  :sdk_version, :core_selected, :sdk_published, :missing_sdk_tag, :main_version,
                  :tag_dependency, :fail_lint, :fail_push, :fail_resolve, :sdk_index_spec,
                  :sdk_tag_version, :missing_lock, :trunk_push_error
    attr_reader :examples_at_update

    def initialize(env)
      @env, @calls = env, []
      @provenance = "HXSDK-Source-SHA: #{'a' * 40}"
      @sdk_published = true
      @sdk_version = SDK_VERSION
      @main_version = "1.0.0"
      @roots = {}
      @examples_at_update = []
    end

    def run(*args, chdir: nil)
      @calls << args
      if args[0..3] == %w[bundle exec pod repo] && args[4] == "add"
        @specs = File.join(@env.fetch("CP_HOME_DIR"), "repos", args[5])
        FileUtils.mkdir_p(@specs)
        install_spec(sdk_index_spec || spec("HXSDK", sdk_version)) if sdk_published && !core_selected
        install_spec(existing_spec) if existing_spec
      elsif args[0..1] == %w[git clone]
        destination = args.last
        FileUtils.mkdir_p(destination)
        if destination.end_with?("/source")
          @roots[destination] = "source"
          path = File.join(destination, "HXSDK/Classes/Public")
          FileUtils.mkdir_p(path)
          File.write(File.join(path, "HXSDK.m"), "+ (NSString *)getSDKVersion { return @\"#{wrong_runtime || sdk_version}\"; }")
          FileUtils.mkdir_p(File.join(destination, "Example"))
        else
          name = File.basename(destination)
          @roots[destination] = name
          tagged = args.include?("--no-checkout")
          version = if tagged
                      name == "HXSDK" ? (sdk_tag_version || sdk_version) : (wrong_version || VERSION)
                    else
                      main_version
                    end
          repo = SDKRelease::PROJECTS.fetch(name).first
          dependency = tagged ? (tag_dependency || "~> #{sdk_version}") : "~> 5.2.9"
          File.write(File.join(destination, "#{name}.podspec"), "s.name = '#{name}'\ns.version = '#{version}'\ns.source = 'https://gitee.com/#{repo}.git'\ns.dependency 'HXSDK', '#{dependency}'\n")
          File.write(File.join(destination, "README.md"), "pod 'HXSDK', '0.0.1'\nHXSDK ~> 5.2.9\n")
          example = name == "HXSDK" ? "HXSDK-iOS-Example" : SDKRelease::AdapterRelease::EXAMPLES.fetch(name)
          FileUtils.mkdir_p(File.join(destination, example))
          File.write(File.join(destination, example, "Podfile"), "source 'https://cdn.cocoapods.org/'\ntarget 'Example' do\n  pod '#{name}', :path => '../../old-name'\n  pod 'HXSDK/UBiX', '~> 5.2.9'\nend\n")
        end
      elsif args.first == "git" && args.include?("fetch") && missing_sdk_tag && @roots[args[2]] == "HXSDK"
        raise SDKRelease::Error, "missing SDK tag"
      elsif args.first == "git" && args.include?("push") && fail_push
        raise SDKRelease::Error, "atomic push rejected"
      elsif args.first == "bash"
        FileUtils.mkdir_p(File.join(args[3], "HXSDK.framework"))
        File.write(File.join(args[3], "HXSDK.framework/HXSDK"), "fake binary")
      elsif args[0..4] == %w[bundle exec pod repo push]
        raise SDKRelease::Error, "Specs rejected" if fail_target == "specs"
        install_spec(parse_spec(File.join(chdir, args[6])))
      elsif args[0..4] == %w[bundle exec pod trunk push]
        raise SDKRelease::Error, trunk_push_error if trunk_push_error
        raise SDKRelease::Error, "Trunk read-only" if fail_target == "trunk"
      elsif args[0..3] == %w[bundle exec pod update]
        raise SDKRelease::Error, "dependency resolution failed" if fail_resolve
        @examples_at_update << File.read(File.join(chdir, "Podfile"))
        File.write(File.join(chdir, "Podfile.lock"), "# resolved example") unless missing_lock
      elsif args[0..3] == %w[bundle exec pod install] && chdir.end_with?("/HXSDK-iOS-Example")
        File.write(File.join(chdir, "Podfile.lock"), "# resolved example")
      elsif args[0..4] == %w[bundle exec pod lib lint]
        raise SDKRelease::Error, "lint failed" if fail_lint == true || args[5] == "#{fail_lint}.podspec"
      end
      true
    end

    def capture(*args, chdir: nil)
      @calls << args
      if args[0..4] == %w[bundle exec pod ipc spec]
        return JSON.generate(parse_spec(args.last))
      end
      return provenance if args.include?("log")
      return "a" * 40 if args.include?("rev-parse") && args[2].end_with?("/source") && args.last == "HEAD"
      return "c" * 40 if args.include?("rev-parse") && args[2].include?("/dependency/")

      "b" * 40
    end

    def spec(name, version)
      result = { "name" => name, "version" => version, "source" => { "git" => "https://gitee.com/#{SDKRelease::PROJECTS.fetch(name).first}.git", "tag" => version } }
      result["dependencies"] = { "HXSDK" => ["~> #{sdk_version}"] } unless name == "HXSDK"
      result
    end

    def parse_spec(path)
      content = File.read(path)
      return JSON.parse(content) if path.end_with?(".json")

      name = content[/s.name = '([^']+)'/, 1]
      version = content[/s.version = '([^']+)'/, 1]
      result = spec(name, version)
      result["source"]["git"] = content[/s.source = '([^']+)'/, 1]
      result["dependencies"] = { "HXSDK" => [content[/s.dependency 'HXSDK', '([^']+)'/, 1]] } unless name == "HXSDK"
      result
    end

    def install_spec(value)
      path = File.join(@specs, value.fetch("name"), value.fetch("version"))
      FileUtils.mkdir_p(path)
      File.write(File.join(path, "#{value.fetch('name')}.podspec.json"), JSON.generate(value))
    end

    def tag_exists?(repo, _version)
      existing_tag == true || Array(existing_tag).include?(SDKRelease::PROJECTS.find { |_, value| repo.include?(value.first) }&.first)
    end
  end

  def setup
    @dir = Dir.mktmpdir("sdk-release-test-")
    @env = { "CP_HOME_DIR" => File.join(@dir, "cp"), "SDK_OUTPUT_DIR" => File.join(@dir, "output"), "COCOAPODS_TRUNK_TOKEN" => "test-token" }
    @commands = Commands.new(@env)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def request(**options)
    SDKRelease::Request.new({ project: "HXGMAdapter", version: VERSION, hx_sdk_version: SDK_VERSION }.merge(options), {})
  end

  def runner(req = request, registry: nil, trunk_confirmation: ->(*) { nil }, cdn_ready: ->(*) { true }, sleeper: ->(_) {})
    @commands.sdk_version = req.sdk_version
    @commands.core_selected = req.versions.key?("HXSDK")
    registry ||= ->(name, version) { @commands.spec(name, version) if name == "HXSDK" && !@commands.core_selected }
    SDKRelease::Runner.new(req, commands: @commands, env: @env, registry: registry,
                          trunk_confirmation: trunk_confirmation, sleeper: sleeper, cdn_ready: cdn_ready)
  end

  def results
    JSON.parse(File.read(File.join(@env.fetch("SDK_OUTPUT_DIR"), "results.json")))
  end

  def spec(name = "HXGMAdapter")
    @commands.spec(name, VERSION)
  end

  def test_defaults_and_independent_versions
    assert request.dry_run
    assert_equal "both", request.target
    env = SDKRelease::PROJECTS.values.to_h { |_, key| [key, VERSION] }.merge("SDK_PROJECT" => "all")
    assert_equal SDKRelease::PROJECTS.keys, SDKRelease::Request.new({}, env).versions.keys
    env.delete("GM_VERSION")
    assert_raises(SDKRelease::Error) { SDKRelease::Request.new({}, env) }
  end

  def test_rejects_unknown_project_invalid_version_target_and_boolean
    [{ project: "other" }, { version: "v1.2.3" }, { version: "1.2.3; touch x" }, { target: "trunk" }, { dry_run: "yes" }].each do |options|
      assert_raises(SDKRelease::Error) { request(**options) }
    end
  end

  def test_update_only_release_version
    path = File.join(@dir, "SDK.podspec")
    File.write(path, "s.version = '1.0.0'\ns.dependency 'HXSDK', '~> 5.2.9'\n")
    SDKRelease.update_version(path, VERSION)
    assert_includes File.read(path), "s.version = '#{VERSION}'"
    assert_includes File.read(path), "'~> 5.2.9'"
    File.write(path, "# no version\n")
    assert_raises(SDKRelease::Error) { SDKRelease.update_version(path, VERSION) }
  end

  def test_adapter_dry_run_does_not_commit_tag_push_or_publish
    capture_io { runner.run }
    assert_equal %w[dry_run dry_run], results.map { |r| r.fetch("status") }
    refute @commands.calls.any? { |c| c.include?("push") || c.include?("commit") || c.include?("tag") || c.include?("add") && c.first == "git" }
    assert @commands.calls.any? { |c| c.include?("refs/tags/#{SDK_VERSION}") }
  end

  def test_specs_only_never_contacts_trunk
    registry = ->(*) { flunk "Specs-only must not query Trunk" }
    capture_io { runner(request(target: "specs", dry_run: false), registry: registry).run }
    assert_equal ["specs"], results.map { |r| r.fetch("stage") }
    assert_equal ["published"], results.map { |r| r.fetch("status") }
  end

  def test_partial_success_is_failed_and_preserves_each_target_status
    @commands.fail_target = "trunk"
    capture_io { assert_raises(SDKRelease::Error) { runner(request(dry_run: false)).run } }
    assert_equal %w[published failed], results.map { |r| r.fetch("status") }
    assert_includes results.last.fetch("message"), "Trunk read-only"
    assert_includes results.last.fetch("message"), "未查到 HXGMAdapter #{VERSION}"
  end

  def test_trunk_push_timeout_is_reconciled_when_matching_spec_appears
    @commands.trunk_push_error = "Calling the GitHub commit API timed out"
    lookups = []
    confirmation = lambda do |name, version|
      lookups << [name, version]
      raise Net::ReadTimeout if lookups.size == 1
      next unless lookups.size == 2

      @commands.spec(name, version)
    end

    output, = capture_io do
      runner(request(project: "HXSDK", version: SDK_VERSION, dry_run: false), trunk_confirmation: confirmation).run
    end

    assert_equal %w[published published], results.map { |r| r.fetch("status") }
    assert_includes results.last.fetch("message"), "已发布且内容一致"
    assert_includes output, "| HXSDK | #{SDK_VERSION} | trunk | published |"
    assert_equal Array.new(2, ["HXSDK", SDK_VERSION]), lookups
    assert_equal 1, @commands.calls.count { |args| args[0..4] == %w[bundle exec pod trunk push] }
  end

  def test_trunk_push_timeout_still_fails_when_remote_spec_differs
    @commands.trunk_push_error = "Calling the GitHub commit API timed out"
    confirmation = ->(name, version) { @commands.spec(name, version).merge("summary" => "different") }
    capture_io do
      assert_raises(SDKRelease::Error) { runner(request(dry_run: false), trunk_confirmation: confirmation).run }
    end
    assert_equal %w[published failed], results.map { |r| r.fetch("status") }
    assert_includes results.last.fetch("message"), @commands.trunk_push_error
    assert_includes results.last.fetch("message"), "podspec 内容不同"
    assert_equal 1, @commands.calls.count { |args| args[0..4] == %w[bundle exec pod trunk push] }
  end

  def test_trunk_republishes_immediately_when_version_is_missing
    @commands.trunk_push_error = "Calling the GitHub commit API timed out"
    delays = []
    lookups = 0
    confirmation = lambda do |*|
      lookups += 1
      @commands.trunk_push_error = nil
      nil
    end
    output, = capture_io do
      runner(request(dry_run: false), trunk_confirmation: confirmation, sleeper: ->(delay) { delays << delay }).run
    end
    assert_empty delays
    assert_equal 1, lookups
    assert_equal %w[published published], results.map { |r| r.fetch("status") }
    assert_includes output, "立即重试发布"
    assert_equal 2, @commands.calls.count { |args| args[0..4] == %w[bundle exec pod trunk push] }
  end

  def test_trunk_republication_stops_after_three_missing_confirmations
    @commands.trunk_push_error = "push timed out"
    delays = []
    capture_io do
      assert_raises(SDKRelease::Error) do
        runner(request(dry_run: false), sleeper: ->(delay) { delays << delay }).run
      end
    end
    assert_empty delays
    assert_includes results.last.fetch("message"), "已尝试发布 3 次"
    assert_equal 3, @commands.calls.count { |args| args[0..4] == %w[bundle exec pod trunk push] }
  end

  def test_trunk_push_timeout_still_fails_when_confirmation_is_unavailable
    @commands.trunk_push_error = "Calling the GitHub commit API timed out"
    lookups = 0
    delays = []
    confirmation = ->(*) { lookups += 1; raise SDKRelease::Error, "HTTP 503" }
    capture_io do
      assert_raises(SDKRelease::Error) do
        runner(request(dry_run: false), trunk_confirmation: confirmation, sleeper: ->(delay) { delays << delay }).run
      end
    end
    assert_equal %w[published failed], results.map { |r| r.fetch("status") }
    assert_includes results.last.fetch("message"), @commands.trunk_push_error
    assert_includes results.last.fetch("message"), "HTTP 503"
    assert_includes results.last.fetch("message"), "已复查 3 次"
    assert_equal 3, lookups
    assert_equal [5, 10], delays
    assert_equal 1, @commands.calls.count { |args| args[0..4] == %w[bundle exec pod trunk push] }
  end

  def test_specs_failure_still_attempts_trunk
    @commands.fail_target = "specs"
    capture_io { assert_raises(SDKRelease::Error) { runner(request(dry_run: false)).run } }
    assert_equal %w[failed published], results.map { |r| r.fetch("status") }
  end

  def test_identical_published_versions_are_skipped_on_both_targets
    @commands.existing_spec = spec
    @commands.existing_tag = ["HXGMAdapter"]
    registry = ->(name, version) { name == "HXSDK" ? @commands.spec(name, version) : spec }
    capture_io { runner(request(dry_run: false), registry: registry).run }
    assert_equal %w[already_published already_published], results.map { |r| r.fetch("status") }
    refute @commands.calls.any? { |c| c.include?("push") }
  end

  def test_different_published_spec_is_never_overwritten
    @commands.existing_spec = spec.merge("summary" => "different")
    @commands.existing_tag = ["HXGMAdapter"]
    capture_io { assert_raises(SDKRelease::Error) { runner(request(target: "specs", dry_run: false)).run } }
    assert_equal "failed", results.first.fetch("status")
    refute @commands.calls.any? { |c| c.include?("push") }
  end

  def test_registry_network_error_is_not_treated_as_a_missing_version
    registry = ->(name, version) { raise SDKRelease::Error, "timeout" unless name == "HXSDK"; @commands.spec(name, version) }
    capture_io { assert_raises(SDKRelease::Error) { runner(request(dry_run: false), registry: registry).run } }
    assert_equal "timeout", results.last.fetch("message")
    refute @commands.calls.any? { |c| c.include?("trunk") && c.include?("push") }
  end

  def test_wrong_tag_version_fails_before_any_publication
    @commands.existing_tag = ["HXGMAdapter"]
    @commands.wrong_version = "0.0.1"
    capture_io { assert_raises(SDKRelease::Error) { runner.run } }
    assert_equal "prepare", results.first.fetch("stage")
    refute @commands.calls.any? { |c| c.include?("lint") || c.include?("push") }
  end

  def test_core_build_dry_run_updates_artifact_without_pushing
    capture_io { runner(request(project: "HXSDK")).run }
    assert File.file?(File.join(@env.fetch("SDK_OUTPUT_DIR"), "HXSDK.framework/HXSDK"))
    assert_equal %w[dry_run dry_run], results.map { |r| r.fetch("status") }
    refute @commands.calls.any? { |c| c.include?("commit") || c.include?("push") || c.include?("tag") }
  end

  def test_core_publication_pushes_atomic_refs_and_records_source_commit
    capture_io { runner(request(project: "HXSDK", dry_run: false, target: "specs")).run }
    commit = @commands.calls.find { |c| c.include?("commit") }
    assert_includes commit.last, "HXSDK-Source-SHA: #{'a' * 40}"
    push = @commands.calls.find { |c| c.first == "git" && c.include?("push") }
    assert_includes push, "--atomic"
    assert_includes push, "refs/tags/#{VERSION}"
    staged = @commands.calls.find { |c| c.first == "git" && c.include?("add") }
    assert_includes staged, "HXSDK-iOS-Example/Podfile.lock"
  end

  def test_existing_core_tag_must_match_source_and_is_not_rebuilt
    @commands.existing_tag = true
    capture_io { runner(request(project: "HXSDK")).run }
    refute @commands.calls.any? { |c| c.first == "bash" || c.include?("commit") }
    @commands.provenance = "HXSDK-Source-SHA: unknown"
    capture_io { assert_raises(SDKRelease::Error) { runner(request(project: "HXSDK")).run } }
    assert_equal "failed", results.first.fetch("status")
  end

  def test_wrong_runtime_version_blocks_core_before_build
    @commands.wrong_runtime = "0.0.0"
    capture_io { assert_raises(SDKRelease::Error) { runner(request(project: "HXSDK")).run } }
    refute @commands.calls.any? { |c| c.first == "bash" || c.include?("push") }
  end

  def test_missing_trunk_token_fails_before_preparing_release
    @env.delete("COCOAPODS_TRUNK_TOKEN")
    capture_io { assert_raises(SDKRelease::Error) { runner(request(dry_run: false)).run } }
    assert_empty @commands.calls
  end

  def batch_request
    env = SDKRelease::PROJECTS.values.to_h { |_, key| [key, VERSION] }.merge("SDK_PROJECT" => "all")
    SDKRelease::Request.new({}, env)
  end

  def test_batch_builds_core_first_and_lints_adapters_with_the_new_core
    capture_io { runner(batch_request).run }
    assert_equal SDKRelease::PROJECTS.keys, results.map { |r| r.fetch("project") }.uniq
    assert_equal 10, results.size
    included = @commands.calls.select { |c| c.any? { |arg| arg.start_with?("--include-podspecs=") } }
    assert_equal 4, included.size
    refute @commands.calls.any? { |c| c.include?("commit") || c.include?("push") }
  end

  def test_failed_core_blocks_batch_adapters
    @commands.wrong_runtime = "0.0.0"
    capture_io { assert_raises(SDKRelease::Error) { runner(batch_request).run } }
    assert_equal ["failed", *Array.new(4, "blocked")], results.map { |r| r.fetch("status") }
  end

  def assert_no_git_writes
    refute @commands.calls.any? { |c| c.first == "git" && (c & %w[add commit tag push]).any? }
  end

  def test_adapter_requires_an_explicit_sdk_version
    assert_raises(SDKRelease::Error) { request(hx_sdk_version: nil) }
    assert_raises(SDKRelease::Error) { request(hx_sdk_version: "v5.2.11") }
    assert_equal SDK_VERSION, request.sdk_version
  end

  def test_adapters_batch_requires_four_versions_and_one_sdk_tag
    env = SDKRelease::PROJECTS.values.to_h { |_, key| [key, VERSION] }
    env.merge!("SDK_PROJECT" => "adapters", "HXSDK_VERSION" => SDK_VERSION)
    req = SDKRelease::Request.new({}, env)
    assert_equal SDKRelease::PROJECTS.keys - ["HXSDK"], req.versions.keys
    assert_equal SDK_VERSION, req.sdk_version
    env.delete("GM_VERSION")
    assert_raises(SDKRelease::Error) { SDKRelease::Request.new({}, env) }
  end

  def test_adapter_release_orders_resolution_lint_atomic_push_and_publication
    capture_io { runner(request(dry_run: false)).run }
    assert_equal %w[published published], results.map { |r| r.fetch("status") }
    calls = @commands.calls
    resolve = calls.index { |c| c[0..3] == %w[bundle exec pod update] }
    lint = calls.index { |c| c[0..4] == %w[bundle exec pod lib lint] }
    commit = calls.index { |c| c.first == "git" && c.include?("commit") }
    push = calls.index { |c| c.first == "git" && c.include?("push") }
    publish = calls.index { |c| c[0..4] == %w[bundle exec pod repo push] }
    assert resolve < lint && lint < commit && commit < push && push < publish
    assert_includes calls[push], "--atomic"
    assert_includes calls[push], "HEAD:refs/heads/main"
    assert_includes calls[push], "refs/tags/#{VERSION}"
    assert_includes calls[commit].last, "HXSDK-Dependency-Tag: #{SDK_VERSION}"
    assert_includes calls[commit].last, "HXSDK-Dependency-SHA: #{'c' * 40}"
    staged = calls.find { |c| c.first == "git" && c.include?("add") }
    assert_equal ["HXGMAdapter.podspec", "Example/Podfile", "Example/Podfile.lock", "README.md"], staged.drop(staged.index("--") + 1)
    assert_includes calls[resolve], "--no-repo-update"
    assert_includes calls[lint].last, "--include-podspecs="
  end

  def test_adapter_dry_run_resolves_and_validates_without_git_writes
    capture_io { runner.run }
    assert_equal 1, @commands.examples_at_update.size
    example = @commands.examples_at_update.first
    assert_includes example, "pod 'HXGMAdapter', :path => '..'"
    assert_includes example, "pod 'HXSDK/UBiX', '~> #{SDK_VERSION}'"
    assert_includes example, SDKRelease::SPECS_URL
    assert_no_git_writes
  end

  def test_missing_sdk_tag_blocks_before_any_adapter_preparation
    @commands.missing_sdk_tag = true
    capture_io { assert_raises(SDKRelease::Error) { runner.run } }
    assert results.any? { |r| r["message"] == "missing SDK tag" }
    refute @commands.calls.any? { |c| c.first == "git" && c[1] == "clone" && c.last.end_with?("/HXGMAdapter") }
    assert_no_git_writes
  end

  def test_sdk_must_be_published_to_specs
    @commands.sdk_published = false
    capture_io { assert_raises(SDKRelease::Error) { runner.run } }
    assert_includes results.first.fetch("message"), "尚未发布到 Specs"
    assert_no_git_writes
  end

  def test_both_requires_sdk_on_trunk_before_adapter_changes
    capture_io { assert_raises(SDKRelease::Error) { runner(registry: ->(*) { nil }).run } }
    assert_includes results.first.fetch("message"), "尚未发布到 Trunk"
    assert_no_git_writes
  end

  def test_sdk_index_must_match_the_selected_tag
    @commands.sdk_index_spec = @commands.spec("HXSDK", SDK_VERSION).merge("summary" => "different")
    capture_io { assert_raises(SDKRelease::Error) { runner.run } }
    assert_includes results.first.fetch("message"), "禁止覆盖"
    assert_no_git_writes
  end

  def test_sdk_podspec_version_must_match_its_tag
    @commands.sdk_tag_version = "5.2.10"
    capture_io { assert_raises(SDKRelease::Error) { runner.run } }
    assert_includes results.first.fetch("message"), "版本与请求不一致"
    assert_no_git_writes
  end

  def test_new_adapter_version_must_increase
    @commands.main_version = VERSION
    capture_io { assert_raises(SDKRelease::Error) { runner.run } }
    assert_includes results.first.fetch("message"), "新版本必须高于"
    assert_empty @commands.examples_at_update
    assert_no_git_writes
  end

  def test_existing_adapter_tag_with_other_sdk_is_rejected
    @commands.existing_tag = ["HXGMAdapter"]
    @commands.tag_dependency = "~> 5.2.9"
    capture_io { assert_raises(SDKRelease::Error) { runner.run } }
    assert_includes results.first.fetch("message"), "已有 tag 禁止覆盖"
    assert_no_git_writes
  end

  def test_existing_adapter_tag_with_other_sdk_commit_is_rejected
    @commands.existing_tag = ["HXGMAdapter"]
    @commands.provenance = "HXSDK-Dependency-SHA: #{'f' * 40}"
    capture_io { assert_raises(SDKRelease::Error) { runner.run } }
    assert_includes results.first.fetch("message"), "提交与所选 tag 不匹配"
    assert_no_git_writes
  end

  def test_resolution_and_lint_failures_cannot_push_or_publish
    %i[fail_resolve fail_lint].each do |setting|
      @commands.public_send("#{setting}=", true)
      capture_io { assert_raises(SDKRelease::Error) { runner(request(dry_run: false)).run } }
      assert_includes %w[resolve validate], results.first.fetch("stage")
      assert_no_git_writes
      refute @commands.calls.any? { |c| c.include?("push") }
      @commands.public_send("#{setting}=", false)
    end
  end

  def test_rejected_git_push_prevents_pod_publication
    @commands.fail_push = true
    capture_io { assert_raises(SDKRelease::Error) { runner(request(dry_run: false)).run } }
    assert_equal "push", results.first.fetch("stage")
    refute @commands.calls.any? { |c| c.first == "bundle" && c.include?("push") }
  end

  def test_missing_generated_lockfile_blocks_release
    @commands.missing_lock = true
    capture_io { assert_raises(SDKRelease::Error) { runner(request(dry_run: false)).run } }
    assert_equal "resolve", results.first.fetch("stage")
    assert_includes results.first.fetch("message"), "未生成 Podfile.lock"
    assert_no_git_writes
  end

  def test_trunk_push_clones_specs_only_while_sdk_is_missing_from_cdn
    versions = SDKRelease::PROJECTS.values.to_h { |_, key| [key, VERSION] }.merge("HXSDK_VERSION" => SDK_VERSION)
    req = SDKRelease::Request.new({ project: "all", dry_run: false }, versions)
    lookups = []
    cdn_ready = lambda do |name, version|
      lookups << [name, version]
      lookups.size > 1
    end

    capture_io { runner(req, cdn_ready: cdn_ready).run }

    pushes = @commands.calls.select { |args| args[0..4] == %w[bundle exec pod trunk push] }
    assert_equal SDKRelease::PROJECTS.keys.map { |name| "#{name}.podspec" }, pushes.map { |args| args[5] }
    assert_equal ["HXTakuAdapter.podspec"], pushes.filter_map { |args| args[5] if args.include?("--synchronous") }
    assert_equal [["HXSDK", SDK_VERSION], ["HXSDK", SDK_VERSION]], lookups
    assert_equal ["published"], results.map { |result| result.fetch("status") }.uniq
  end

  def test_all_mode_blocks_adapters_after_partial_core_publication
    @commands.fail_target = "trunk"
    req = SDKRelease::Request.new({ project: "all", dry_run: false }, SDKRelease::PROJECTS.values.to_h { |_, key| [key, VERSION] })
    capture_io { assert_raises(SDKRelease::Error) { runner(req).run } }
    assert_equal ["published", "failed", *Array.new(4, "blocked")], results.map { |r| r.fetch("status") }
    assert_empty @commands.examples_at_update
  end

  def test_adapters_batch_continues_after_one_adapter_fails_validation
    @commands.fail_lint = "HXToBidAdapter"
    env = SDKRelease::PROJECTS.values.to_h { |_, key| [key, VERSION] }.merge("SDK_PROJECT" => "adapters", "HXSDK_VERSION" => SDK_VERSION)
    capture_io { assert_raises(SDKRelease::Error) { runner(SDKRelease::Request.new({}, env)).run } }
    assert_equal ["HXTakuAdapter", "HXToBidAdapter", "HXToBidAdapterNew", "HXGMAdapter"], results.map { |r| r.fetch("project") }.uniq
    assert_equal 1, results.count { |r| r["status"] == "failed" }
    assert_equal 6, results.count { |r| r["status"] == "dry_run" }
    assert_no_git_writes
  end

  def test_podfile_conversion_is_targeted_and_idempotent
    before = <<~PODFILE
      source 'https://cdn.cocoapods.org/'
      target 'Example' do
        pod 'HXToBidAdapterNew', :path => '../../old'
        pod 'HXSDK/UBiX', '~> 5.2.9' # SDK
        pod 'Other', '~> 1.0.0'
        # pod 'HXSDK', '5.0.0'
      end
    PODFILE
    result = SDKRelease::AdapterRelease.update_podfile(before, "HXToBidAdapterNew", SDK_VERSION)
    assert_includes result, "pod 'HXToBidAdapterNew', :path => '..'"
    assert_includes result, "pod 'HXSDK/UBiX', '~> #{SDK_VERSION}' # SDK"
    assert_includes result, "pod 'Other', '~> 1.0.0'"
    assert_includes result, "# pod 'HXSDK', '5.0.0'"
    assert_equal 1, result.scan(SDKRelease::SPECS_URL).size
    assert_equal result, SDKRelease::AdapterRelease.update_podfile(result, "HXToBidAdapterNew", SDK_VERSION)
  end

  def test_unversioned_sdk_and_modern_path_syntax_are_updated
    before = "pod 'HXGMAdapter', path: '../'\npod 'HXSDK/UBiX'\n"
    result = SDKRelease::AdapterRelease.update_podfile(before, "HXGMAdapter", SDK_VERSION)
    assert_includes result, "pod 'HXGMAdapter', :path => '..'"
    assert_includes result, "pod 'HXSDK/UBiX', '~> #{SDK_VERSION}'"
  end

  def test_podfile_rejects_missing_adapter_path_and_external_sdk_override
    assert_raises(SDKRelease::Error) { SDKRelease::AdapterRelease.update_podfile("pod 'HXGMAdapter'\n", "HXGMAdapter", SDK_VERSION) }
    assert_raises(SDKRelease::Error) { SDKRelease::AdapterRelease.update_podfile("pod 'HXGMAdapter', :path => '..'\npod 'HXSDK', :path => 'elsewhere'\n", "HXGMAdapter", SDK_VERSION) }
  end

  def test_preview_restores_podfile_even_after_resolution_failure
    path = File.join(@dir, "Podfile")
    before = "pod 'HXGMAdapter', :path => '..'\npod 'HXSDK/UBiX', '~> #{SDK_VERSION}'\n"
    File.write(path, before)
    assert_raises(SDKRelease::Error) do
      SDKRelease::AdapterRelease.with_preview_sdk(path, "/tmp/new-sdk") do
        assert_includes File.read(path), "pod 'HXSDK', :path => '/tmp/new-sdk'"
        assert_includes File.read(path), "pod 'HXSDK/UBiX', :path => '/tmp/new-sdk'"
        raise SDKRelease::Error, "resolution failed"
      end
    end
    assert_equal before, File.read(path)
  end
end
