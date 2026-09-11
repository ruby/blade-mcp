# frozen_string_literal: true

# Loads what the web process needs. bin/blade-mcp adds the parser, vault,
# importer and embedder, so the web process does not carry mail and the AWS
# SDK.
module BladeMcp
  VERSION = '0.1.0'
  LISTS = %w[ruby-core ruby-dev ruby-list ruby-talk ruby-ext ruby-math].freeze
end

require_relative 'blade_mcp/text'
require_relative 'blade_mcp/bigram'
require_relative 'blade_mcp/db'
require_relative 'blade_mcp/store'
require_relative 'blade_mcp/inference'
require_relative 'blade_mcp/search'
require_relative 'blade_mcp/tools'
require_relative 'blade_mcp/app'
