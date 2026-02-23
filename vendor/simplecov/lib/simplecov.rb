# frozen_string_literal: true

require "coverage"

module SimpleCov
  class << self
    def start(&block)
      @config = Config.new
      @started = true
      @minimum = { line: 0, branch: 0 }
      @minimum_by_file = { line: 0, branch: 0 }
      @filters = []
      @track_glob = nil
      @coverage_enabled = false
      @at_exit_installed = false

      begin
        Coverage.start(lines: true, branches: true)
        @coverage_enabled = :lines_and_branches
      rescue StandardError
        Coverage.start
        @coverage_enabled = :lines_only
      end

      DSLContext.new.instance_eval(&block) if block
      install_at_exit
      @config
    end

    def enable_coverage(mode)
      @config.coverage_mode = mode
    end

    def track_files(glob)
      @track_glob = glob
    end

    def minimum_coverage(line: 0, branch: 0)
      @minimum = { line: line.to_f, branch: branch.to_f }
    end

    def minimum_coverage_by_file(line: 0, branch: 0)
      @minimum_by_file = { line: line.to_f, branch: branch.to_f }
    end

    def add_filter(pattern)
      @filters << pattern.to_s
    end

    private

    def install_at_exit
      return if @at_exit_installed

      @at_exit_installed = true
      at_exit do
        next unless @started
        next if $ERROR_INFO

        covered_files = collect_file_rows
        global_line, global_branch = global_percentages(covered_files)

        failures = []
        if global_line < @minimum[:line]
          failures << "Line coverage #{format("%.2f", global_line)}% is below #{@minimum[:line]}%"
        end
        if global_branch < @minimum[:branch]
          failures << "Branch coverage #{format("%.2f", global_branch)}% is below #{@minimum[:branch]}%"
        end

        covered_files.each do |row|
          if row[:line_percent] < @minimum_by_file[:line]
            failures << "#{row[:file]} line coverage #{format("%.2f", row[:line_percent])}% is below #{@minimum_by_file[:line]}%"
          end
          if row[:branch_percent] < @minimum_by_file[:branch]
            failures << "#{row[:file]} branch coverage #{format("%.2f", row[:branch_percent])}% is below #{@minimum_by_file[:branch]}%"
          end
        end

        if failures.empty?
          warn("Coverage OK (line=#{format("%.2f", global_line)}%, branch=#{format("%.2f", global_branch)}%)")
        else
          failures.each { |msg| warn(msg) }
          exit(false)
        end
      end
    end

    def collect_file_rows
      result = Coverage.result
      candidates = tracked_candidates

      candidates.map do |file|
        cov = result[file]
        line_cov = line_cov_data(cov)
        branch_cov = branch_cov_data(cov)
        branch_counts = flatten_branch_counts(branch_cov)
        lines_total = line_cov.compact.length
        lines_hit = line_cov.compact.count { |v| v.to_i.positive? }
        line_percent = percentage(lines_hit, lines_total)
        branches_total = branch_counts.length
        branches_hit = branch_counts.count { |v| v.to_i.positive? }
        branch_percent = percentage(branches_hit, branches_total)
        {
          file: file,
          line_percent: line_percent,
          branch_percent: branch_percent,
          lines_hit: lines_hit,
          lines_total: lines_total,
          branches_hit: branches_hit,
          branches_total: branches_total,
        }
      end
    end

    def tracked_candidates
      files =
        if @track_glob.to_s.empty?
          []
        else
          Dir.glob(@track_glob).map { |f| File.expand_path(f) }
        end
      files.reject { |f| filtered?(f) }.sort
    end

    def filtered?(file)
      @filters.any? { |flt| file.include?(flt) }
    end

    def line_cov_data(cov)
      return [] if cov.nil?
      return cov if cov.is_a?(Array)
      return cov[:lines] || cov["lines"] || [] if cov.is_a?(Hash)
      []
    end

    def branch_cov_data(cov)
      return {} if cov.nil?
      return {} unless cov.is_a?(Hash)
      cov[:branches] || cov["branches"] || {}
    end

    def flatten_branch_counts(branch_cov)
      counts = []
      branch_cov.each_value do |value|
        if value.is_a?(Hash)
          value.each_value { |count| counts << count }
        else
          counts << value
        end
      end
      counts
    end

    def global_percentages(rows)
      line_hits = rows.sum { |row| row[:lines_hit] }
      line_total = rows.sum { |row| row[:lines_total] }
      branch_hits = rows.sum { |row| row[:branches_hit] }
      branch_total = rows.sum { |row| row[:branches_total] }
      [percentage(line_hits, line_total), percentage(branch_hits, branch_total)]
    end

    def percentage(hit, total)
      return 100.0 if total.zero?
      ((hit.to_f / total.to_f) * 100.0)
    end
  end

  class Config
    attr_accessor :coverage_mode
  end

  class DSLContext
    def enable_coverage(mode)
      SimpleCov.enable_coverage(mode)
    end

    def track_files(glob)
      SimpleCov.track_files(glob)
    end

    def minimum_coverage(line: 0, branch: 0)
      SimpleCov.minimum_coverage(line: line, branch: branch)
    end

    def minimum_coverage_by_file(line: 0, branch: 0)
      SimpleCov.minimum_coverage_by_file(line: line, branch: branch)
    end

    def add_filter(pattern)
      SimpleCov.add_filter(pattern)
    end
  end
end
