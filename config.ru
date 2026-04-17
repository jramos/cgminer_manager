# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('lib', __dir__)
require 'cgminer_manager'

run CgminerManager::HttpApp
