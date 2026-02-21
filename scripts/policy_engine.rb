#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"

require_relative "tool_registry"

module PolicyEngine
  class ValidationError < StandardError; end

  module_function

  def default_policy
    {
      "allowed_capabilities" => [],
      "denied_capabilities" => [],
      "max_steps" => 10,
      "max_tool_retries" => 1,
      "max_run_seconds" => 600,
      "max_llm_calls" => 1,
      "require_idempotent_for_auto" => false,
    }
  end

  def safe_load_yaml(path)
    contents = File.read(path)
    begin
      YAML.safe_load(contents, permitted_classes: [], permitted_symbols: [], aliases: false)
    rescue ArgumentError
      YAML.safe_load(contents)
    end
  rescue Errno::ENOENT
    raise ValidationError, "Policy file not found: #{path}"
  rescue Psych::Exception => e
    raise ValidationError, "YAML parse error in #{path}: #{e.message}"
  end

  def load_policy(path = nil)
    return default_policy if path.nil? || path.to_s.strip.empty?
    return default_policy unless File.exist?(path)
    raw = safe_load_yaml(path)
    raise ValidationError, "policy must be an object/map" unless raw.is_a?(Hash)
    default_policy.merge(raw.transform_keys(&:to_s))
  end

  def check!(plan, policy:, registry_path:, execute:)
    raise ValidationError, "plan must be an object/map" unless plan.is_a?(Hash)
    steps = plan["steps"]
    raise ValidationError, "plan.steps must be an array" unless steps.is_a?(Array)

    report = []
    allowed = Array(policy["allowed_capabilities"]).map(&:to_s)
    denied = Array(policy["denied_capabilities"]).map(&:to_s)
    max_steps = policy["max_steps"].to_i

    report << { "reason" => "step_limit_exceeded", "details" => "steps=#{steps.length}, max_steps=#{max_steps}" } if max_steps.positive? && steps.length > max_steps

    registry = ToolRegistry.load_registry!(registry_path)
    by_id = registry.dig("index", "by_id") || {}
    require_idempotent = policy["require_idempotent_for_auto"] == true

    steps.each do |step|
      cap = step["capability"].to_s
      step_id = step["step_id"].to_s
      if !allowed.empty? && !allowed.include?(cap)
        report << { "step_id" => step_id, "capability" => cap, "reason" => "capability_not_allowed" }
      end
      if denied.include?(cap)
        report << { "step_id" => step_id, "capability" => cap, "reason" => "capability_denied" }
      end

      next unless execute && require_idempotent
      tool_id = step["tool"]
      next unless tool_id.is_a?(String) && !tool_id.empty?
      tool = by_id[tool_id]
      next unless tool.is_a?(Hash)
      if tool["idempotency"] != "safe"
        report << { "step_id" => step_id, "tool" => tool_id, "reason" => "idempotency_required" }
      end
    end

    if report.empty?
      { "status" => "ok", "policy" => policy, "violations" => [] }
    else
      {
        "status" => "blocked_by_policy",
        "policy" => policy,
        "violations" => report,
      }
    end
  end
end
