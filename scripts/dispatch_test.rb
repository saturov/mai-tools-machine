#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"

require_relative "dispatch"

class DispatchTest < Minitest::Test
  def test_dev_prefixed_text_bypasses_dispatcher_routing
    Dir.mktmpdir do |dir|
      output_path = File.join(dir, "dispatch-output.json")

      code = Dispatch.run_from_text(
        "Dev: обнови AGENTS.md под новый workflow",
        registry_path: File.join(dir, "missing-registry.json"),
        runs_dir: dir,
        dry_run: false,
        execute: false,
        pretty: false,
        output_path: output_path
      )

      assert_equal 0, code

      payload = JSON.parse(File.read(output_path))
      assert_equal "bypass", payload["status"]
      assert_equal "developer_request", payload["reason"]
      assert_equal "Dev: обнови AGENTS.md под новый workflow", payload.dig("request", "user_goal")
    end
  end
end
