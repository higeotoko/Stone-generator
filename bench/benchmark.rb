# frozen_string_literal: true

# 幾何エンジン単体のベンチマーク（SketchUp 本体の描画・面生成時間は含まない）
#   ruby bench/benchmark.rb [石の枚数...]
require 'benchmark'
require_relative '../src/stone_layout_generator/core'
include Higeotoko::StoneLayout::Core
Log.quiet = true

counts = ARGV.empty? ? [100, 500, 1000, 5000] : ARGV.map(&:to_i)

def time
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000.0
end

puts format('%-6s %-8s %10s %10s %10s %10s %10s %10s %10s', 'stones', 'actual', 'layout', 'mesh_all',
            'pick', 'drag(1)', 'commit', 'save', 'load')
counts.each do |n|
  rows = Math.sqrt(n * 600.0 / 900).round.clamp(1, 10_000)
  cols = (n.to_f / rows).ceil
  surf = SurfaceDefinition.flat_wall(cols * 900.0, rows * 600.0)
  doc = nil
  t_layout = time { doc = LayoutBuilder.build(surf, Settings.new('pattern' => 'running')).first }
  t_mesh = time { StoneGeometry.new(doc).build_many(doc.panels.keys) }
  eng = EditEngine.new(doc)
  p = Vec2.new((cols / 2) * 900.0, ((rows / 2) / 2 * 2) * 600.0 + 300) # 偶数段（目地位置が 900 の倍数）
  piece = nil
  t_pick = time { 20.times { piece = eng.pick(p, 5) } } / 20
  plan = nil
  t_drag = time { 20.times { |i| plan = eng.plan_move([piece], 10 + i) } } / 20
  t_commit = time do
    cs = eng.apply(plan)
    StoneGeometry.new(doc).build_many(cs.all_rebuild)
  end
  json = nil
  t_save = time { json = Serializer.dump(doc) }
  t_load = time { Serializer.load(json) }
  puts format('%-6d %-8d %10.1f %10.1f %10.2f %10.2f %10.2f %10.1f %10.1f', n, doc.panels.size, t_layout, t_mesh,
              t_pick, t_drag, t_commit, t_save, t_load)
end
puts '(単位: ms / pick・drag は1回あたり / drag は1回のマウス移動でのプレビュー計算)'
