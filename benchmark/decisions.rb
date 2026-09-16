# frozen_string_literal: true

# Has a consultant predict each decision in decisions.yml without tools and with search_matz and matz_timeline, and
# has the chat model of Heroku Managed Inference score the predictions against what matz decided.

require_relative 'support'

options, out = BladeMcp::Bench.options('Usage: bundle exec ruby benchmark/decisions.rb [options] OUT_DIR')

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
ask = BladeMcp::Bench.consultant(options, chat) { |question, tools| prompt(question, tools, options[:skill]) }

FileUtils.mkdir_p(out)
questions = BladeMcp::Bench.questions('decisions.yml', options)
BladeMcp::Bench.answers(questions, out, options) do |question, condition, trial|
  run = ask.(question, question['question'], condition == 'tools')
  user = "Question:\n#{question['question']}\n\nWhat matz actually decided:\n#{question['truth']}\n\nPrediction:\n#{run[:answer]}"
  run[:score] = BladeMcp::Bench.grade(chat, user, JUDGE)
  warn "#{question['id']} #{condition} #{trial + 1}: #{run[:score].values_at('decision', 'reasons')} #{run[:calls].size} calls"
  run
end

mean = BladeMcp::Bench.method(:mean)
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
