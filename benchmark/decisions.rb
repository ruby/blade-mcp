# frozen_string_literal: true

# Has a consultant predict each decision in decisions.yml without tools and with search_matz and matz_timeline, and
# has the chat model of Heroku Managed Inference score the predictions against what matz decided.

require_relative 'support'

options = {consultant: 'heroku', set: 'all', trials: 3, jobs: 4}
parser = OptionParser.new do |opts|
  opts.banner = 'Usage: bundle exec ruby benchmark/decisions.rb [options] OUT_DIR'
  opts.on('--consultant NAME', 'heroku for the chat model of Heroku Managed Inference, or a Claude Code model such as opus')
  opts.on('--skill PATH', 'Give the consultant this skill along with the tools')
  opts.on('--set SET', %w[tune check all], 'Questions to ask: tune, check or all (default)')
  opts.on('--trials N', Integer, 'Answers per question and condition (default 3)')
  opts.on('--jobs N', Integer, 'Answers produced at once (default 4)')
  opts.on('--only ID,...', Array, 'Ask only these questions')
  opts.on('--baseline-from DIR', 'Take the answers without tools from an earlier run instead of asking again')
end
parser.parse!(into: options)
out = ARGV.fetch(0) { abort parser.help }

JUDGE = {
  type: 'function',
  function: {
    name: 'score',
    description: 'Score a prediction of what matz decided against what he actually decided.',
    parameters: {
      type: 'object',
      properties: {
        decision: {type: 'integer', enum: [0, 1, 2],
                   description: '2 when the prediction chooses, accepts or turns down what matz did, 1 when it points the ' \
                                'same way or gets one of several points right, 0 otherwise'},
        reasons: {type: 'integer', enum: [0, 1, 2], description: "2 when the main reasons match matz's own, 1 when some do, 0 when none do"},
        note: {type: 'string', description: 'One sentence on what matched and what did not'}
      },
      required: %w[decision reasons note]
    }
  }
}.freeze

def prompt(question, tools, skill)
  text = 'You advise Ruby core developers on how Yukihiro Matsumoto (matz), the creator of Ruby, would decide questions ' \
         "of Ruby's design. Today is #{question['date_to'] + 1}. Predict his decision, stating what he would choose, " \
         'accept or turn down, then the reasons he would give. Answer in at most 200 words.'
  return text unless tools

  text = "#{text} You can look up what matz said before today with the tools. Base the prediction on what he said, " \
         'and cite the statements you rely on by their source.'
  skill ? "#{text}\n\n#{File.read(skill)}" : text
end

chat = BladeMcp::Bench::HerokuConsultant.from_env or abort 'benchmark: INFERENCE_URL and INFERENCE_KEY are not set'
if options[:consultant] == 'heroku'
  statements = BladeMcp::Statements.new(BladeMcp::DB.connect)
  search = BladeMcp::Search.new(statements, embedder: BladeMcp::Inference::Embedding.from_env,
                                            reranker: BladeMcp::Inference::Rerank.from_env)
  context = {statements:, matz_search: search}
  ask = lambda do |question, tools|
    # A client passes on what the server says about itself at initialize, which Claude Code does by itself.
    system = tools ? "#{prompt(question, true, options[:skill])}\n\n#{BladeMcp::App::INSTRUCTIONS}" : prompt(question, false, nil)
    chat.ask(system, question['question'], context:, date_to: question['date_to'], tools:)
  end
else
  claude = BladeMcp::Bench::ClaudeCode.new(options[:consultant])
  ask = lambda do |question, tools|
    if tools
      mcp = {command: RbConfig.ruby, args: [File.join(__dir__, 'server.rb')], env: {BENCH_DATE_TO: question['date_to'].to_s}}
      allowed = %w[mcp__blade__search_matz mcp__blade__matz_timeline]
    end
    begin
      claude.ask(prompt(question, tools, options[:skill]), question['question'], mcp:, allowed: allowed.to_a)
    rescue RuntimeError => e
      warn "#{question['id']}: asking again after #{e.message[0, 200]}"
      claude.ask(prompt(question, tools, options[:skill]), question['question'], mcp:, allowed: allowed.to_a)
    end
  end
end

FileUtils.mkdir_p(out)
questions = BladeMcp::Bench.load('decisions.yml').select { |q| options[:set] == 'all' || q['set'] == options[:set] }
                                  .select { |q| !options[:only] || options[:only].include?(q['id']) }
results = {}
jobs = []
questions.each do |question|
  path = File.join(out, "#{question['id']}.json")
  next if File.exist?(path)

  result = results[path] = question.merge('baseline' => Array.new(options[:trials]), 'tools' => Array.new(options[:trials]))
  if options[:'baseline-from']
    result['baseline'] = JSON.parse(File.read(File.join(options[:'baseline-from'], "#{question['id']}.json")))['baseline']
  else
    options[:trials].times { |trial| jobs << [question, path, 'baseline', trial] }
  end
  options[:trials].times { |trial| jobs << [question, path, 'tools', trial] }
end

lock = Mutex.new
BladeMcp::Bench.each_job(jobs, options[:jobs]) do |question, path, condition, trial|
  run = ask.(question, condition == 'tools')
  user = "Question:\n#{question['question']}\n\nWhat matz actually decided:\n#{question['truth']}\n\nPrediction:\n#{run[:answer]}"
  run[:score] = BladeMcp::Bench.grade(chat, user, JUDGE)
  warn "#{question['id']} #{condition} #{trial + 1}: #{run[:score].values_at('decision', 'reasons')} #{run[:calls].size} calls"
  lock.synchronize do
    result = results.fetch(path)
    result[condition][trial] = run
    File.write(path, JSON.pretty_generate(result)) if (result['baseline'] + result['tools']).none?(&:nil?)
  end
end

mean = ->(values) { values.empty? ? 0 : (values.sum.to_f / values.size).round(2) }
score = ->(runs) { "#{mean.(runs.map { |run| run.dig('score', 'decision') })} / #{mean.(runs.map { |run| run.dig('score', 'reasons') })}" }
done = Dir[File.join(out, '*.json')].map { |path| JSON.parse(File.read(path)) }.sort_by { |r| [r['set'], r['decided'].to_s, r['id']] }
report = ["# #{options[:consultant]}#{' with the skill' if options[:skill]}", '',
          '| question | set | without tools: decision / reasons | with tools | tool calls |', '| --- | --- | --- | --- | --- |']
done.each do |r|
  report << "| #{r['id']} (##{r['issue']}) | #{r['set']} | #{score.(r['baseline'])} | #{score.(r['tools'])} | " \
            "#{mean.(r['tools'].map { |run| run['calls'].size })} |"
end
done.group_by { |r| r['set'] }.merge('all' => done).each do |set, rs|
  report << "| **#{set}** | | #{score.(rs.flat_map { |r| r['baseline'] })} | #{score.(rs.flat_map { |r| r['tools'] })} | |"
end
done.each do |r|
  report << '' << "## #{r['id']}" << ''
  %w[baseline tools].each do |condition|
    r[condition].each { |run| report << "- #{condition} #{run['score'].values_at('decision', 'reasons').join('/')}: #{run.dig('score', 'note')}" }
  end
end
File.write(File.join(out, 'report.md'), "#{report.join("\n")}\n")
puts report.first(done.size + 4 + done.group_by { |r| r['set'] }.size + 1)
