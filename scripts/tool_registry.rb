#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "fileutils"
require "optparse"
require "pathname"
require "time"
require "yaml"

module ToolRegistry
  class ValidationError < StandardError; end
  class CapabilityNotFound < ValidationError; end

  module JSONSchemaSubset
    module_function

    def validate(schema, instance, path: "$")
      errors = []
      validate_into(errors, schema, instance, path)
      errors
    end

    def validate_into(errors, schema, instance, path)
      return if schema.nil?
      unless schema.is_a?(Hash)
        errors << "#{path}: schema must be an object"
        return
      end

      schema_type = schema["type"]
      if schema_type
        unless type_ok?(schema_type, instance)
          errors << "#{path}: expected type #{schema_type}, got #{ruby_type(instance)}"
          return
        end
      end

      if schema.key?("enum")
        enum = schema["enum"]
        unless enum.is_a?(Array)
          errors << "#{path}: enum must be an array"
        else
          errors << "#{path}: value must be one of #{enum.inspect}" unless enum.include?(instance)
        end
      end

      if schema.key?("pattern")
        pattern = schema["pattern"]
        if pattern.is_a?(String)
          if instance.is_a?(String)
            begin
              re = Regexp.new(pattern)
              errors << "#{path}: string does not match pattern #{pattern.inspect}" unless re.match?(instance)
            rescue RegexpError => e
              errors << "#{path}: invalid regex pattern #{pattern.inspect} (#{e.message})"
            end
          else
            errors << "#{path}: pattern applies to strings, got #{ruby_type(instance)}"
          end
        else
          errors << "#{path}: pattern must be a string"
        end
      end

      if schema.key?("minLength")
        min_length = schema["minLength"]
        if instance.is_a?(String) && min_length.is_a?(Integer)
          errors << "#{path}: string length must be >= #{min_length}" if instance.length < min_length
        elsif !instance.is_a?(String)
          errors << "#{path}: minLength applies to strings, got #{ruby_type(instance)}"
        else
          errors << "#{path}: minLength must be an integer"
        end
      end

      case schema_type
      when "object"
        validate_object(errors, schema, instance, path)
      when "array"
        validate_array(errors, schema, instance, path)
      end
    end

    def validate_object(errors, schema, instance, path)
      unless instance.is_a?(Hash)
        errors << "#{path}: expected object, got #{ruby_type(instance)}"
        return
      end

      required = schema["required"]
      if required
        if required.is_a?(Array)
          required.each do |key|
            next unless key.is_a?(String)
            errors << "#{path}.#{key}: is required" unless instance.key?(key)
          end
        else
          errors << "#{path}: required must be an array"
        end
      end

      properties = schema["properties"]
      if properties
        if properties.is_a?(Hash)
          properties.each do |prop, prop_schema|
            next unless prop.is_a?(String)
            next unless instance.key?(prop)
            validate_into(errors, prop_schema, instance[prop], "#{path}.#{prop}")
          end
        else
          errors << "#{path}: properties must be an object"
        end
      end

      if schema.key?("additionalProperties")
        additional = schema["additionalProperties"]
        if additional == false
          allowed = properties.is_a?(Hash) ? properties.keys.grep(String) : []
          instance.each_key do |k|
            next unless k.is_a?(String)
            next if allowed.include?(k)
            errors << "#{path}.#{k}: additional property is not allowed"
          end
        elsif additional != true
          errors << "#{path}: additionalProperties must be boolean"
        end
      end
    end

    def validate_array(errors, schema, instance, path)
      unless instance.is_a?(Array)
        errors << "#{path}: expected array, got #{ruby_type(instance)}"
        return
      end

      if schema.key?("minItems")
        min_items = schema["minItems"]
        if min_items.is_a?(Integer)
          errors << "#{path}: array length must be >= #{min_items}" if instance.length < min_items
        else
          errors << "#{path}: minItems must be an integer"
        end
      end

      items_schema = schema["items"]
      if items_schema
        instance.each_with_index do |item, idx|
          validate_into(errors, items_schema, item, "#{path}[#{idx}]")
        end
      end
    end

    def type_ok?(schema_type, instance)
      case schema_type
      when "object" then instance.is_a?(Hash)
      when "array" then instance.is_a?(Array)
      when "string" then instance.is_a?(String)
      when "integer" then instance.is_a?(Integer)
      when "number" then instance.is_a?(Numeric)
      when "boolean" then instance == true || instance == false
      when "null" then instance.nil?
      else
        false
      end
    end

    def ruby_type(instance)
      return "null" if instance.nil?
      instance.class.name
    end
  end

  module SchemaSubset
    module_function

    def subset?(required_schema, available_schema)
      errors(required_schema, available_schema).empty?
    end

    def errors(required_schema, available_schema, path: "$")
      out = []
      compare(out, required_schema, available_schema, path)
      out
    end

    def compare(out, required_schema, available_schema, path)
      unless required_schema.is_a?(Hash)
        out << "#{path}: required schema must be an object"
        return
      end
      unless available_schema.is_a?(Hash)
        out << "#{path}: available schema must be an object"
        return
      end

      req_type = required_schema["type"]
      avail_type = available_schema["type"]
      if req_type && avail_type && req_type != avail_type
        out << "#{path}: type mismatch (required=#{req_type.inspect}, available=#{avail_type.inspect})"
        return
      end
      if req_type == "array" || avail_type == "array"
        compare_array(out, required_schema, available_schema, path)
        return
      end
      if req_type == "object" || avail_type == "object"
        compare_object(out, required_schema, available_schema, path)
        return
      end

      compare_enum(out, required_schema, available_schema, path)
    end

    def compare_object(out, required_schema, available_schema, path)
      req_required = normalize_string_array(required_schema["required"])
      avail_required = normalize_string_array(available_schema["required"])
      if (avail_required - req_required).any?
        missing = (avail_required - req_required).sort
        out << "#{path}: required schema must require #{missing.join(", ")}"
      end

      req_props = normalize_properties(required_schema["properties"])
      avail_props = normalize_properties(available_schema["properties"])

      req_props.each do |key, req_prop_schema|
        avail_prop_schema = avail_props[key]
        if avail_prop_schema.nil?
          out << "#{path}.#{key}: property missing in available schema"
          next
        end
        compare(out, req_prop_schema, avail_prop_schema, "#{path}.#{key}")
      end

    end

    def compare_array(out, required_schema, available_schema, path)
      req_items = required_schema["items"]
      avail_items = available_schema["items"]
      return if req_items.nil?
      if avail_items.nil?
        out << "#{path}: array items schema missing in available schema"
        return
      end
      compare(out, req_items, avail_items, "#{path}[]")
    end

    def compare_enum(out, required_schema, available_schema, path)
      req_enum = required_schema["enum"]
      avail_enum = available_schema["enum"]
      return if req_enum.nil?
      unless req_enum.is_a?(Array)
        out << "#{path}: required schema enum must be an array"
        return
      end
      unless avail_enum.is_a?(Array)
        out << "#{path}: available schema enum must be an array"
        return
      end
      missing = req_enum - avail_enum
      out << "#{path}: enum values are not covered #{missing.inspect}" unless missing.empty?
    end

    def normalize_string_array(value)
      return [] unless value.is_a?(Array)
      value.select { |v| v.is_a?(String) }
    end

    def normalize_properties(value)
      return {} unless value.is_a?(Hash)
      value.each_with_object({}) do |(k, v), out|
        out[k] = v if k.is_a?(String) && v.is_a?(Hash)
      end
    end
  end

  module_function

  def eprint(message)
    warn(message)
  end

  def repo_root
    @repo_root ||= Pathname.new(__dir__).join("..").expand_path
  end

  def tools_glob
    File.join(repo_root.to_s, "tools", "*", "tool.yaml")
  end

  def schema_path
    File.join(repo_root.to_s, "schemas", "tool-manifest.schema.json")
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
      value.each_with_object({}) do |(k, v), out|
        out[k.to_s] = stringify_keys(v)
      end
    when Array
      value.map { |v| stringify_keys(v) }
    else
      value
    end
  end

  def load_schema
    JSON.parse(File.read(schema_path))
  rescue JSON::ParserError => e
    raise ValidationError, "Schema JSON parse error in #{schema_path}: #{e.message}"
  end

  def semver_tuple(version)
    parts = version.to_s.split(".")
    return nil unless parts.length == 3 && parts.all? { |p| p.match?(/\A[0-9]+\z/) }
    parts.map(&:to_i)
  end

  def scan_manifests
    Dir.glob(tools_glob).sort
  end

  def validate_manifests!
    schema = load_schema
    paths = scan_manifests
    errors = []

    if paths.empty?
      errors << "No tool manifests found at tools/*/tool.yaml"
      return errors
    end

    names = {}

    paths.each do |path|
      raw = safe_load_yaml(path)
      manifest = stringify_keys(raw)

      unless manifest.is_a?(Hash)
        errors << "#{path}: manifest must be a YAML mapping/object"
        next
      end

      schema_errors = JSONSchemaSubset.validate(schema, manifest, path: "$")
      schema_errors.each do |err|
        errors << "#{path}: #{err}"
      end

      name = manifest["name"]
      if name.is_a?(String) && !name.empty?
        if names.key?(name)
          errors << "#{path}: duplicate tool name #{name.inspect} (already used in #{names[name]})"
        else
          names[name] = path
        end
      end

      caps = manifest["capabilities"]
      if caps.is_a?(Array)
        duplicates = caps.group_by { |c| c }.select { |_k, v| v.length > 1 }.keys
        unless duplicates.empty?
          errors << "#{path}: capabilities contain duplicates: #{duplicates.inspect}"
        end
      end

      if manifest.key?("version")
        v = semver_tuple(manifest["version"])
        errors << "#{path}: version must be x.y.z semver-like" if v.nil?
      end
    end

    errors
  end

  def normalize_manifest(manifest, source_path)
    tool = manifest.dup
    tool["id"] = "#{tool["name"]}@#{tool["version"]}"
    tool["source_path"] = source_path
    tool["idempotency"] ||= "unknown"
    tool["stability"] ||= "experimental"
    tool
  end

  def build_registry!(output_path)
    errors = validate_manifests!
    unless errors.empty?
      errors.each { |e| eprint(e) }
      raise ValidationError, "Manifest validation failed (#{errors.length} error(s))"
    end

    tools = []
    by_id = {}
    by_capability = Hash.new { |h, k| h[k] = [] }

    scan_manifests.each do |path|
      manifest = stringify_keys(safe_load_yaml(path))
      tool = normalize_manifest(manifest, relative_to_root(path))
      tools << tool
      by_id[tool["id"]] = tool
      Array(tool["capabilities"]).each do |cap|
        next unless cap.is_a?(String)
        by_capability[cap] << tool["id"]
      end
    end

    by_capability.each_value(&:sort!)

    registry = {
      "generated_at" => Time.now.utc.iso8601,
      "schema_path" => "schemas/tool-manifest.schema.json",
      "tools" => tools.sort_by { |t| t["id"] },
      "index" => {
        "by_capability" => by_capability,
        "by_id" => by_id,
      },
    }

    FileUtils.mkdir_p(File.dirname(output_path))
    File.write(output_path, JSON.pretty_generate(registry) + "\n")
    registry
  end

  def relative_to_root(path)
    Pathname.new(path).expand_path.relative_path_from(repo_root).to_s
  rescue ArgumentError
    path
  end

  def load_registry!(path)
    JSON.parse(File.read(path))
  rescue Errno::ENOENT
    raise ValidationError, "Registry cache not found: #{path}. Run: make registry"
  rescue JSON::ParserError => e
    raise ValidationError, "Invalid registry JSON at #{path}: #{e.message}"
  end

  def stability_rank(stability)
    stability == "stable" ? 1 : 0
  end

  def pick_best_tool(tools)
    tools.max_by do |t|
      [
        stability_rank(t["stability"]),
        semver_tuple(t["version"]) || [0, 0, 0],
        t["name"].to_s,
      ]
    end
  end

  def resolve!(capability, from_cache_path)
    registry = load_registry!(from_cache_path)
    index = registry.dig("index", "by_capability") || {}
    ids = index[capability]
    unless ids.is_a?(Array) && !ids.empty?
      raise CapabilityNotFound, "No tools found for capability #{capability.inspect}"
    end
    by_id = registry.dig("index", "by_id") || {}
    tools = ids.map { |id| by_id[id] }.compact.map { |t| stringify_keys(t) }
    best = pick_best_tool(tools)
    raise ValidationError, "Registry is missing tool definitions for capability #{capability.inspect}" if best.nil?
    best
  end

  class CLI
    def self.run(argv)
      require "fileutils"
      require "pathname"

      command = argv.shift
      case command
      when "validate"
        errors = ToolRegistry.validate_manifests!
        if errors.empty?
          puts "OK"
          return 0
        end
        errors.each { |e| ToolRegistry.eprint(e) }
        return 1
      when "build"
        output = File.join(ToolRegistry.repo_root.to_s, "state", "registry-cache.json")
        OptionParser.new do |o|
          o.on("--output PATH", "Output path for registry cache JSON") { |v| output = v }
        end.parse!(argv)
        ToolRegistry.build_registry!(output)
        puts output
        return 0
      when "resolve"
        from_cache = File.join(ToolRegistry.repo_root.to_s, "state", "registry-cache.json")
        OptionParser.new do |o|
          o.on("--from-cache PATH", "Path to registry cache JSON") { |v| from_cache = v }
        end.parse!(argv)
        cap = argv.shift
        unless cap && !cap.empty?
          ToolRegistry.eprint("Usage: tool_registry.rb resolve <capability> [--from-cache PATH]")
          return 1
        end
        tool = ToolRegistry.resolve!(cap, from_cache)
        puts JSON.pretty_generate(tool)
        return 0
      else
        ToolRegistry.eprint(<<~USAGE)
          Usage:
            tool_registry.rb validate
            tool_registry.rb build [--output PATH]
            tool_registry.rb resolve <capability> [--from-cache PATH]
        USAGE
        return 1
      end
    rescue ToolRegistry::ValidationError => e
      ToolRegistry.eprint(e.message)
      return 2 if e.is_a?(ToolRegistry::CapabilityNotFound)
      return 1
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  exit(ToolRegistry::CLI.run(ARGV))
end
