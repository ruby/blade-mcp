# frozen_string_literal: true

# Has a consultant say what each proposal in gaps.yml still needs before matz accepts it, without tools and with
# search_matz and matz_timeline, and has the chat model of Heroku Managed Inference check the points raised against
# the ones matz actually raised: how many of his it found, and how many of its own his reply contradicts.

require_relative 'support'

options, out = BladeMcp::Bench.options('Usage: bundle exec ruby benchmark/gaps.rb [options] OUT_DIR')

JUDGE = {
  type: 'function',
  function: {
    name: 'score',
    description: 'Check an assessment of what a proposal still needs against what matz actually asked for.',
    parameters: {
      type: 'object',
      properties: {
        hits: {
          type: 'array', items: {type: 'integer', enum: [0, 1]},
          description: "One entry for each of matz's numbered points, in the same order: 1 when the assessment raises " \
                       'that point in substance, 0 when it does not. Wording need not match, but a point counts only ' \
                       'when the assessment says the same thing, not merely something about the same topic.'
        },
        contradicted: {
          type: 'integer',
          description: "How many points the assessment raises that matz's reply contradicts: things he settled the " \
                       'other way, or asked for the opposite of. Points he simply did not mention are not counted.'
        },
        note: {type: 'string', description: 'One sentence on what the assessment found and what it got wrong'}
      },
      required: %w[hits contradicted note]
    }
  }
}.freeze

def prompt(question, tools, skill)
  text = 'You advise Ruby core developers on getting a proposal past Yukihiro Matsumoto (matz), the creator of Ruby. ' \
         "Today is #{question['date_to'] + 1}, and the proposal below is about to reach him. Say what it still needs " \
         'before he accepts it: the conditions he will set, the objections he will raise, the questions he will ask ' \
         'and the corrections he will make. Give each as its own point, the one he is most likely to raise first. ' \
         'Answer in at most 300 words.'
  return text unless tools

  text = "#{text} You can look up what matz said before today with the tools. Base each point on what he said, and " \
         'cite the statements you rely on by their source.'
  skill ? "#{text}\n\n#{File.read(skill)}" : text
end

# The hits the judge returns are trusted only for their length: a short array leaves the rest missed.
def recall(score, asks)
  hits = Array(score['hits']).map { |hit| hit == 1 ? 1 : 0 }
  (hits.first(asks) + Array.new([asks - hits.size, 0].max, 0)).sum.fdiv(asks)
end

chat = BladeMcp::Bench::HerokuConsultant.from_env or abort 'benchmark: INFERENCE_URL and INFERENCE_KEY are not set'
ask = BladeMcp::Bench.consultant(options, chat) { |question, tools| prompt(question, tools, options[:skill]) }

FileUtils.mkdir_p(out)
questions = BladeMcp::Bench.questions('gaps.yml', options)
BladeMcp::Bench.answers(questions, out, options) do |question, condition, trial|
  run = ask.(question, question['proposal'], condition == 'tools')
  asks = question['asks'].each_with_index.map { |item, n| "#{n + 1}. #{item['ask']}" }.join("\n")
  user = "Proposal:\n#{question['proposal']}\n\nWhat matz actually asked for in his reply:\n#{asks}\n\n" \
         "The assessment of what the proposal still needs:\n#{run[:answer]}"
  run[:score] = BladeMcp::Bench.grade(chat, user, JUDGE)
  run[:recall] = recall(run[:score], question['asks'].size)
  run[:contradicted] = run[:score]['contradicted'].to_i
  warn "#{question['id']} #{condition} #{trial + 1}: recall #{run[:recall].round(2)} contradicted #{run[:contradicted]} #{run[:calls].size} calls"
  run
end

mean = BladeMcp::Bench.method(:mean)
score = ->(runs) { "#{mean.(runs.map { |run| run['recall'] })} / #{mean.(runs.map { |run| run['contradicted'] })}" }
done = Dir[File.join(out, '*.json')].map { |path| JSON.parse(File.read(path)) }.sort_by { |r| [r['set'], r['date_to'].to_s, r['id']] }
report = ["# #{options[:consultant]}#{' with the skill' if options[:skill]}", '',
          '| proposal | set | asks | without tools: recall / contradicted | with tools | tool calls |',
          '| --- | --- | --- | --- | --- | --- |']
done.each do |r|
  report << "| #{r['id']} (##{r['issue']}) | #{r['set']} | #{r['asks'].size} | #{score.(r['baseline'])} | " \
            "#{score.(r['tools'])} | #{mean.(r['tools'].map { |run| run['calls'].size })} |"
end
done.group_by { |r| r['set'] }.merge('all' => done).each do |set, rs|
  report << "| **#{set}** | | #{rs.sum { |r| r['asks'].size }} | #{score.(rs.flat_map { |r| r['baseline'] })} | " \
            "#{score.(rs.flat_map { |r| r['tools'] })} | |"
end
done.each do |r|
  report << '' << "## #{r['id']}" << ''
  %w[baseline tools].each do |condition|
    r[condition].each do |run|
      report << "- #{condition} #{run['recall'].round(2)}/#{run['contradicted']}: #{run.dig('score', 'note')}"
    end
  end
end
File.write(File.join(out, 'report.md'), "#{report.join("\n")}\n")
puts report.first(done.size + 4 + done.group_by { |r| r['set'] }.size + 1)
