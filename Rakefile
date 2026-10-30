# frozen_string_literal: true

require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'test'
  t.test_files = FileList['test/**/test_*.rb']
  t.warning = false
end

desc 'Run geometry engine benchmarks (100/500/1000/5000 stones)'
task :bench do
  ruby 'bench/benchmark.rb'
end

task default: :test

desc 'Build the SketchUp extension package (dist/*.rbz)'
task :rbz do
  ruby 'tools/build_rbz.rb'
end
