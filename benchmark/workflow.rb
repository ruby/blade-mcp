# frozen_string_literal: true

# Sends the requests in workflow.yml to Claude Code with and without skills/blade, through the MCP server at
# BLADE_MCP_URL and WebFetch, and reports how the answers route requests and whether they find past discussions.

require_relative 'support'

options = {models: %w[sonnet opus], trials: 2, jobs: 24, skill: BladeMcp::Bench::SKILL}
parser = OptionParser.new do |opts|
  opts.banner = 'Usage: bundle exec ruby benchmark/workflow.rb [options] OUT.json'
  opts.on('--models LIST', Array, 'Claude Code models (default sonnet,opus)')
  opts.on('--skill PATH', "The skill to measure (default #{BladeMcp::Bench::SKILL})")
  opts.on('--skill-only', 'Skip the answers without the skill')
  opts.on('--only ID,...', Array, 'Send only these requests')
  opts.on('--trials N', Integer, 'Answers per request and condition (default 2)')
  opts.on('--jobs N', Integer, 'Answers produced at once (default 24)')
end
parser.parse!(into: options)
out = ARGV.fetch(0) { abort parser.help }
abort 'benchmark: BLADE_MCP_TOKEN is not set' unless ENV['BLADE_MCP_TOKEN']

ROUTE = {
  type: 'function',
  function: {
    name: 'score',
    description: 'Score how an answer routes a request about the development of Ruby against who actually decides it.',
    parameters: {
      type: 'object',
      properties: {
        route: {type: 'integer', enum: [0, 1, 2],
                description: '2 when the answer names the right decider and venue, 1 when it is partly right, such as the ' \
                             'right decider among several or an unneeded detour to matz, 0 when it sends the request elsewhere'},
        note: {type: 'string', description: 'One sentence on what matched and what did not'}
      },
      required: %w[route note]
    }
  }
}.freeze
PROMPT = 'You help members of the Ruby core team with their daily work on the development of Ruby. Answer in at most 250 words.'
HISTORY = %w[search get_message get_thread].freeze
# Claude Code expands ${BLADE_MCP_TOKEN} itself, so the token stays out of the command line.
SERVER = {type: 'http', url: ENV.fetch('BLADE_MCP_URL', 'https://blade.ruby-lang.org/mcp'),
          headers: {Authorization: 'Bearer ${BLADE_MCP_TOKEN}'}}.freeze
ALLOWED = (HISTORY + %w[search_matz matz_timeline]).map { |tool| "mcp__blade__#{tool}" } + ['WebFetch']

chat = BladeMcp::Inference::Chat.from_env or abort 'benchmark: INFERENCE_URL and INFERENCE_KEY are not set'
store = BladeMcp::Store.new(BladeMcp::DB.connect)
requests = BladeMcp::Bench.load('workflow.yml')
threads = requests['discussions'].to_h do |d|
  next [d['id'], []] unless d['root']

  list, seq = d['root'].split(':')
  [d['id'], store.thread(store.find(list, Integer(seq))[:id]).map { |m| "#{m[:list]}:#{m[:seq]}" }]
end

selected = (requests['routing'] + requests['discussions']).select { |r| !options[:only] || options[:only].include?(r['id']) }
conditions = options[:'skill-only'] ? [true] : [false, true]
jobs = options[:models].product(conditions, selected, (1..options[:trials]).to_a)
results = []
lock = Mutex.new
BladeMcp::Bench.each_job(jobs, options[:jobs]) do |model, skill, request, trial|
  system = skill ? "#{PROMPT}\n\n#{File.read(options[:skill])}" : PROMPT
  claude = BladeMcp::Bench::ClaudeCode.new(model)
  run = begin
    claude.ask(system, request['request'], mcp: SERVER, allowed: ALLOWED, builtin: 'WebFetch')
  rescue RuntimeError => e
    warn "#{request['id']}: asking again after #{e.message[0, 200]}"
    claude.ask(system, request['request'], mcp: SERVER, allowed: ALLOWED, builtin: 'WebFetch')
  end
  row = {model: run[:model], skill:, id: request['id'], trial:, cost_usd: run[:cost_usd], answer: run[:answer],
         history_calls: run[:calls].count { |call| HISTORY.include?(call[:tool]) },
         read_maintainers: run[:calls].any? { |call| call[:tool] == 'WebFetch' && call[:input].to_s.include?('maintainers') }}
  if request['truth']
    user = "Request:\n#{request['request']}\n\nWho actually decides:\n#{request['truth']}\n\nAnswer:\n#{run[:answer]}"
    row.merge!(kind: 'routing', **BladeMcp::Bench.grade(chat, user, ROUTE).transform_keys(&:to_sym))
  else
    cited = run[:answer].scan(/ruby-(?:core|dev|list|talk|ext|math):\d+/)
    found = cited.intersect?(threads[request['id']]) || (request['issue'] && run[:answer].match?(/(?<!\d)#{request['issue']}(?!\d)/))
    row.merge!(kind: 'discussion', found: !!found)
  end
  warn "#{model} skill=#{skill} #{request['id']} #{trial}: #{row[:route] || row[:found]}"
  lock.synchronize { results << row }
end
File.write(out, JSON.pretty_generate(results))

mean = ->(values) { values.empty? ? '-' : (values.sum.to_f / values.size).round(2) }
puts '| model | skill | routing | read doc/maintainers.md | discussions found | history calls | cost (USD) |', '| --- | --- | --- | --- | --- | --- | --- |'
results.group_by { |row| [row[:model], row[:skill]] }.sort_by { |key, _| key.map(&:to_s) }.each do |(model, skill), rows|
  routing, discussions = rows.partition { |row| row[:kind] == 'routing' }
  puts "| #{model} | #{skill} | #{mean.(routing.map { |row| row[:route] })} | #{routing.count { |row| row[:read_maintainers] }}/#{routing.size} | " \
       "#{discussions.count { |row| row[:found] }}/#{discussions.size} | #{mean.(rows.map { |row| row[:history_calls] })} | " \
       "#{rows.sum { |row| row[:cost_usd].to_f }.round(2)} |"
end
