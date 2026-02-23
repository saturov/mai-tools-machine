#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "fileutils"
require "optparse"
require "open3"
require "pathname"
require "shellwords"
require "time"
require "timeout"
require "yaml"

require_relative "../../scripts/tool_registry"

module WorkflowExecutor
  class ValidationError < StandardError
    attr_reader :code

    def initialize(message, code: "validation")
      super(message)
      @code = code
    end
  end

  class ExecutionError < StandardError
    attr_reader :code

    def initialize(message, code: "tool_failed")
      super(message)
      @code = code
    end
  end

  class ExecutionFailed < ExecutionError
    attr_reader :executed_steps, :failed_step_id, :failed_tool_id, :failed_capability, :remaining_steps

    def initialize(message, code: "tool_failed", executed_steps:, failed_step_id:, failed_tool_id:, failed_capability:, remaining_steps:)
      super(message, code: code)
      @executed_steps = executed_steps
      @failed_step_id = failed_step_id
      @failed_tool_id = failed_tool_id
      @failed_capability = failed_capability
      @remaining_steps = remaining_steps
    end
  end

  module_function

  def emit_event(handler, payload)
    return unless handler
    handler.call(payload)
  rescue StandardError
    nil
  end

  def repo_root
    @repo_root ||= Pathname.new(__dir__).join("..", "..").expand_path
  end

  def default_registry_path
    File.join(repo_root.to_s, "state", "registry-cache.json")
  end

  def default_runs_dir
    File.join(repo_root.to_s, "state", "runs")
  end

  def safe_load_yaml(path)
    contents = File.read(path)
    begin
      YAML.safe_load(contents, permitted_classes: [], permitted_symbols: [], aliases: false)
    rescue ArgumentError
      YAML.safe_load(contents)
    end
  rescue Errno::ENOENT
    raise ValidationError, "File not found: #{path}"
  rescue Psych::Exception => e
    raise ValidationError, "YAML parse error in #{path}: #{e.message}"
  end

  def load_json(path)
    JSON.parse(File.read(path))
  rescue Errno::ENOENT
    raise ValidationError, "File not found: #{path}"
  rescue JSON::ParserError => e
    raise ValidationError, "Invalid JSON in #{path}: #{e.message}"
  end

  def load_request(path)
    ext = File.extname(path).downcase
    obj =
      case ext
      when ".json"
        load_json(path)
      else
        safe_load_yaml(path)
      end
    raise ValidationError, "request must be an object/map" unless obj.is_a?(Hash)
    obj.transform_keys(&:to_s)
  end

  def load_plan(path)
    plan = load_json(path)
    raise ValidationError, "plan must be an object/map" unless plan.is_a?(Hash)
    plan
  end

  def generate_run_id(now = Time.now.utc)
    "run-#{now.strftime("%Y%m%d%H%M%S")}-#{rand(1000..9999)}"
  end

  def tool_dir_for(tool)
    source_path = tool["source_path"]
    raise ValidationError, "tool is missing source_path" unless source_path.is_a?(String) && !source_path.strip.empty?
    Pathname.new(repo_root).join(source_path).dirname.to_s
  end

  def resolve_from(from, request_inputs:, step_outputs:, allow_unresolved:)
    unless from.is_a?(String) && !from.strip.empty?
      raise ValidationError, "inputs.*.from must be a non-empty string"
    end

    if from.start_with?("request.inputs.")
      key = from.delete_prefix("request.inputs.")
      value = request_inputs[key]
      raise ValidationError, "Missing request input #{key.inspect}" if (value.nil? || (value.is_a?(String) && value.strip.empty?)) && !allow_unresolved
      return value.nil? ? from : value
    end

    if from.start_with?("steps.")
      parts = from.split(".")
      # steps.<step_id>.outputs.<key>
      unless parts.length == 4 && parts[2] == "outputs"
        raise ValidationError, "Unsupported from reference: #{from.inspect}"
      end
      step_id = parts[1]
      key = parts[3]
      value = step_outputs.dig(step_id, key)
      raise ValidationError, "Missing output #{key.inspect} from step #{step_id.inspect}" if (value.nil? || (value.is_a?(String) && value.strip.empty?)) && !allow_unresolved
      return value.nil? ? from : value
    end

    raise ValidationError, "Unsupported from reference: #{from.inspect}"
  end

  def resolve_step_inputs(step, request_inputs:, step_outputs:, allow_unresolved:)
    raw = step["inputs"]
    raise ValidationError, "step.inputs must be an object/map" unless raw.is_a?(Hash)

    resolved = {}
    raw.each do |k, v|
      key = k.to_s
      if v.is_a?(Hash) && v.key?("from")
        resolved[key] = resolve_from(v["from"], request_inputs: request_inputs, step_outputs: step_outputs, allow_unresolved: allow_unresolved)
      else
        resolved[key] = v
      end
    end
    resolved
  end

  def base_argv_for(tool)
    entrypoint = tool["entrypoint"]
    raise ValidationError, "tool.entrypoint must be an object/map" unless entrypoint.is_a?(Hash)
    raise ValidationError, "Only entrypoint.type=shell is supported" unless entrypoint["type"] == "shell"
    command = entrypoint["command"]
    raise ValidationError, "tool.entrypoint.command must be a non-empty string" unless command.is_a?(String) && !command.strip.empty?
    Shellwords.split(command)
  end

  def argv_for_tool(tool, inputs)
    name = tool["name"].to_s
    base = base_argv_for(tool)

    case name
    when "youtube-downloader"
      url = inputs["url"]
      raise ValidationError, "youtube.download requires input url" unless url.is_a?(String) && !url.strip.empty?
      argv = base + [url]
      if (cookies = inputs["cookies_from_browser"]).is_a?(String) && !cookies.strip.empty?
        argv += ["--cookies-from-browser", cookies]
      end
      if (target_quality = inputs["target_quality"]).is_a?(Integer) && target_quality.positive?
        argv += ["--target-quality", target_quality.to_s]
      end
      if (min_height = inputs["min_height"]).is_a?(Integer) && min_height.positive?
        argv += ["--min-height", min_height.to_s]
      end
      if (quality_policy = inputs["quality_policy"]).is_a?(String) && !quality_policy.strip.empty?
        argv += ["--quality-policy", quality_policy]
      end
      clients = Array(inputs["player_clients"]).map { |v| v.to_s.strip }.reject(&:empty?)
      clients.each do |client|
        argv += ["--player-client", client]
      end
      argv
    when "drive-uploader"
      file_path = inputs["file_path"]
      folder_id = inputs["folder_id"]
      raise ValidationError, "drive.upload requires input file_path" unless file_path.is_a?(String) && !file_path.strip.empty?
      raise ValidationError, "drive.upload requires input folder_id" unless folder_id.is_a?(String) && !folder_id.strip.empty?

      argv = base + ["--file-path", file_path, "--folder-id", folder_id]

      if (v = inputs["name"]).is_a?(String) && !v.strip.empty?
        argv += ["--name", v]
      end
      if (v = inputs["mime_type"]).is_a?(String) && !v.strip.empty?
        argv += ["--mime-type", v]
      end
      if (v = inputs["auth_mode"]).is_a?(String) && !v.strip.empty?
        argv += ["--auth-mode", v]
      end
      if (v = inputs["credentials_path"]).is_a?(String) && !v.strip.empty?
        argv += ["--credentials-path", v]
      end
      if (v = inputs["token_path"]).is_a?(String) && !v.strip.empty?
        argv += ["--token-path", v]
      end
      if inputs.key?("resumable") && inputs["resumable"] == false
        argv += ["--no-resumable"]
      end
      if (v = inputs["timeout_seconds"]).is_a?(Integer)
        argv += ["--timeout-seconds", v.to_s]
      end
      if (v = inputs["retries"]).is_a?(Integer)
        argv += ["--retries", v.to_s]
      end

      argv
    when "webm-to-mp4-converter"
      mode = inputs["mode"].to_s.strip
      input_dir = inputs["input_dir"]
      output_dir = inputs["output_dir"]
      raise ValidationError, "video.convert requires input mode (all|selected)" unless %w[all selected].include?(mode)
      raise ValidationError, "video.convert requires input input_dir" unless input_dir.is_a?(String) && !input_dir.strip.empty?
      raise ValidationError, "video.convert requires input output_dir" unless output_dir.is_a?(String) && !output_dir.strip.empty?

      argv = base + ["--mode", mode, "--input-dir", input_dir, "--output-dir", output_dir]
      if mode == "selected"
        files = Array(inputs["files"]).map { |v| v.to_s.strip }.reject(&:empty?)
        raise ValidationError, "video.convert requires non-empty files list for mode=selected" if files.empty?
        files.each { |file| argv += ["--file", file] }
      end
      if inputs.key?("overwrite") && inputs["overwrite"] == false
        argv << "--no-overwrite"
      end
      if (jobs = inputs["jobs"]).is_a?(Integer) && jobs.positive?
        argv += ["--jobs", jobs.to_s]
      end
      argv
    else
      raise ValidationError, "Unsupported tool runner for tool #{name.inspect} (id=#{tool["id"].inspect})"
    end
  end

  def parse_tool_output(tool, stdout)
    name = tool["name"].to_s
    s = stdout.to_s.strip

    begin
      parsed = JSON.parse(s)
      return parsed if parsed.is_a?(Hash)
    rescue JSON::ParserError
      # fall through
    end

    case name
    when "youtube-downloader"
      line = s.lines.reverse.find { |ln| ln.strip.start_with?("Saved:") }
      raise ExecutionError, "youtube-downloader: could not parse output (expected JSON or 'Saved: ...')" if line.nil?
      path = line.split("Saved:", 2)[1].to_s.strip
      raise ExecutionError, "youtube-downloader: missing saved file path in output" if path.empty?
      { "file_path" => path }
    else
      raise ExecutionError, "Tool #{name.inspect} did not return JSON output"
    end
  end

  def execute_tool_command(argv, chdir:, timeout_seconds:, stream_stderr: false, stderr_io: $stderr)
    stdout_buf = +""
    stderr_buf = +""
    status = nil
    wait_thr = nil

    Timeout.timeout(timeout_seconds) do
      Open3.popen3(*argv, chdir: chdir) do |stdin, stdout, stderr, wt|
        wait_thr = wt
        stdin.close

        stdout_thread = Thread.new do
          stdout.each_line { |line| stdout_buf << line }
        rescue IOError
          nil
        end

        stderr_thread = Thread.new do
          stderr.each_line do |line|
            stderr_buf << line
            next unless stream_stderr && stderr_io
            stderr_io.print(line)
            stderr_io.flush if stderr_io.respond_to?(:flush)
          end
        rescue IOError
          nil
        end

        stdout_thread.join
        stderr_thread.join
        status = wt.value
      end
    end

    [stdout_buf, stderr_buf, status]
  rescue Timeout::Error
    if wait_thr&.alive?
      begin
        Process.kill("TERM", wait_thr.pid)
      rescue StandardError
        nil
      end
      sleep(0.2)
      begin
        Process.kill("KILL", wait_thr.pid) if wait_thr.alive?
      rescue StandardError
        nil
      end
    end
    raise ExecutionError.new("Step timed out after #{timeout_seconds}s", code: "tool_timeout")
  end

  def execute_step!(step, tool, request_inputs:, step_outputs:, dry_run:, max_retries: 0, timeout_seconds: 300, event_handler: nil, step_index: nil, total_steps: nil, stream_tool_stderr: true)
    resolved_inputs = resolve_step_inputs(step, request_inputs: request_inputs, step_outputs: step_outputs, allow_unresolved: dry_run)
    argv = argv_for_tool(tool, resolved_inputs)
    tool_dir = tool_dir_for(tool)

    if dry_run
      emit_event(
        event_handler,
        {
          "type" => "step_attempt_started",
          "step_id" => step["step_id"],
          "capability" => step["capability"],
          "step_index" => step_index,
          "total_steps" => total_steps,
          "attempt" => 1,
          "max_attempts" => 1,
        }
      )
      result = {
        "step_id" => step["step_id"],
        "capability" => step["capability"],
        "tool" => tool["id"],
        "tool_dir" => tool_dir,
        "argv" => argv,
        "inputs" => resolved_inputs,
        "outputs" => {},
        "status" => "dry-run",
      }
      emit_event(
        event_handler,
        {
          "type" => "step_succeeded",
          "step_id" => step["step_id"],
          "capability" => step["capability"],
          "step_index" => step_index,
          "total_steps" => total_steps,
          "attempt" => 1,
          "max_attempts" => 1,
          "elapsed_seconds" => 0,
        }
      )
      return result
    end

    attempts = 0
    begin
      attempts += 1
      emit_event(
        event_handler,
        {
          "type" => "step_attempt_started",
          "step_id" => step["step_id"],
          "capability" => step["capability"],
          "step_index" => step_index,
          "total_steps" => total_steps,
          "attempt" => attempts,
          "max_attempts" => max_retries.to_i + 1,
        }
      )
      attempt_started_at = Time.now
      stdout, stderr, status = execute_tool_command(
        argv,
        chdir: tool_dir,
        timeout_seconds: timeout_seconds,
        stream_stderr: stream_tool_stderr
      )
      unless status.success?
        raise ExecutionError.new("Step #{step["step_id"]} failed (#{tool["name"]}): exit=#{status.exitstatus}\n#{stderr}".strip, code: "tool_failed")
      end

      outputs = parse_tool_output(tool, stdout)
      raise ExecutionError.new("Tool output must be an object/map", code: "tool_invalid_output") unless outputs.is_a?(Hash)

      result = {
        "step_id" => step["step_id"],
        "capability" => step["capability"],
        "tool" => tool["id"],
        "tool_dir" => tool_dir,
        "argv" => argv,
        "inputs" => resolved_inputs,
        "outputs" => outputs,
        "status" => "ok",
        "stdout" => stdout,
        "stderr" => stderr,
        "exit_code" => status.exitstatus,
        "attempts" => attempts,
      }
      quality_payload = {}
      if step["capability"] == "youtube.download"
        target_quality = outputs["target_quality"]
        actual_quality = outputs["actual_quality"]
        fallback = outputs["fallback"]
        quality_payload["target_quality"] = target_quality if target_quality.is_a?(Integer)
        if outputs.key?("actual_quality")
          quality_payload["actual_quality"] =
            actual_quality.is_a?(Integer) ? actual_quality : "unknown"
        end
        quality_payload["fallback"] = fallback if fallback == true || fallback == false
      end
      emit_event(
        event_handler,
        {
          "type" => "step_succeeded",
          "step_id" => step["step_id"],
          "capability" => step["capability"],
          "step_index" => step_index,
          "total_steps" => total_steps,
          "attempt" => attempts,
          "max_attempts" => max_retries.to_i + 1,
          "elapsed_seconds" => Time.now - attempt_started_at,
        }.merge(quality_payload)
      )
      return result
    rescue ExecutionError => e
      if attempts <= max_retries
        emit_event(
          event_handler,
          {
            "type" => "step_retry",
            "step_id" => step["step_id"],
            "capability" => step["capability"],
            "step_index" => step_index,
            "total_steps" => total_steps,
            "attempt" => attempts,
            "max_attempts" => max_retries.to_i + 1,
            "error_code" => e.code,
            "message" => e.message,
          }
        )
        retry
      end
      emit_event(
        event_handler,
        {
          "type" => "step_failed",
          "step_id" => step["step_id"],
          "capability" => step["capability"],
          "step_index" => step_index,
          "total_steps" => total_steps,
          "attempt" => attempts,
          "max_attempts" => max_retries.to_i + 1,
          "error_code" => e.code,
          "message" => e.message,
        }
      )
      raise e
    end
  end

  def run_plan!(plan, request, registry_path: default_registry_path, runs_dir: default_runs_dir, dry_run: false, max_tool_retries: 0, timeout_seconds: 300, now: Time.now.utc, event_handler: nil, stream_tool_stderr: true)
    raise ValidationError.new("plan.status must be 'complete' to execute", code: "validation") unless dry_run || plan["status"] == "complete"

    request_inputs = (request["inputs"].is_a?(Hash) ? request["inputs"] : {}).transform_keys(&:to_s)
    steps = plan["steps"]
    raise ValidationError, "plan.steps must be an array" unless steps.is_a?(Array)

    registry = ToolRegistry.load_registry!(registry_path)
    by_id = registry.dig("index", "by_id") || {}

    run_id = generate_run_id(now)
    step_outputs = {}
    executed_steps = []

    steps.each_with_index do |step, idx|
      raise ValidationError, "each step must be an object/map" unless step.is_a?(Hash)
      step_id = step["step_id"].to_s
      tool_id = step["tool"]
      raise ValidationError, "step #{step_id.inspect} is missing tool (run gap-detector first)" unless tool_id.is_a?(String) && !tool_id.strip.empty?
      tool = by_id[tool_id]
      raise ValidationError, "registry is missing tool definition for #{tool_id.inspect}" unless tool.is_a?(Hash)

      begin
        result = execute_step!(
          step,
          tool,
          request_inputs: request_inputs,
          step_outputs: step_outputs,
          dry_run: dry_run,
          max_retries: max_tool_retries,
          timeout_seconds: timeout_seconds,
          event_handler: event_handler,
          step_index: idx + 1,
          total_steps: steps.length,
          stream_tool_stderr: stream_tool_stderr
        )
      rescue ExecutionError => e
        remaining_steps = steps[idx..] || []
        raise ExecutionFailed.new(
          e.message,
          code: e.code,
          executed_steps: executed_steps,
          failed_step_id: step_id,
          failed_tool_id: tool_id,
          failed_capability: step["capability"],
          remaining_steps: remaining_steps
        )
      end
      executed_steps << result
      step_outputs[step_id] = result["outputs"] if result["outputs"].is_a?(Hash) && !result["outputs"].empty?
    end

    run = {
      "run_id" => run_id,
      "started_at" => now.utc.iso8601,
      "dry_run" => dry_run,
      "plan_id" => plan["plan_id"],
      "request_id" => plan["request_id"],
      "steps" => executed_steps,
      "final_outputs" => step_outputs,
      "status" => dry_run ? "dry-run" : "ok",
    }

    FileUtils.mkdir_p(runs_dir)
    File.write(File.join(runs_dir, "#{run_id}.json"), JSON.pretty_generate(run) + "\n")
    run
  end

  class CLI
    def self.run(argv)
      command = argv.shift
      case command
      when "run"
        plan_path = nil
        request_path = nil
        registry_path = WorkflowExecutor.default_registry_path
        runs_dir = WorkflowExecutor.default_runs_dir
        output_path = nil
        pretty = false
        dry_run = false

        OptionParser.new do |o|
          o.on("--plan PATH", "Path to workflow plan JSON") { |v| plan_path = v }
          o.on("--request PATH", "Path to request YAML/JSON") { |v| request_path = v }
          o.on("--registry PATH", "Path to registry cache JSON") { |v| registry_path = v }
          o.on("--runs-dir PATH", "Directory to write run artifacts") { |v| runs_dir = v }
          o.on("--dry-run", "Do not execute steps; only print commands/placeholders") { dry_run = true }
          o.on("--output PATH", "Write result JSON to PATH (default: stdout)") { |v| output_path = v }
          o.on("--pretty", "Pretty-print JSON") { pretty = true }
        end.parse!(argv)

        raise ValidationError, "Missing --plan PATH" if plan_path.nil? || plan_path.strip.empty?
        raise ValidationError, "Missing --request PATH" if request_path.nil? || request_path.strip.empty?

        plan = WorkflowExecutor.load_plan(plan_path)
        request = WorkflowExecutor.load_request(request_path)
        run = WorkflowExecutor.run_plan!(plan, request, registry_path: registry_path, runs_dir: runs_dir, dry_run: dry_run)

        json = pretty ? JSON.pretty_generate(run) : JSON.generate(run)
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
            workflow_executor.rb run --plan PATH --request PATH [--registry PATH] [--runs-dir PATH] [--dry-run] [--output PATH] [--pretty]
        USAGE
        return 1
      end
    rescue ValidationError, ExecutionError, ToolRegistry::ValidationError => e
      warn(e.message)
      return 1
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  exit(WorkflowExecutor::CLI.run(ARGV))
end
