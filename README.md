# blade-mcp

An MCP server for the archive of the Ruby mailing lists (ruby-core, ruby-dev, ruby-list, ruby-talk, ruby-ext and ruby-math). It imports the original messages from the private `blade-data-vault` bucket into Postgres and serves read-only tools at `POST /mcp` over Streamable HTTP in stateless mode: `search`, `get_message` and `get_thread` over the mail, and `search_matz` and `matz_timeline` over what matz said about the design of Ruby, drawn from his mails, bugs.ruby-lang.org comments and the notes of the developers' meetings.

```
claude mcp add --transport http blade https://blade.ruby-lang.org/mcp --header "Authorization: Bearer $BLADE_MCP_TOKEN"
```

Responses carry the sender's name with the domain masked (`matz@...`), the date, the subject, the decoded body and attachments. To, Cc, Reply-To, Return-Path, Received and Message-ID are never returned. Redmine notification mails keep only the subject and the issue number, which the bugs.ruby-lang.org MCP server takes.

The skill in [skills/blade](skills/blade/SKILL.md) shows Claude how to use these tools in the core team's daily work, from finding past discussions and judging who decides a question and how matz would see a proposal, to drafting an agenda item for the developers' meeting. Install it as a personal skill:

```
mkdir -p ~/.claude/skills/blade && curl -fsSL https://raw.githubusercontent.com/ruby/blade-mcp/main/skills/blade/SKILL.md -o ~/.claude/skills/blade/SKILL.md
```

## Configuration

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

## Commands

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

## Development

Schema changes are Sequel migrations in `db/migrate`, named with a timestamp and written as raw SQL with `run`, and `migrate` applies the ones not yet recorded, which Heroku does on every release. Tests drop and recreate the tables in `TEST_DATABASE_URL`, which defaults to `postgres://postgres@localhost/blade_mcp_test` and needs pgvector.

```
createdb blade_mcp_test
bundle exec rake test
```
