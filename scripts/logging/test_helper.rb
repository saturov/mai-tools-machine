#!/usr/bin/env ruby
# frozen_string_literal: true

require "simplecov"

SimpleCov.start do
  enable_coverage :branch
  track_files "scripts/logging/**/*.rb"
  minimum_coverage line: 100, branch: 100
  minimum_coverage_by_file line: 100, branch: 100
  add_filter "/test/"
end
