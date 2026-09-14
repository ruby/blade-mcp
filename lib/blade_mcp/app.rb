# frozen_string_literal: true

require 'mcp'
require 'openssl'
require 'sinatra/base'

module BladeMcp
  # POST /mcp speaks MCP over Streamable HTTP in its stateless form, so each
  # request is answered with one JSON response and any Puma process can
  # serve it.
  class App < Sinatra::Base
    INSTRUCTIONS = <<~TEXT
      Archive of the Ruby mailing lists: ruby-core, ruby-dev, ruby-list, ruby-talk, ruby-ext and ruby-math, from
      1995 on. Use it to find past discussions and the decisions made in them. Start with `search`, read a hit with
      `get_message`, and see the discussion around it with `get_thread`. Messages are identified by refs such as
      [ruby-dev:30000]. Redmine notification mails keep only their subject and issue number; read those issues with
      the bugs.ruby-lang.org MCP server (`get_issue`), which also takes the issue numbers reported here.

      What matz said about the design of Ruby, in these mails, on bugs.ruby-lang.org and in the developers' meeting
      notes, is also kept as statements, each with a verbatim quote and its source:
      `search_matz` finds them by words or meaning, and `matz_timeline` lists those on one feature in date order. To
      judge how matz would see a new proposal, search with the proposal, weigh the statements found, and cite their
      quotes and sources. A statement is evidence of what he said then, not a ruling on the proposal.
    TEXT

    # rack-protection guards cookie sessions of browser apps. Its Origin check
    # would turn away browser-based MCP clients, and there is no cookie here.
    set :protection, false
    set :token, ENV.fetch('BLADE_MCP_TOKEN', nil)
    set :embedder, Inference::Embedding.from_env
    set :reranker, Inference::Rerank.from_env

    before '/mcp' do
      halt 401, {'www-authenticate' => 'Bearer'}, '' unless authorized?
    end

    post('/mcp') { mcp }
    get('/mcp') { mcp }
    delete('/mcp') { mcp }

    private

    def authorized?
      expected = settings.token.to_s
      given = request.env['HTTP_AUTHORIZATION'].to_s[/\ABearer (.+)\z/, 1].to_s
      !expected.empty? && OpenSSL.secure_compare(given, expected)
    end

    def mcp
      db = DB.current
      store = Store.new(db)
      statements = Statements.new(db)
      search = BladeMcp::Search.new(store, embedder: settings.embedder, reranker: settings.reranker)
      matz_search = BladeMcp::Search.new(statements, embedder: settings.embedder, reranker: settings.reranker)
      server = MCP::Server.new(name: 'blade-mcp', version: VERSION, instructions: INSTRUCTIONS, tools: Tools.all,
                               server_context: {store:, search:, statements:, matz_search:})
      # A bearer token is required, so a rebinding page cannot call it anyway.
      transport = MCP::Server::Transports::StreamableHTTPTransport.new(
        server, stateless: true, enable_json_response: true, dns_rebinding_protection: false
      )
      # Holding one connection for the request checks it out and validates it once.
      db.synchronize { transport.handle_request(request) }
    end
  end
end
