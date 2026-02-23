#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "pathname"
require "time"
require "yaml"

module RequestRouter
  class ValidationError < StandardError; end

  DEFAULT_TARGET_QUALITY = 720
  MIN_TARGET_QUALITY = 144
  MAX_TARGET_QUALITY = 4320

  module_function

  def repo_root
    @repo_root ||= Pathname.new(__dir__).join("..", "..").expand_path
  end

  def safe_load_yaml(path)
    contents = File.read(path)
    begin
      YAML.safe_load(contents, permitted_classes: [], permitted_symbols: [], aliases: false)
    rescue ArgumentError
      YAML.safe_load(contents)
    end
  rescue Psych::Exception => e
    raise ValidationError, "YAML parse error in #{path}: #{e.message}"
  end

  def stringify_keys(value)
    case value
    when Hash
      value.each_with_object({}) { |(k, v), out| out[k.to_s] = stringify_keys(v) }
    when Array
      value.map { |v| stringify_keys(v) }
    else
      value
    end
  end

  def generate_request_id(now = Time.now.utc)
    "req-#{now.strftime("%Y%m%d%H%M%S")}-#{rand(1000..9999)}"
  end

  def extract_youtube_url(text)
    return nil unless text.is_a?(String)
    m = text.match(%r{https?://[^\s)>"']+}i)
    return nil unless m
    url = m[0]
    return url if youtube_url?(url)

    # Scan all URLs if the first one isn't YouTube
    text.scan(%r{https?://[^\s)>"']+}i).find { |u| youtube_url?(u) }
  end

  def extract_drive_folder_id(text)
    return nil unless text.is_a?(String)

    # Common folder URL: https://drive.google.com/drive/folders/<id>
    if (m = text.match(%r{drive\.google\.com/drive/folders/([a-zA-Z0-9_-]+)}i))
      return m[1]
    end

    # Fallback: any Drive URL with ?id=<id>
    if (m = text.match(/drive\.google\.com\/[^\s]*[?&]id=([a-zA-Z0-9_-]+)/i))
      return m[1]
    end

    nil
  end

  def extract_yandex_disk_url(text)
    return nil unless text.is_a?(String)
    text.scan(%r{https?://[^\s)>"']+}i).find { |u| u.match?(/disk\.yandex\.(?:ru|com)/i) }
  end

  def extract_webm_file_names(text)
    return [] unless text.is_a?(String)

    text.scan(/([^\s,;:()"'<>]+\.webm)\b/i).flatten.map do |token|
      cleaned = token.to_s.strip.sub(/[.,;:!?]+\z/, "")
      File.basename(cleaned)
    end.uniq
  end

  def normalize_target_quality(value)
    parsed =
      case value
      when Integer
        value
      when String
        stripped = value.strip
        return nil if stripped.empty?
        Integer(stripped, 10)
      else
        nil
      end
    return nil if parsed.nil?
    return nil if parsed < MIN_TARGET_QUALITY || parsed > MAX_TARGET_QUALITY

    parsed
  rescue ArgumentError
    nil
  end

  def extract_target_quality(text)
    return nil unless text.is_a?(String)
    return nil if text.strip.empty?

    patterns = [
      /(?:в\s+качеств[ео]|качество)\s*(\d{3,4})(?:p)?\b/i,
      /\b(\d{3,4})\s*p\b/i,
    ]
    patterns.each do |pattern|
      match = text.match(pattern)
      next unless match
      parsed = normalize_target_quality(match[1])
      return parsed unless parsed.nil?
    end
    nil
  end

  def resolved_target_quality(inputs)
    value = normalize_target_quality(inputs["target_quality"])
    value || DEFAULT_TARGET_QUALITY
  end

  def video_convert_intent?(text)
    return false unless text.is_a?(String)
    s = text.downcase
    return false unless s.include?("webm")
    return true if s.match?(/(?:конверт|перекод|преобраз|convert|transcod)/)
    s.include?("mp4")
  end

  def youtube_url?(value)
    return false unless value.is_a?(String)
    return false if value.strip.empty?
    value.match?(/youtube\.com|youtu\.be/i)
  end

  def nonempty_string!(value, label:)
    return value if value.is_a?(String) && !value.strip.empty?
    raise ValidationError, "#{label} must be a non-empty string"
  end

  def capability_contract_for(capability)
    case capability
    when "youtube.download"
      {
        "input_schema" => {
          "type" => "object",
          "required" => ["url"],
          "additionalProperties" => true,
          "properties" => {
            "url" => { "type" => "string" },
            "cookies_from_browser" => { "type" => "string" },
            "target_quality" => { "type" => "integer" },
            "min_height" => { "type" => "integer" },
            "quality_policy" => { "type" => "string", "enum" => %w[strict best_effort] },
            "player_clients" => { "type" => "array", "items" => { "type" => "string" } },
          },
        },
        "output_schema" => {
          "type" => "object",
          "required" => ["file_path"],
          "additionalProperties" => true,
          "properties" => {
            "file_path" => { "type" => "string" },
            "target_quality" => { "type" => "integer" },
            "actual_quality" => { "type" => "integer" },
            "fallback" => { "type" => "boolean" },
            "fallback_reason" => { "type" => "string" },
          },
        },
      }
    when "drive.upload"
      {
        "input_schema" => {
          "type" => "object",
          "required" => %w[file_path folder_id],
          "additionalProperties" => true,
          "properties" => {
            "file_path" => { "type" => "string" },
            "folder_id" => { "type" => "string" },
          },
        },
        "output_schema" => {
          "type" => "object",
          "required" => %w[file_id file_name],
          "additionalProperties" => true,
          "properties" => {
            "file_id" => { "type" => "string" },
            "file_name" => { "type" => "string" },
          },
        },
      }
    when "yandex.disk.upload"
      {
        "input_schema" => {
          "type" => "object",
          "required" => %w[file_path destination_url],
          "additionalProperties" => true,
          "properties" => {
            "file_path" => { "type" => "string" },
            "destination_url" => { "type" => "string" },
          },
        },
        "output_schema" => {
          "type" => "object",
          "required" => [],
          "additionalProperties" => true,
          "properties" => {},
        },
      }
    when "video.convert"
      {
        "input_schema" => {
          "type" => "object",
          "required" => %w[mode input_dir output_dir overwrite],
          "additionalProperties" => true,
          "properties" => {
            "mode" => { "type" => "string", "enum" => %w[all selected] },
            "files" => { "type" => "array", "items" => { "type" => "string" } },
            "input_dir" => { "type" => "string" },
            "output_dir" => { "type" => "string" },
            "overwrite" => { "type" => "boolean" },
          },
        },
        "output_schema" => {
          "type" => "object",
          "required" => %w[converted_count failed_count output_files results],
          "additionalProperties" => true,
          "properties" => {
            "converted_count" => { "type" => "integer" },
            "failed_count" => { "type" => "integer" },
            "output_files" => { "type" => "array", "items" => { "type" => "string" } },
            "results" => {
              "type" => "array",
              "items" => {
                "type" => "object",
                "required" => %w[input_file status],
                "additionalProperties" => true,
                "properties" => {
                  "input_file" => { "type" => "string" },
                  "output_file" => { "type" => "string" },
                  "status" => { "type" => "string", "enum" => %w[ok error] },
                  "error" => { "type" => "string" },
                },
              },
            },
          },
        },
      }
    else
      {
        "input_schema" => { "type" => "object", "required" => [], "additionalProperties" => true, "properties" => {} },
        "output_schema" => { "type" => "object", "required" => [], "additionalProperties" => true, "properties" => {} },
      }
    end
  end

  def default_step_metadata(capability:, planner_source:)
    risk_level =
      case capability
      when "drive.upload", "yandex.disk.upload" then "medium"
      else "low"
      end

    {
      "risk_level" => risk_level,
      "idempotency_required" => false,
      "planner_source" => planner_source,
      "approval_required" => false,
    }
  end

  def normalize_coverage_fields!(step, planner_source:)
    if planner_source == "rule"
      step["coverage_confidence"] = 1.0
      step["coverage_rationale"] = "rule_matched"
      return
    end

    confidence = step["coverage_confidence"]
    normalized_confidence =
      if confidence.is_a?(Numeric)
        c = confidence.to_f
        if c.negative?
          0.0
        elsif c > 1.0
          1.0
        else
          c
        end
      else
        0.0
      end

    step["coverage_confidence"] = normalized_confidence
    rationale = step["coverage_rationale"]
    step["coverage_rationale"] = rationale.to_s.strip.empty? ? "llm_unspecified" : rationale.to_s
  end

  def validate_llm_capability_contract!(step, index:)
    contract = step["capability_contract"]
    unless contract.is_a?(Hash)
      raise ValidationError, "steps[#{index}].capability_contract is required for LLM plans"
    end

    input_schema = contract["input_schema"]
    output_schema = contract["output_schema"]
    unless input_schema.is_a?(Hash)
      raise ValidationError, "steps[#{index}].capability_contract.input_schema must be an object/map"
    end
    return if output_schema.is_a?(Hash)

    raise ValidationError, "steps[#{index}].capability_contract.output_schema must be an object/map"
  end

  def normalize_step!(step, index:, planner_source:)
    raise ValidationError, "step at index #{index} must be an object/map" unless step.is_a?(Hash)
    step["step_id"] = "step-#{index + 1}" if !step["step_id"].is_a?(String) || step["step_id"].strip.empty?
    cap = step["capability"]
    nonempty_string!(cap, label: "steps[#{index}].capability")
    step["tool"] = nil unless step.key?("tool")
    step["inputs"] = {} unless step["inputs"].is_a?(Hash)
    if planner_source == "llm"
      validate_llm_capability_contract!(step, index: index)
    else
      step["capability_contract"] = capability_contract_for(cap) unless step["capability_contract"].is_a?(Hash)
    end

    default_step_metadata(capability: cap, planner_source: planner_source).each do |k, v|
      step[k] = v unless step.key?(k)
    end

    normalize_coverage_fields!(step, planner_source: planner_source)
    normalize_step_input_references!(step)
  end

  def normalize_step_input_references!(step)
    inputs = step["inputs"]
    return unless inputs.is_a?(Hash)

    inputs.each do |_key, value|
      next unless value.is_a?(Hash) && value["from"].is_a?(String)

      from = value["from"]
      value["from"] = normalize_from_reference(from)
    end
  end

  def normalize_from_reference(from)
    # LLMs sometimes emit legacy references: step-1.output.file_path
    # Normalize to the canonical resolver format: steps.step-1.outputs.file_path
    if (m = from.match(/\A([a-zA-Z0-9_-]+)\.output\.([a-zA-Z0-9_-]+)\z/))
      return "steps.#{m[1]}.outputs.#{m[2]}"
    end
    if (m = from.match(/\A([a-zA-Z0-9_-]+)\.outputs\.([a-zA-Z0-9_-]+)\z/))
      return "steps.#{m[1]}.outputs.#{m[2]}"
    end

    from
  end

  def normalize_llm_plan!(raw_plan, request:, now:, planner_source:)
    raise ValidationError, "LLM planner output must be an object/map" unless raw_plan.is_a?(Hash)

    steps = raw_plan["steps"]
    raise ValidationError, "LLM planner output must include steps array" unless steps.is_a?(Array) && !steps.empty?

    normalized_steps = steps.each_with_index.map do |step, idx|
      s = stringify_keys(step)
      normalize_step!(s, index: idx, planner_source: planner_source)
      s
    end

    created_at = now.utc.iso8601
    request_id = request.fetch("request_id")
    {
      "plan_id" => "plan-#{request_id}-#{created_at}",
      "request_id" => request_id,
      "user_goal" => request.fetch("user_goal"),
      "created_at" => created_at,
      "status" => "planned",
      "steps" => normalized_steps,
    }
  end

  def build_request_from_text(text, now: Time.now.utc)
    nonempty_string!(text, label: "text")
    inputs = {}

    youtube_url = extract_youtube_url(text)
    inputs["youtube_url"] = youtube_url if youtube_url
    extracted_target_quality = extract_target_quality(text)
    if youtube_url
      inputs["target_quality"] = extracted_target_quality || DEFAULT_TARGET_QUALITY
    elsif !extracted_target_quality.nil?
      inputs["target_quality"] = extracted_target_quality
    end

    drive_folder_id = extract_drive_folder_id(text)
    inputs["drive_folder_id"] = drive_folder_id if drive_folder_id

    yandex_disk_url = extract_yandex_disk_url(text)
    inputs["yandex_disk_url"] = yandex_disk_url if yandex_disk_url

    if video_convert_intent?(text)
      files = extract_webm_file_names(text)
      inputs["video_convert_mode"] = files.empty? ? "all" : "selected"
      inputs["video_convert_files"] = files unless files.empty?
      inputs["video_convert_input_dir"] = "input_data"
      inputs["video_convert_output_dir"] = "output_data"
      inputs["video_convert_overwrite"] = true
    end

    {
      "request_id" => generate_request_id(now),
      "user_goal" => text.strip,
      "inputs" => inputs,
    }
  end

  def build_plan_from_text(text, now: Time.now.utc)
    build_plan(build_request_from_text(text, now: now), now: now)
  end

  def build_plan(request_hash, now: Time.now.utc)
    request = stringify_keys(request_hash)
    raise ValidationError, "request must be a YAML mapping/object" unless request.is_a?(Hash)

    user_goal = request["user_goal"]
    nonempty_string!(user_goal, label: "user_goal")

    inputs = request["inputs"]
    raise ValidationError, "inputs must be an object/map" unless inputs.is_a?(Hash)

    request_id = request["request_id"]
    request_id = generate_request_id(now) unless request_id.is_a?(String) && !request_id.strip.empty?

    created_at = now.utc.iso8601
    plan_id = "plan-#{request_id}-#{created_at}"

    steps = []

    wants_youtube = inputs.key?("youtube_url") || youtube_url?(inputs["url"])
    wants_drive = inputs.key?("drive_folder_id") || inputs.key?("folder_id")
    wants_yandex_disk = inputs.key?("yandex_disk_url")
    wants_video_convert = inputs.key?("video_convert_mode") || inputs.key?("video_convert_files")

    if wants_video_convert && (wants_youtube || wants_drive || wants_yandex_disk)
      raise ValidationError, "No route rules matched: mixed video.convert and upload/download intents are not supported in one rule-based plan."
    end

    if wants_video_convert
      mode = inputs["video_convert_mode"].to_s.strip.downcase
      mode = "selected" if mode.empty? && inputs["video_convert_files"].is_a?(Array)
      mode = "all" if mode.empty?
      unless %w[all selected].include?(mode)
        raise ValidationError, "inputs.video_convert_mode must be one of: all, selected"
      end

      files = Array(inputs["video_convert_files"]).map { |v| File.basename(v.to_s.strip) }.reject(&:empty?).uniq
      if mode == "selected"
        raise ValidationError, "inputs.video_convert_files must include at least one .webm file for mode=selected" if files.empty?
        invalid = files.reject { |name| name.downcase.end_with?(".webm") }
        raise ValidationError, "inputs.video_convert_files must contain only .webm file names" unless invalid.empty?
      end

      input_dir = inputs["video_convert_input_dir"].to_s.strip
      input_dir = "input_data" if input_dir.empty?
      output_dir = inputs["video_convert_output_dir"].to_s.strip
      output_dir = "output_data" if output_dir.empty?
      overwrite = inputs.key?("video_convert_overwrite") ? inputs["video_convert_overwrite"] == true : true

      steps << {
        "step_id" => "step-1",
        "capability" => "video.convert",
        "tool" => nil,
        "coverage_confidence" => 1.0,
        "coverage_rationale" => "rule_matched",
        "inputs" => {
          "mode" => mode,
          "files" => files,
          "input_dir" => input_dir,
          "output_dir" => output_dir,
          "overwrite" => overwrite,
        },
        "capability_contract" => capability_contract_for("video.convert"),
        "risk_level" => "low",
        "idempotency_required" => false,
        "planner_source" => "rule",
        "approval_required" => false,
      }
    end

    if wants_youtube
      source_key = inputs.key?("youtube_url") ? "youtube_url" : "url"
      url_value = inputs[source_key]
      nonempty_string!(url_value, label: "inputs.#{source_key}")
      raise ValidationError, "inputs.#{source_key} must be a YouTube URL" unless youtube_url?(url_value)
      target_quality = resolved_target_quality(inputs)

      steps << {
        "step_id" => "step-1",
        "capability" => "youtube.download",
        "tool" => nil,
        "coverage_confidence" => 1.0,
        "coverage_rationale" => "rule_matched",
        "inputs" => {
          "url" => { "from" => "request.inputs.#{source_key}" },
          "target_quality" => target_quality,
        },
        "capability_contract" => capability_contract_for("youtube.download"),
        "risk_level" => "low",
        "idempotency_required" => false,
        "planner_source" => "rule",
        "approval_required" => false,
      }
    end

    if wants_drive
      folder_source_key = inputs.key?("drive_folder_id") ? "drive_folder_id" : "folder_id"
      folder_value = inputs[folder_source_key]
      nonempty_string!(folder_value, label: "inputs.#{folder_source_key}")

      if wants_youtube
        file_path_from = "steps.step-1.outputs.file_path"
      else
        file_path_value = inputs["file_path"]
        nonempty_string!(file_path_value, label: "inputs.file_path")
        file_path_from = "request.inputs.file_path"
      end

      step_id = wants_youtube ? "step-2" : "step-1"
      steps << {
        "step_id" => step_id,
        "capability" => "drive.upload",
        "tool" => nil,
        "coverage_confidence" => 1.0,
        "coverage_rationale" => "rule_matched",
        "inputs" => {
          "file_path" => { "from" => file_path_from },
          "folder_id" => { "from" => "request.inputs.#{folder_source_key}" },
        },
        "capability_contract" => capability_contract_for("drive.upload"),
        "risk_level" => "medium",
        "idempotency_required" => false,
        "planner_source" => "rule",
        "approval_required" => false,
      }
    end

    if wants_yandex_disk
      yandex_disk_url = inputs["yandex_disk_url"]
      nonempty_string!(yandex_disk_url, label: "inputs.yandex_disk_url")

      if wants_youtube
        file_path_from = "steps.step-1.outputs.file_path"
      else
        file_path_value = inputs["file_path"]
        nonempty_string!(file_path_value, label: "inputs.file_path")
        file_path_from = "request.inputs.file_path"
      end

      step_id = "step-#{steps.length + 1}"
      steps << {
        "step_id" => step_id,
        "capability" => "yandex.disk.upload",
        "tool" => nil,
        "coverage_confidence" => 1.0,
        "coverage_rationale" => "rule_matched",
        "inputs" => {
          "file_path" => { "from" => file_path_from },
          "destination_url" => { "from" => "request.inputs.yandex_disk_url" },
        },
        "capability_contract" => capability_contract_for("yandex.disk.upload"),
        "risk_level" => "medium",
        "idempotency_required" => false,
        "planner_source" => "rule",
        "approval_required" => false,
      }
    end

    if steps.empty?
      raise ValidationError,
            "No route rules matched: provide inputs.youtube_url (or inputs.url with YouTube domain), inputs.drive_folder_id, inputs.yandex_disk_url, or video.convert inputs. " \
            "For free-form goals, use agent LLM fallback with AGENT_API_KEY or ZAI_API_KEY."
    end

    {
      "plan_id" => plan_id,
      "request_id" => request_id,
      "user_goal" => user_goal,
      "created_at" => created_at,
      "status" => "planned",
      "steps" => steps,
    }
  end

  def build_hybrid_plan_from_text(text, llm_client: nil, model: nil, now: Time.now.utc)
    request = build_request_from_text(text, now: now)

    begin
      return [request, build_plan(request, now: now)]
    rescue ValidationError => e
      raise e if llm_client.nil?
      llm_payload = llm_client.plan_workflow(text: text, request: request, model: model)
      plan = normalize_llm_plan!(llm_payload, request: request, now: now, planner_source: "llm")
      plan["planner"] = {
        "mode" => "hybrid",
        "fallback_reason" => e.message,
      }
      return [request, plan]
    end
  end

  def build_plan_from_file(request_path, now: Time.now.utc)
    build_plan(safe_load_yaml(request_path), now: now)
  end

  class CLI
    def self.run(argv)
      command = argv.shift
      case command
      when "route"
        request_path = nil
        output_path = nil
        pretty = false

        OptionParser.new do |o|
          o.on("--request PATH", "Path to request YAML/JSON") { |v| request_path = v }
          o.on("--output PATH", "Write plan JSON to PATH (default: stdout)") { |v| output_path = v }
          o.on("--pretty", "Pretty-print JSON") { pretty = true }
        end.parse!(argv)

        raise ValidationError, "Missing --request PATH" if request_path.nil? || request_path.strip.empty?
        plan = RequestRouter.build_plan_from_file(request_path)
        json = pretty ? JSON.pretty_generate(plan) : JSON.generate(plan)
        json << "\n"

        if output_path
          File.write(output_path, json)
        else
          print json
        end
        return 0
      when "route-text"
        text = nil
        text_file = nil
        output_path = nil
        pretty = false

        OptionParser.new do |o|
          o.on("--text TEXT", "Raw user request text") { |v| text = v }
          o.on("--text-file PATH", "Path to a file containing raw user request text") { |v| text_file = v }
          o.on("--output PATH", "Write plan JSON to PATH (default: stdout)") { |v| output_path = v }
          o.on("--pretty", "Pretty-print JSON") { pretty = true }
        end.parse!(argv)

        if text.nil? || text.strip.empty?
          if text_file && !text_file.strip.empty?
            text = File.read(text_file)
          end
        end
        raise ValidationError, "Missing --text TEXT (or --text-file PATH)" if text.nil? || text.strip.empty?

        plan = RequestRouter.build_plan_from_text(text)
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
            request_router.rb route --request PATH [--output PATH] [--pretty]
            request_router.rb route-text --text TEXT [--output PATH] [--pretty]
        USAGE
        return 1
      end
    rescue ValidationError => e
      warn(e.message)
      return 1
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  exit(RequestRouter::CLI.run(ARGV))
end
