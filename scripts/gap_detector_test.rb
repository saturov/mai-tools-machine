#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "yaml"
require_relative "../skills/request-router/request_router"
require_relative "../skills/gap-detector/gap_detector"

class GapDetectorTest < Minitest::Test
  def registry_path
    File.expand_path("../state/registry-cache.json", __dir__)
  end

  def example_request
    request_path = File.expand_path("../templates/workflow/request.example.yaml", __dir__)
    YAML.safe_load(File.read(request_path))
  end

  def test_detects_no_gaps_and_sets_tools_when_registry_covers_capabilities
    plan = RequestRouter.build_plan(example_request, now: Time.utc(2026, 2, 17, 0, 0, 0))
    GapDetector.apply!(plan, registry_path: registry_path)

    assert_equal "complete", plan["status"]
    assert_equal [], plan["gap_report"]

    assert_includes plan.dig("steps", 0, "tool"), "youtube-downloader@"
    assert_includes plan.dig("steps", 1, "tool"), "drive-uploader@"
  end

  def test_detects_gap_for_unknown_capability
    plan = RequestRouter.build_plan(example_request, now: Time.utc(2026, 2, 17, 0, 0, 0))
    plan["steps"] << {
      "step_id" => "step-3",
      "capability" => "tg.scrape",
      "tool" => nil,
      "inputs" => {},
    }

    GapDetector.apply!(plan, registry_path: registry_path)

    assert_equal "partial-complete", plan["status"]
    assert_equal 1, plan.fetch("gap_report").length
    assert_equal "tg.scrape", plan["gap_report"][0]["missing_capability"]
    assert_equal "no_capability_match", plan["gap_report"][0]["reason"]
  end

  def test_detects_gap_when_schema_is_incompatible
    plan = RequestRouter.build_plan(example_request, now: Time.utc(2026, 2, 17, 0, 0, 0))
    plan["steps"][0]["capability_contract"]["input_schema"]["required"] = %w[url access_token]
    plan["steps"][0]["capability_contract"]["input_schema"]["properties"]["access_token"] = { "type" => "string" }

    GapDetector.apply!(plan, registry_path: registry_path)

    assert_equal "partial-complete", plan["status"]
    assert_equal "schema_incompatible", plan.dig("gap_report", 0, "reason")
    assert_nil plan.dig("steps", 0, "tool")
  end

  def test_detects_gap_for_low_llm_confidence_even_when_schema_matches
    plan = RequestRouter.build_plan(example_request, now: Time.utc(2026, 2, 17, 0, 0, 0))
    step = plan["steps"][0]
    step["planner_source"] = "llm"
    step["coverage_confidence"] = 0.5
    step["coverage_rationale"] = "weak match"

    GapDetector.apply!(plan, registry_path: registry_path)

    assert_equal "partial-complete", plan["status"]
    assert_equal "low_confidence", plan.dig("gap_report", 0, "reason")
    assert_nil plan.dig("steps", 0, "tool")
  end

  def test_rule_step_with_full_confidence_and_compatible_schema_is_complete
    plan = RequestRouter.build_plan(example_request, now: Time.utc(2026, 2, 17, 0, 0, 0))
    plan["steps"][0]["coverage_confidence"] = 1.0
    plan["steps"][0]["coverage_rationale"] = "rule_matched"

    GapDetector.apply!(plan, registry_path: registry_path)

    assert_equal "complete", plan["status"]
    refute_nil plan.dig("steps", 0, "tool")
  end
end
