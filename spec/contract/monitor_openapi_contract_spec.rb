# frozen_string_literal: true

require 'spec_helper'
require 'yaml'

# Cross-repo contract test: every envelope field that MonitorClient +
# view-models read from cgminer_monitor's /v2/* responses must be
# declared in the monitor-shipped OpenAPI spec. Catches field rename
# or envelope reshape at CI time instead of at page-load time.
#
# The OpenAPI yml ships inside the cgminer_monitor gem at
# lib/cgminer_monitor/openapi.yml — cgminer_monitor.gemspec includes
# `lib/**/*.yml` in the files glob, so Gem::Specification.find_by_name
# resolves a predictable absolute path. Manager pins the monitor gem
# by tag in the Gemfile :development, :test group; bumping the pin is
# a deliberate reviewable event that regenerates this contract.
#
# Scope is envelope-only: `:miners`, `:host`, `:port`, `:available`,
# `:id`, `:ok`, `:response`, `:error`, `:fields`, `:data`, `:status`.
# Cgminer payload drift (`SUMMARY`, `DEVS`, `MHS 5s`, etc.) is a
# separate concern covered by api_client + FakeCgminer fixtures.
RSpec.describe 'MonitorClient ↔ monitor OpenAPI contract' do
  let(:openapi) do
    spec = Gem::Specification.find_by_name('cgminer_monitor')
    YAML.load_file(File.join(spec.gem_dir, 'lib/cgminer_monitor/openapi.yml'))
  end

  # Follows at most one level of $ref against components.schemas to
  # transparently resolve the SnapshotEnvelope + GraphDataEnvelope
  # factoring. Inline schemas (/v2/miners, /v2/healthz) pass through.
  def response_schema(openapi, path, method: 'get', status: '200')
    op = openapi.dig('paths', path, method)
    raise "path #{method.upcase} #{path} not in OpenAPI" if op.nil?

    schema = op.dig('responses', status, 'content', 'application/json', 'schema')
    if schema.is_a?(Hash) && schema['$ref']
      ref = schema['$ref'].sub(%r{^#/components/schemas/}, '')
      schema = openapi.dig('components', 'schemas', ref)
    end
    schema
  end

  def declared_properties(schema)
    (schema['properties'] || {}).keys
  end

  describe 'GET /v2/miners' do
    it 'declares the keys MonitorClient#miners reads' do
      schema = response_schema(openapi, '/v2/miners')
      expect(declared_properties(schema)).to include('miners')

      miner_items = schema.dig('properties', 'miners', 'items')
      %w[id host port available].each do |k|
        expect(declared_properties(miner_items)).to include(k)
      end
    end
  end

  describe 'GET /v2/miners/{miner}/{summary,stats,devices,pools}' do
    %w[summary stats devices pools].each do |verb|
      it "#{verb} envelope declares ok, response, error" do
        schema = response_schema(openapi, "/v2/miners/{miner}/#{verb}")
        %w[ok response error].each do |k|
          expect(declared_properties(schema)).to include(k)
        end
      end
    end
  end

  describe 'GET /v2/graph_data/{metric}' do
    %w[hashrate temperature availability].each do |metric|
      it "#{metric} declares fields and data" do
        schema = response_schema(openapi, "/v2/graph_data/#{metric}")
        %w[fields data].each do |k|
          expect(declared_properties(schema)).to include(k)
        end
      end
    end
  end

  describe 'GET /v2/healthz' do
    it 'declares status (minimum required by HttpApp#/healthz)' do
      schema = response_schema(openapi, '/v2/healthz')
      expect(declared_properties(schema)).to include('status')
    end
  end
end
