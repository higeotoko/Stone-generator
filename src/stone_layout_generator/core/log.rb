# frozen_string_literal: true

module Higeotoko::StoneLayout::Core
  # 石ID・目地IDを追跡できる簡易ロガー。
  # SketchUp では Ruby コンソールに出力され、直近の記録はメモリにも残る。
  #
  # ログの失敗で本体の処理を止めないこと。SketchUp 2027 の Sketchup::Console は
  # puts が private なので、出力先へ直接 puts を呼ばず Kernel#puts（$stdout 経由）を使う。
  module Log
    MAX_ENTRIES = 500
    @entries = []
    @output = nil # nil = Kernel#puts（Ruby コンソール）。テストでは StringIO などを入れられる
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
        emit(line) unless @quiet
        line
      rescue StandardError
        line
      end

      def emit(line)
        if @output.nil?
          Kernel.puts(line)
        elsif @output.respond_to?(:write)
          @output.write("#{line}\n")
        end
      rescue StandardError
        nil
      end
    end
  end
end
