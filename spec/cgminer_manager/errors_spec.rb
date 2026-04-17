# frozen_string_literal: true

RSpec.describe CgminerManager do
  describe 'error hierarchy' do
    it 'defines a top-level Error' do
      expect(CgminerManager::Error.ancestors).to include(StandardError)
    end

    it 'defines ConfigError < Error' do
      expect(CgminerManager::ConfigError.ancestors).to include(CgminerManager::Error)
    end

    it 'defines MonitorError < Error' do
      expect(CgminerManager::MonitorError.ancestors).to include(CgminerManager::Error)
    end

    it 'defines MonitorError::ConnectionError' do
      expect(CgminerManager::MonitorError::ConnectionError.ancestors)
        .to include(CgminerManager::MonitorError)
    end

    it 'defines MonitorError::ApiError' do
      expect(CgminerManager::MonitorError::ApiError.ancestors)
        .to include(CgminerManager::MonitorError)
    end

    it 'defines PoolManagerError::DidNotConverge < Error' do
      expect(CgminerManager::PoolManagerError::DidNotConverge.ancestors)
        .to include(CgminerManager::Error)
    end
  end
end
