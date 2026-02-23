#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"

require_relative "policy_engine"

class PolicyEngineTest < Minitest::Test
  def registry_path
    File.expand_path("../state/registry-cache.json", __dir__)
  end

  def test_blocks_capability_not_in_allowlist
    plan = {
      "steps" => [
        { "step_id" => "step-1", "capability" => "tg.scrape", "tool" => nil, "inputs" => {} },
      ],
    }
    policy = PolicyEngine.default_policy.merge("allowed_capabilities" => ["youtube.download"])
    result = PolicyEngine.check!(plan, policy: policy, registry_path: registry_path, execute: false)

    assert_equal "blocked_by_policy", result["status"]
    assert_equal "capability_not_allowed", result.dig("violations", 0, "reason")
    assert_equal "deny", result["verdict"]
    assert_equal "high", result["risk"]
    assert_equal "capability_not_allowed", result["reason"]
    assert_equal "no", result["confirmation_required"]
  end

  def test_allowlist_and_denied_precedence
    plan = {
      "steps" => [
        { "step_id" => "step-1", "capability" => "youtube.download", "tool" => "youtube-downloader@0.1.0", "inputs" => {} },
      ],
    }
    policy = PolicyEngine.default_policy.merge(
      "allowed_capabilities" => ["youtube.download"],
      "denied_capabilities" => ["youtube.download"]
    )
    result = PolicyEngine.check!(plan, policy: policy, registry_path: registry_path, execute: true)
    assert_equal "blocked_by_policy", result["status"]
    reasons = result["violations"].map { |v| v["reason"] }
    assert_includes reasons, "capability_denied"
    assert_equal "deny", result["verdict"]
  end

  def test_allows_when_policy_has_no_violations_with_status_fields
    plan = {
      "steps" => [
        { "step_id" => "step-1", "capability" => "youtube.download", "tool" => "youtube-downloader@0.1.0", "inputs" => {} },
      ],
    }
    policy = PolicyEngine.default_policy
    result = PolicyEngine.check!(plan, policy: policy, registry_path: registry_path, execute: false)
    assert_equal "ok", result["status"]
    assert_equal "allow", result["verdict"]
    assert_equal "low", result["risk"]
    assert_equal "policy_passed", result["reason"]
    assert_equal "no", result["confirmation_required"]
  end
end
