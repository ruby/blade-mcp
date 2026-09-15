# blade-mcp

An MCP server that lets Claude read the Ruby mailing lists (ruby-core, ruby-dev, ruby-list, ruby-talk, ruby-ext and ruby-math, since 1995) and what matz said about the design of Ruby, gathered from those lists, bugs.ruby-lang.org and the notes of the developers' meetings. It is for the Ruby core team, to find the discussion behind a behavior and to shape a proposal the way matz has decided similar ones. The archive and the statements are updated daily.

## What you can ask

The answers below are what the server returns today. Most of it sits in Japanese mails that web search does not reach, or is scattered across ticket comments and meeting notes.

**Why does `"abc"[0]` return a String and not an Integer since Ruby 1.9? Find the original discussion.**

> Claude searches in English and finds the answer on ruby-dev, in Japanese. When [[ruby-dev:33186]](https://blade.ruby-lang.org/ruby-dev/33186) asked in January 2008 how to read and write single bytes without one-character strings, matz replied in [[ruby-dev:33192]](https://blade.ruby-lang.org/ruby-dev/33192) that he had weighed whether a String is used more often as text or as bytes and gave text priority. He planned a method for byte access rather than a separate Bytes class, in keeping with Ruby's preference for a few large classes, and had not added one only because he could not think of a good name.

**Has matz ever been open to type annotations in Ruby's syntax?**

> `matz_timeline` returns 11 statements from 2001 to 2022. He said neither yes nor no but "wait" in 2001 ([[ruby-talk:15226]](https://blade.ruby-lang.org/ruby-talk/15226)), rejected a syntax that conflicted with keyword arguments in 2012 ([Feature #5583](https://bugs.ruby-lang.org/issues/5583#note-20)), said he would rather add soft typing with type inference in 2013 ([[ruby-talk:412805]](https://blade.ruby-lang.org/ruby-talk/412805)), and has ruled out any type annotation syntax since 2016 ([Feature #9999](https://bugs.ruby-lang.org/issues/9999#note-13), and in Japanese in [Feature #18626](https://bugs.ruby-lang.org/issues/18626#note-3)).

**I want to move Enumerable#sole (Feature #13683) forward. What does matz still need before accepting it?**

> `search_matz` collects ten years of his statements from the tracker and the meeting notes. In 2016 he was open to a raising variant of `find` but not to the name `find!`, and in 2020 he said "let me consider". On 2026-01-14 he agreed to the behavior and said he did not want an exception class dedicated to the method ([note 41](https://bugs.ruby-lang.org/issues/13683#note-41)), and at the developers' meeting that day he turned down `single` and found `sole` acceptable. What remains open is the name, which he left unsettled in the ticket, and the exception, since he prefers `ArgumentError` but that would break Rails.

## Installation

The server is at `https://blade.ruby-lang.org/mcp` and takes the bearer token shared among the Ruby core team. Add it to Claude Code for every project:

```
claude mcp add --transport http --scope user blade https://blade.ruby-lang.org/mcp --header "Authorization: Bearer $BLADE_MCP_TOKEN"
```

Any other MCP client that speaks Streamable HTTP can connect with the same URL and `Authorization` header.

The skill in [skills/blade](skills/blade/SKILL.md) shows Claude how to use the tools in the core team's daily work, from finding past discussions and judging who decides a question and how matz would see a proposal, to drafting an agenda item for the developers' meeting. Install it as a personal skill:

```
mkdir -p ~/.claude/skills/blade && curl -fsSL https://raw.githubusercontent.com/ruby/blade-mcp/main/skills/blade/SKILL.md -o ~/.claude/skills/blade/SKILL.md
```

## Tools

| Tool | Returns |
| --- | --- |
| `search` | Mails matching the words of the query (Japanese or English, every word must appear) and its meaning, reranked. Filters: `lists`, `date_from`, `date_to`, `from` (`"matz"` for his mails), `include_notifications`. |
| `get_message` | One mail by ref such as `[ruby-dev:30000]`, with its decoded body, attachments, and the refs of its parent and replies. |
| `get_thread` | The whole thread of a mail from its root, in date order, with the parent and depth of each mail. |
| `search_matz` | Statements of what matz said, matching a few words or a whole proposal. Filters: `kinds`, `feature`, `date_from`, `date_to`, `include_reported`. |
| `matz_timeline` | The statements on one `feature`, oldest first. |

A statement has a kind (`accepted`, `rejected`, `design`, `naming`, `policy`, `principle`, `condition`, `undecided` or `opinion`), an English summary and rationale, a verbatim quote in the original language, the features it concerns, and its source: a mail ref, an issue and note number, or an agenda item of the meeting notes in ruby/dev-meeting-log. A statement with `reported_by` is someone else's record of what he said. Statements are evidence of what he said then, not rulings on a new proposal.

Senders are shown with the domain of their address masked (`matz@...`). To, Cc, Reply-To, Return-Path, Received and Message-ID are never returned. Redmine notification mails keep only the subject and the issue number, and the issue itself is read with the bugs.ruby-lang.org MCP server.

## Development

The server imports the original messages from the private `blade-data-vault` bucket into Postgres and serves the tools at `POST /mcp` over Streamable HTTP in stateless mode.

### Configuration

| Variable | Purpose |
| --- | --- |
| `DATABASE_URL` | Postgres with the `vector` extension |
| `BLADE_MCP_TOKEN` | Passphrase expected in `Authorization: Bearer` |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | Read access to `blade-data-vault`, for the import commands |
| `EMBEDDING_URL`, `EMBEDDING_KEY` | Heroku Managed Inference, `cohere-embed-v4` unless `EMBEDDING_MODEL_ID` says otherwise |
| `RERANK_URL`, `RERANK_KEY` | Heroku Managed Inference, `cohere-rerank-3-5` unless `RERANK_MODEL_ID` says otherwise |
| `INFERENCE_URL`, `INFERENCE_KEY` | Heroku Managed Inference, `claude-opus-4-8` unless `INFERENCE_MODEL_ID` says otherwise, for `extract` |
| `BUGS_DATABASE_URL` | The bugs.ruby-lang.org database, read once by `import-redmine` |
| `GITHUB_TOKEN` | Optional token for the GitHub API calls that sync ruby/dev-meeting-log, which are limited to 60 an hour per address without one |

Without the inference variables, `search` ranks by the full-text index alone.

### Commands

```
bin/blade-mcp migrate
bin/blade-mcp import --lists ruby-dev --limit 2000
bin/blade-mcp import-redmine
bin/blade-mcp import-meetings
bin/blade-mcp update
bin/blade-mcp embed --lists ruby-talk
bin/blade-mcp extract --sources redmine --limit 100
```

`import` reads whole lists, `update` takes only messages numbered above the last one stored, embeds them, fetches bugs.ruby-lang.org comments by or about matz through the REST API and the meeting notes changed in ruby/dev-meeting-log, extracts statements from what is not yet read and embeds those statements, which is what Heroku Scheduler runs daily. `import-redmine` fills those comments in from the Redmine database once, and `import-meetings` the notes of the developers' meetings from a tarball of the repository, split into agenda items at their headings; both have to run before the first `update`. `embed` covers every list but ruby-talk by default and skips Redmine notifications. `extract` has the chat model read matz's mails, with the post each one replies to, those comments and the agenda items, and records what he said about Ruby's design as statements: decisions, opinions, conditions and principles, each with its reason and the features it concerns. Every mail, comment and agenda item is read once.

Schema changes are Sequel migrations in `db/migrate`, named with a timestamp and written as raw SQL with `run`, and `migrate` applies the ones not yet recorded, which Heroku does on every release.

### Tests

Tests drop and recreate the tables in `TEST_DATABASE_URL`, which defaults to `postgres://postgres@localhost/blade_mcp_test` and needs pgvector.

```
createdb blade_mcp_test
bundle exec rake test
```

### Benchmark

`benchmark/decisions.rb` measures how well a consultant predicts matz. Each question in `benchmark/decisions.yml` is a decision he made on bugs.ruby-lang.org after the models' training data ends, asked without tools and with `search_matz` and `matz_timeline` that see only what he said before it, and the chat model scores each answer against the decision. The consultant is the chat model itself (`--consultant heroku`) or Claude Code with a given model (`--consultant opus`), optionally with the skill (`--skill skills/blade/SKILL.md`). Tune on `--set tune` and keep `--set check` for confirming a change. `benchmark/workflow.rb` sends the requests in `benchmark/workflow.yml` to Claude Code with and without the skill, through the server at `BLADE_MCP_URL` (default `https://blade.ruby-lang.org/mcp`, with `BLADE_MCP_TOKEN`), and reports whether the answers route each request to whoever decides it and find the past discussion asked for.

Both need `DATABASE_URL` and the inference variables, and only read the database, so production can be used with `PGOPTIONS='-c default_transaction_read_only=on'`. Claude Code runs without the settings, CLAUDE.md and skills of whoever runs it, and its answers count against that account's usage.

```
bundle exec ruby benchmark/decisions.rb --consultant sonnet --skill skills/blade/SKILL.md --set tune tmp/sonnet
bundle exec ruby benchmark/workflow.rb --models sonnet,opus tmp/workflow.json
```
