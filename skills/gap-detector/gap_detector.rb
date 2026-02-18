#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "pathname"
require "time"

require_relative "../../scripts/tool_registry"

module GapDetector
  class ValidationError < StandardError; end
  MIN_LLM_COVERAGE_CONFIDENCE = 0.75

  module_function

  def repo_root
    @repo_root ||= Pathname.new(__dir__).join("..", "..").expand_path
  end

  def default_registry_path
    File.join(repo_root.to_s, "state", "registry-cache.json")
  end

  def load_json(path)
    JSON.parse(File.read(path))
  rescue Errno::ENOENT
    raise ValidationError, "Plan file not found: #{path}"
  rescue JSON::ParserError => e
    raise ValidationError, "Invalid JSON in #{path}: #{e.message}"
  end

  def default_schema
    { "type" => "object", "required" => [], "additionalProperties" => true, "properties" => {} }
  end

  def proposed_tool_name_for(capability)
    return "unknown-tool" unless capability.is_a?(String) && capability.include?(".")

    domain, action = capability.split(".", 2)
    actioner =
      case action
      when "download" then "downloader"
      when "upload" then "uploader"
      else action
      end

    name = "#{domain}-#{actioner}"
    name.gsub(/[^a-z0-9-]/, "-")
  end

  def gap_reason_message(reason_code)
    case reason_code
    when "no_capability_match" then "No tools found in registry for capability"
    when "schema_incompatible" then "Tools exist for capability, but none match required capability contract"
    when "low_confidence" then "LLM confidence for selected capability is below threshold"
    when "invalid_capability" then "Step capability is missing or invalid"
    else "Step is not covered by available tools"
    end
  end

  def gap_entry_for(step, step_index, reason_code:, reason_details: nil)
    cap = step["capability"]
    contract = step["capability_contract"].is_a?(Hash) ? step["capability_contract"] : {}
    input_schema = contract["input_schema"].is_a?(Hash) ? contract["input_schema"] : default_schema
    output_schema = contract["output_schema"].is_a?(Hash) ? contract["output_schema"] : default_schema

    {
      "missing_capability" => cap,
      "reason" => reason_code,
      "reason_message" => gap_reason_message(reason_code),
      "reason_details" => reason_details,
      "proposed_tool_name" => proposed_tool_name_for(cap),
      "proposed_input_schema" => input_schema,
      "proposed_output_schema" => output_schema,
      "priority" => (step_index == 0 ? "high" : "medium"),
    }
  end

  def coverage_confidence_for(step)
    raw = step["coverage_confidence"]
    return 0.0 unless raw.is_a?(Numeric)
    return 0.0 if raw.negative?
    return 1.0 if raw > 1.0
    raw.to_f
  end

  def contract_for_step(step)
    contract = step["capability_contract"]
    return nil unless contract.is_a?(Hash)
    input = contract["input_schema"]
    output = contract["output_schema"]
    return nil unless input.is_a?(Hash) && output.is_a?(Hash)

    { "input_schema" => input, "output_schema" => output }
  end

  def compatible_tools_for_step(step, tools)
    contract = contract_for_step(step)
    return [[], "step capability_contract is missing input_schema/output_schema"] if contract.nil?

    compatible = tools.select do |tool|
      input_ok = ToolRegistry::SchemaSubset.subset?(contract["input_schema"], tool["input_schema"])
      output_ok = ToolRegistry::SchemaSubset.subset?(contract["output_schema"], tool["output_schema"])
      input_ok && output_ok
    end
    return [compatible, nil] unless compatible.empty?

    [compatible, "no tool satisfies capability_contract.input_schema/output_schema"]
  end

  def apply!(plan, registry_path: default_registry_path)
    raise ValidationError, "plan must be an object" unless plan.is_a?(Hash)

    steps = plan["steps"]
    raise ValidationError, "plan.steps must be an array" unless steps.is_a?(Array)

    registry = ToolRegistry.load_registry!(registry_path)
    by_cap = registry.dig("index", "by_capability") || {}
    by_id = registry.dig("index", "by_id") || {}

    gaps = []

    steps.each_with_index do |step, idx|
      next unless step.is_a?(Hash)
      cap = step["capability"]
      unless cap.is_a?(String) && !cap.strip.empty?
        gaps << gap_entry_for(step, idx, reason_code: "invalid_capability")
        step["tool"] = nil
        next
      end

      ids = by_cap[cap]
      unless ids.is_a?(Array) && !ids.empty?
        step["tool"] = nil
        gaps << gap_entry_for(step, idx, reason_code: "no_capability_match")
        next
      end

      tool_candidates = ids.map { |id| by_id[id] }.compact
      compatible_tools, compatibility_error = compatible_tools_for_step(step, tool_candidates)
      if compatible_tools.empty?
        step["tool"] = nil
        gaps << gap_entry_for(step, idx, reason_code: "schema_incompatible", reason_details: compatibility_error)
        next
      end

      if step["planner_source"] == "llm"
        confidence = coverage_confidence_for(step)
        if confidence < MIN_LLM_COVERAGE_CONFIDENCE
          step["tool"] = nil
          gaps << gap_entry_for(
            step,
            idx,
            reason_code: "low_confidence",
            reason_details: "coverage_confidence=#{confidence} < #{MIN_LLM_COVERAGE_CONFIDENCE}"
          )
          next
        end
      end

      best = ToolRegistry.pick_best_tool(compatible_tools)
      unless best
        step["tool"] = nil
        gaps << gap_entry_for(step, idx, reason_code: "schema_incompatible", reason_details: "no compatible tool candidate selected")
        next
      end

      step["tool"] = best["id"]
      step["tool_meta"] = {
        "name" => best["name"],
        "version" => best["version"],
        "source_path" => best["source_path"],
      }
    end

    plan["gap_report"] = gaps
    plan["status"] = gaps.empty? ? "complete" : "partial-complete"
    plan
  end

  class CLI
    def self.run(argv)
      command = argv.shift
      case command
      when "detect"
        plan_path = nil
        registry_path = GapDetector.default_registry_path
        output_path = nil
        pretty = false

        OptionParser.new do |o|
          o.on("--plan PATH", "Path to workflow plan JSON") { |v| plan_path = v }
          o.on("--registry PATH", "Path to registry cache JSON") { |v| registry_path = v }
          o.on("--output PATH", "Write updated plan JSON to PATH (default: stdout)") { |v| output_path = v }
          o.on("--pretty", "Pretty-print JSON") { pretty = true }
        end.parse!(argv)

        raise ValidationError, "Missing --plan PATH" if plan_path.nil? || plan_path.strip.empty?

        plan = GapDetector.load_json(plan_path)
        GapDetector.apply!(plan, registry_path: registry_path)

        json = pretty ? JSON.pretty_generate(plan) : JSON.generate(plan)
        json << "\n"

        if output_path
          File.write(output_path, json)
        else
          print json
        end
        return 0
      else
        warn(<<~USAGE)
          Usage:
            gap_detector.rb detect --plan PATH [--registry PATH] [--output PATH] [--pretty]
        USAGE
        return 1
      end
    rescue ValidationError, ToolRegistry::ValidationError => e
      warn(e.message)
      return 1
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  exit(GapDetector::CLI.run(ARGV))
end
