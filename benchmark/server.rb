# frozen_string_literal: true

# search_matz and matz_timeline over stdio, for Claude Code in decisions.rb. Nothing dated after BENCH_DATE_TO is
# returned, whatever date_to the client asks for.

require_relative 'support'

module CapDate
  def call(date_to: nil, **arguments)
    super(date_to: [date_to, ENV.fetch('BENCH_DATE_TO')].compact.min, **arguments)
  end
end

tools = BladeMcp::Bench::HerokuConsultant::TOOLS
tools.each { |tool| tool.singleton_class.prepend(CapDate) }
statements = BladeMcp::Statements.new(BladeMcp::DB.connect)
search = BladeMcp::Search.new(statements, embedder: BladeMcp::Inference::Embedding.from_env,
                                          reranker: BladeMcp::Inference::Rerank.from_env)
server = MCP::Server.new(name: 'blade-mcp', version: BladeMcp::VERSION, instructions: BladeMcp::App::INSTRUCTIONS,
                         tools:, server_context: {statements:, matz_search: search})
MCP::Server::Transports::StdioTransport.new(server).open
