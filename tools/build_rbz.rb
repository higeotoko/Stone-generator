# frozen_string_literal: true

# SketchUp 拡張パッケージ (.rbz) を作る:  ruby tools/build_rbz.rb
#   → dist/stone_layout_generator-<VERSION>.rbz
# .rbz は src/ 直下（stone_layout_generator.rb とフォルダ）をルートにした zip。
require 'fileutils'
require_relative '../src/stone_layout_generator/core/version'

root = File.expand_path('..', __dir__)
src = File.join(root, 'src')
dist = File.join(root, 'dist')
FileUtils.mkdir_p(dist)
out = File.join(dist, "stone_layout_generator-#{Higeotoko::StoneLayout::VERSION}.rbz")
FileUtils.rm_f(out)

files = Dir.chdir(src) do
  ['stone_layout_generator.rb'] + Dir.glob('stone_layout_generator/**/*').select { |f| File.file?(f) }
end.reject { |f| File.basename(f).start_with?('.') }.sort

Dir.chdir(src) do
  ok = system('zip', '-q', '-X', out, *files)
  abort('zip コマンドが見つからないか失敗しました') unless ok
end
puts "#{out} (#{files.size} files, #{(File.size(out) / 1024.0).round(1)} KB)"
