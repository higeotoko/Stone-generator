# frozen_string_literal: true

# rake が無い環境用: ruby test/run_all.rb
Dir[File.join(__dir__, '**', 'test_*.rb')].sort.each { |f| require f }
