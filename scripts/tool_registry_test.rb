#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "tool_registry"

class ToolRegistrySchemaSubsetTest < Minitest::Test
  def test_valid_manifest_passes_subset_schema
    schema = {
      "type" => "object",
      "required" => %w[name version description capabilities entrypoint input_schema output_schema],
      "additionalProperties" => false,
      "properties" => {
        "name" => { "type" => "string", "pattern" => "^[a-z0-9-]+$" },
        "version" => { "type" => "string", "pattern" => "^[0-9]+\\.[0-9]+\\.[0-9]+$" },
        "description" => { "type" => "string", "minLength" => 10 },
        "capabilities" => { "type" => "array", "minItems" => 1, "items" => { "type" => "string" } },
        "entrypoint" => {
          "type" => "object",
          "required" => %w[type command],
          "additionalProperties" => false,
          "properties" => {
            "type" => { "type" => "string", "enum" => %w[shell python node] },
            "command" => { "type" => "string", "minLength" => 1 },
          },
        },
        "input_schema" => { "type" => "object" },
        "output_schema" => { "type" => "object" },
      },
    }

    manifest = {
      "name" => "drive-uploader",
      "version" => "0.1.0",
      "description" => "Upload a file to Drive.",
      "capabilities" => ["drive.upload"],
      "entrypoint" => { "type" => "shell", "command" => "./run.sh" },
      "input_schema" => { "type" => "object" },
      "output_schema" => { "type" => "object" },
    }

    errors = ToolRegistry::JSONSchemaSubset.validate(schema, manifest)
    assert_equal [], errors
  end

  def test_pattern_and_min_length_failures_are_reported
    schema = {
      "type" => "object",
      "required" => ["version", "description"],
      "properties" => {
        "version" => { "type" => "string", "pattern" => "^[0-9]+\\.[0-9]+\\.[0-9]+$" },
        "description" => { "type" => "string", "minLength" => 10 },
      },
    }
    manifest = { "version" => "0.1", "description" => "short" }
    errors = ToolRegistry::JSONSchemaSubset.validate(schema, manifest)
    assert(errors.any? { |e| e.include?("pattern") })
    assert(errors.any? { |e| e.include?("minLength") || e.include?("length") })
  end
end

