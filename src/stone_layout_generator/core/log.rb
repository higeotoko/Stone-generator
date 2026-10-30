# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  # 石ID・目地IDを追跡できる簡易ロガー。
  # SketchUp では Ruby コンソールに出力され、直近の記録はメモリにも残る。
  module Log
    MAX_ENTRIES = 500
    @entries = []
    @output = $stdout
    @quiet = false

    class << self
      attr_accessor :output, :quiet
      attr_reader :entries

      def info(msg, ctx = {})
        write(:info, msg, ctx)
      end

      def warn(msg, ctx = {})
        write(:warn, msg, ctx)
      end

      def error(msg, ctx = {})
        write(:error, msg, ctx)
      end

      def clear
        @entries.clear
      end

      private

      def write(level, msg, ctx)
        line = +"[StoneLayout][#{level.to_s.upcase}] #{msg}"
        line << ' ' << ctx.map { |k, v| "#{k}=#{v.inspect}" }.join(' ') unless ctx.empty?
        @entries << line
        @entries.shift while @entries.size > MAX_ENTRIES
        @output.puts(line) unless @quiet || @output.nil?
        line
      end
    end
  end
end
