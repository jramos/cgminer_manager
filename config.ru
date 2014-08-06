# This file is used by Rack-based servers to start the application.

if defined?(Unicorn)
  GC_FREQUENCY = 1
  require 'unicorn/oob_gc'
  GC.disable
  use Unicorn::OobGC, GC_FREQUENCY
end

require ::File.expand_path('../config/environment',  __FILE__)
run Rails.application
