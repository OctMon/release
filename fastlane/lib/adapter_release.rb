# frozen_string_literal: true

module SDKRelease
  module AdapterRelease
    EXAMPLES = {
      "HXTakuAdapter" => "HXTakuAdapter-iOS-Example",
      "HXToBidAdapter" => "HXWindAdapter-iOS-Example",
      "HXToBidAdapterNew" => "HXWindAdapter-iOS-Example",
      "HXGMAdapter" => "Example"
    }.freeze

    module_function

    def prepare(root:, name:, version:, sdk_version:)
      spec = File.join(root, "#{name}.podspec")
      SDKRelease.update_version(spec, version)
      content = File.read(spec)
      dependency = /^([ \t]*s\.dependency[ \t]+['"]HXSDK['"][ \t]*,[ \t]*)['"][^'"\n]*['"]([ \t]*(?:#.*)?)$/
      raise Error, "#{name} 必须有且只有一个 HXSDK 版本依赖" unless content.scan(dependency).size == 1

      File.write(spec, content.sub(dependency) { "#{Regexp.last_match(1)}'~> #{sdk_version}'#{Regexp.last_match(2)}" })
      example = EXAMPLES.fetch(name)
      podfile = File.join(root, example, "Podfile")
      File.write(podfile, update_podfile(File.read(podfile), name, sdk_version))
      paths = ["#{name}.podspec", "#{example}/Podfile", "#{example}/Podfile.lock"]
      readme = File.join(root, "README.md")
      if File.file?(readme)
        before = File.read(readme)
        after = before.gsub(/\bHXSDK[ \t]+~>[ \t]+\d+\.\d+\.\d+/, "HXSDK ~> #{sdk_version}")
        after = after.gsub(/(pod\s+['"]HXSDK(?:\/[^'"]+)?['"],\s*['"])(?:~>\s*)?\d+\.\d+\.\d+(['"])/) do
          "#{Regexp.last_match(1)}~> #{sdk_version}#{Regexp.last_match(2)}"
        end
        if after != before
          File.write(readme, after)
          paths << "README.md"
        end
      end
      paths
    end

    def update_podfile(content, name, sdk_version)
      local_references = 0
      result = content.lines.map do |line|
        next line unless (match = line.match(/\A([ \t]*pod[ \t]+)(['"])([^'"]+)\2(.*)$/))

        prefix, quote, pod_name, tail = match.captures
        if pod_name == name
          path = /(?::path\s*=>|\bpath:)\s*['"][^'"]*['"]/
          raise Error, "示例的 #{name} 必须使用本地 :path" unless tail.scan(path).size == 1

          local_references += 1
          tail = tail.sub(path, ":path => '..'")
        elsif pod_name == "HXSDK" || pod_name.start_with?("HXSDK/")
          raise Error, "示例 HXSDK 引用不能包含外部源码选项" if tail.match?(/\b(?:path|git|podspec)\s*(?:=>|:)/)

          tail = tail.sub(/\A\s*,\s*(['"])[^'"]*\1/, "")
          tail = ", '~> #{sdk_version}'#{tail}"
        else
          next line
        end
        "#{prefix}#{quote}#{pod_name}#{quote}#{tail}#{line.end_with?("\n") ? "\n" : ""}"
      end.join
      raise Error, "示例缺少 #{name} 的本地 Pod 引用" if local_references.zero?

      source = /^[ \t]*source[ \t]+['"]#{Regexp.escape(SPECS_URL)}['"]/
      result = "source '#{SPECS_URL}'\n#{result}" unless result.match?(source)
      result
    end

    # A new core version does not have a remote binary tag during an all-project
    # preview. Use its local framework only in that preview, restoring the Podfile
    # afterwards. The preview lockfile is never committed.
    def with_preview_sdk(podfile, sdk_root)
      original = File.read(podfile)
      escaped_root = sdk_root.gsub("\\") { "\\\\" }.gsub("'") { "\\'" }
      preview = original.lines.map do |line|
        line.sub(/\A([ \t]*pod[ \t]+(['"])HXSDK(?:\/[^'"]+)?\2).*$/) do
          "#{Regexp.last_match(1)}, :path => '#{escaped_root}'"
        end
      end.join
      # Also cover examples that reference HXSDK only through the adapter.
      preview = "pod 'HXSDK', :path => '#{escaped_root}'\n#{preview}" unless preview.match?(/^[ \t]*pod[ \t]+['"]HXSDK['"]/)
      File.write(podfile, preview)
      yield
    ensure
      File.write(podfile, original) if original
    end
  end
end
