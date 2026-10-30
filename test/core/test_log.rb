# frozen_string_literal: true

require_relative '../test_helper'
require 'stringio'

# SketchUp 2027 の Ruby コンソールは puts が private。ログが本体を止めないこと
class TestLog < Minitest::Test
  include StoneTestHelpers

  # Sketchup::Console と同じく write だけを持つ（puts は Kernel 由来の private メソッド）
  class PrivatePutsConsole
    attr_reader :buf

    def initialize
      @buf = +''
    end

    def write(*s)
      s.each { |x| @buf << x.to_s }
      s.sum { |x| x.to_s.size }
    end
  end

  class BrokenConsole
    def write(*) = raise(IOError, 'closed')
  end

  def with_output(out)
    Log.quiet = false
    old = Log.output
    Log.output = out
    yield
  ensure
    Log.output = old
    Log.quiet = true
  end

  def test_console_with_private_puts
    con = PrivatePutsConsole.new
    assert_raises(NoMethodError) { con.puts('x') } # SketchUp で起きたエラーと同じ
    with_output(con) { Log.info('click', uv: v2(1, 2)) }
    assert_includes con.buf, '[StoneLayout][INFO] click'
  end

  def test_kernel_puts_route_with_private_puts_stdout
    con = PrivatePutsConsole.new
    old = $stdout
    $stdout = con
    with_output(nil) { Log.error('boom') }
    assert_includes con.buf, 'boom'
  ensure
    $stdout = old
  end

  def test_broken_output_never_raises
    with_output(BrokenConsole.new) { Log.warn('x') }
    assert_includes Log.entries.last, 'x'
  end

  # 実際に問題だった流れ: 目地移動の確定（EditEngine#apply が Log.info を呼ぶ）
  def test_joint_move_commits_with_sketchup_console
    con = PrivatePutsConsole.new
    old = $stdout
    $stdout = con
    doc = flat_doc
    eng = EditEngine.new(doc)
    with_output(nil) { eng.apply(eng.plan_move([eng.pick(v2(900, 300), 3)], 100)) }
    assert_in_delta 1000, Polygon.min_extents(panel_at(doc, 450, 300).points)[0]
  ensure
    $stdout = old
  end
end
