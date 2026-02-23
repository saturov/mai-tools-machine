#!/usr/bin/env ruby
# frozen_string_literal: true

module AgentLogging
  module Status
    STAGE_PLAN = "Планирование запроса"
    STAGE_COVERAGE = "Проверка покрытия"
    STAGE_POLICY = "Проверка политик"
    STAGE_EXECUTION = "Выполнение задачи"
    STAGE_FINAL = "Финальный статус"
    STAGE_ORDER = [STAGE_PLAN, STAGE_COVERAGE, STAGE_POLICY, STAGE_EXECUTION, STAGE_FINAL].freeze

    module_function

    def build_renderer(output_format:, io:, no_color_env: ENV["NO_COLOR"])
      return NullRenderer.new unless output_format == "pretty"
      return PlainRenderer.new(io: io) unless tty_redraw_enabled?(output_format: output_format, io: io, no_color_env: no_color_env)
      TTYRenderer.new(io: io, colorize: true)
    end

    def tty_redraw_enabled?(output_format:, io:, no_color_env: ENV["NO_COLOR"])
      output_format == "pretty" && io.respond_to?(:tty?) && io.tty? && no_color_env.to_s.strip.empty?
    end

    def normalize_state(state)
      s = state.to_s.upcase
      return s if %w[RUNNING OK FAIL].include?(s)
      "RUNNING"
    end

    def emoji_for(state)
      case normalize_state(state)
      when "OK"
        "✅"
      when "FAIL"
        "❌"
      else
        "⏳"
      end
    end

    def normalize_step_names(steps)
      Array(steps).map do |step|
        if step.is_a?(Hash)
          name = step["capability"].to_s
          name.empty? ? "unknown" : name
        else
          name = step.to_s
          name.empty? ? "unknown" : name
        end
      end
    end

    def build_chain(steps, step_states:, colorize:)
      names = normalize_step_names(steps)
      return "—" if names.empty?

      names.each_with_index.map do |name, idx|
        mode = (step_states[idx] || :pending).to_sym
        if colorize
          case mode
          when :done
            "\e[32m#{name}\e[0m"
          when :active
            "\e[33m#{name}\e[0m"
          when :failed
            "\e[31m#{name}\e[0m"
          else
            name
          end
        else
          case mode
          when :done
            "✅#{name}"
          when :active
            "⏳#{name}"
          when :failed
            "❌#{name}"
          else
            name
          end
        end
      end.join("  ->  ")
    end

    class NullRenderer
      def start(stages:, chain:); end
      def update_stage(name:, state:); end
      def update_chain(steps:, step_states:); end
      def emit_coverage_error(missing_caps:); end
      def emit_final(success:, message: nil); end
      def flush; end
    end

    class PlainRenderer
      def initialize(io: $stdout)
        @io = io
      end

      def start(stages:, chain:)
        @steps = Status.normalize_step_names(chain)
      end

      def update_stage(name:, state:)
        @io.puts("#{name} #{Status.emoji_for(state)}")
        flush
      end

      def update_chain(steps:, step_states:)
        @steps = Status.normalize_step_names(steps)
        @io.puts(Status.build_chain(@steps, step_states: step_states, colorize: false))
        flush
      end

      def emit_coverage_error(missing_caps:)
        caps = Array(missing_caps).map(&:to_s).reject(&:empty?)
        return if caps.empty?
        @io.puts("Реализуйте утилиты: #{caps.join(", ")}")
        flush
      end

      def emit_final(success:, message: nil)
        @io.puts(success ? "Задача выполнена ✅" : "Задача не выполнена ❌")
        if !success && !message.to_s.strip.empty?
          @io.puts(message.to_s.strip)
        end
        flush
      end

      def flush
        @io.flush if @io.respond_to?(:flush)
      end
    end

    class TTYRenderer < PlainRenderer
      def initialize(io: $stdout, colorize: true)
        super(io: io)
        @colorize = colorize
        @stage_states = {}
        @steps = []
        @step_states = []
        @coverage_error = nil
        @final_line = nil
        @final_message = nil
        @rendered = false
        @line_count = 0
        @stages = STAGE_ORDER
      end

      def start(stages:, chain:)
        @stages = Array(stages)
        @stages.each { |name| @stage_states[name] = "RUNNING" }
        @steps = Status.normalize_step_names(chain)
        @step_states = Array.new(@steps.length, :pending)
        render!
      end

      def update_stage(name:, state:)
        @stage_states[name] = Status.normalize_state(state)
        render!
      end

      def update_chain(steps:, step_states:)
        @steps = Status.normalize_step_names(steps)
        @step_states = Array(step_states)
        render!
      end

      def emit_coverage_error(missing_caps:)
        caps = Array(missing_caps).map(&:to_s).reject(&:empty?)
        return if caps.empty?
        @coverage_error = "Реализуйте утилиты: #{caps.join(", ")}"
        render!
      end

      def emit_final(success:, message: nil)
        @stage_states[STAGE_FINAL] = success ? "OK" : "FAIL"
        @final_line = success ? "Задача выполнена ✅" : "Задача не выполнена ❌"
        @final_message = success ? nil : message.to_s.strip
        @final_message = nil if @final_message.to_s.empty?
        render!
      end

      private

      def stage_lines
        lines = @stages.each_with_object([]) do |stage, acc|
          if stage == STAGE_FINAL
            acc << @final_line if @final_line
            next
          end
          acc << "#{stage} #{Status.emoji_for(@stage_states[stage])}"
        end
        execution_index = @stages.index(STAGE_EXECUTION)
        if execution_index
          lines.insert(execution_index + 1, Status.build_chain(@steps, step_states: @step_states, colorize: @colorize))
        end
        lines << @coverage_error if @coverage_error
        lines << @final_message if @final_message
        lines
      end

      def render!
        lines = stage_lines
        if @rendered
          @io.print("\e[#{@line_count}A")
        end
        lines.each do |line|
          @io.print("\e[2K\r#{line}\n")
        end

        if @line_count > lines.length
          diff = @line_count - lines.length
          diff.times { @io.print("\e[2K\r\n") }
          @io.print("\e[#{diff}A")
        end

        @line_count = lines.length
        @rendered = true
        flush
      end
    end
  end
end
