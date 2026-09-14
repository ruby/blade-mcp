# blade-mcp

An MCP server for the archive of the Ruby mailing lists (ruby-core, ruby-dev, ruby-list, ruby-talk, ruby-ext and ruby-math). It imports the original messages from the private `blade-data-vault` bucket into Postgres and serves three read-only tools, `search`, `get_message` and `get_thread`, at `POST /mcp` over Streamable HTTP in stateless mode.

```
claude mcp add --transport http blade https://<host>/mcp --header "Authorization: Bearer $BLADE_MCP_TOKEN"
```

Responses carry the sender's name with the domain masked (`matz@...`), the date, the subject, the decoded body and attachments. To, Cc, Reply-To, Return-Path, Received and Message-ID are never returned. Redmine notification mails keep only the subject and the issue number, which the bugs.ruby-lang.org MCP server takes.

## Configuration

| Variable | Purpose |
| --- | --- |
| `DATABASE_URL` | Postgres with the `vector` extension |
| `BLADE_MCP_TOKEN` | Passphrase expected in `Authorization: Bearer` |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | Read access to `blade-data-vault`, for the import commands |
| `EMBEDDING_URL`, `EMBEDDING_KEY` | Heroku Managed Inference, `cohere-embed-v4` unless `EMBEDDING_MODEL_ID` says otherwise |
| `RERANK_URL`, `RERANK_KEY` | Heroku Managed Inference, `cohere-rerank-3-5` unless `RERANK_MODEL_ID` says otherwise |
| `BUGS_DATABASE_URL` | The bugs.ruby-lang.org database, read once by `import-redmine` |

Without the inference variables, `search` ranks by the full-text index alone.

## Commands

```
bin/blade-mcp migrate
bin/blade-mcp import --lists ruby-dev --limit 2000
bin/blade-mcp import-redmine
bin/blade-mcp update
bin/blade-mcp embed --lists ruby-talk
```

`import` reads whole lists, `update` takes only messages numbered above the last one stored, embeds pending messages and then fetches bugs.ruby-lang.org comments by or about matz through the REST API, which is what Heroku Scheduler runs daily. `import-redmine` fills those comments in from the Redmine database once and has to run before the first `update`. `embed` covers every list but ruby-talk by default and skips Redmine notifications.

## Development

Tests drop and recreate the tables in `TEST_DATABASE_URL`, which defaults to `postgres://postgres@localhost/blade_mcp_test` and needs pgvector.

```
createdb blade_mcp_test
bundle exec rake test
```
