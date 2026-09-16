---
name: blade
description: Research Ruby's design history and find what a proposal still needs before matz accepts it, with the blade MCP server (the Ruby mailing list archive since 1995 and matz's statements from the lists, bugs.ruby-lang.org and the developers' meeting notes). Use when looking for past discussions of a feature, a library, RubyGems, Bundler, packaging or the release process, checking precedents for a proposal, asking how matz would see a name, an API or a behavior, or what a proposal is missing, or preparing a ticket or an agenda item for the developers' meeting. Also for requests like "matz はどう思うか", "過去の議論を探して", "開発者会議に出す前に".
---

# Ruby design history with blade

The blade MCP server (`https://blade.ruby-lang.org/mcp`, bearer token shared among the core team) answers two questions, what was discussed before and what matz said about it. Use it in daily work to shape a proposal so that it can be accepted by whoever decides it, matz at the developers' meeting or the maintainers of the area, by finding what it is still missing while there is time to fix it. Issues themselves are read with the bugs.ruby-lang.org MCP server.

## Who decides

It depends on the part of Ruby, as [doc/maintainers.md](https://github.com/ruby/ruby/blob/master/doc/maintainers.md) in ruby/ruby lists. Before saying where a question goes, read the file, from a ruby/ruby checkout or from `https://raw.githubusercontent.com/ruby/ruby/master/doc/maintainers.md`, and find the entry for the part. Do not go by memory, since maintainers change and some parts are maintained by matz himself.

- Language core features and core classes are matz's. The evaluator has a maintainer of its own.
- A module maintainer (a standard library, an extension, or a default gem such as RubyGems or Bundler) decides the features of that part, respecting the discussion on ruby-core and ruby-dev. Some entries add that an API change needs matz's approval, and matz maintains a few libraries himself.
- A submaintainer cannot change or add a feature alone, and neither can anyone for a part with no maintainer. Both need consensus on ruby-core or ruby-dev.
- Bundled gems follow the policy of each upstream repository. Platforms have platform maintainers, and stable branches and patch releases have branch maintainers.

Past discussions are useful in every part. Where someone other than matz decides, find the positions taken before and their reasons with `search` (`from` narrows to one person), and read what `search_matz` returns as background, not as the decision. Bring to matz only the part he has to decide.

## Tools

| Tool | Returns |
| --- | --- |
| `search` | Mails from ruby-core, ruby-dev, ruby-list, ruby-talk, ruby-ext and ruby-math, by words (Japanese or English, all must appear) and by meaning. Filters: `lists`, `date_from`/`date_to`, `from` (`from: "matz"` for his mails). |
| `get_message`, `get_thread` | One mail by ref such as `[ruby-dev:30000]`, or its whole thread. Redmine notification mails keep only the subject and issue number, so read the issue with `get_issue`. |
| `search_matz` | Statements of what matz said, each with a kind, an English summary, a verbatim quote and its source (mail ref, issue note, or meeting notes). Query with words or a whole proposal. Filters: `kinds`, `feature`, dates, `include_reported`. |
| `matz_timeline` | The statements on one feature, oldest first, to see how his view changed. |

Kinds: `accepted` and `rejected` (a proposal), `design` and `naming` (settled), `policy`, `principle` (a value beyond the case), `condition` (what a proposal needs), `undecided` (put off), `opinion` (a view without settling). A statement with `reported_by` is someone else's record of what he said, such as meeting notes.

## Finding past discussions

Search with the feature's name and with a plain description of the problem, in English and in Japanese, since older discussion is mostly on ruby-dev and ruby-list. Read the hits with `get_message`, follow the thread with `get_thread`, and move to the issue when the mail points to one.

## What a proposal still needs

Before a proposal reaches matz, name the conditions he will set, the objections he will raise and the questions he will ask, so that it can answer them first. He rarely answers a proposal whole: he takes it apart and replies to each decision in it.

So take it apart first. A proposal decides a name, a return value, what happens at the edges (out of range, empty, a mismatch in length), which error is raised, how much lands at once, and who settles the rest. Each is a place he can accept the proposal and still send it back.

For each of them, gather in this order:

1. `matz_timeline` on the feature itself, then on the neighbor the decision copies: the method the new one sits beside, the class it extends, the keyword it borrows. What he settled for the neighbor is what he asks the new one to match, down to the return value (`nil` where the neighbor returns `nil`) and which side raises.
2. `search_matz` for the purpose he has stated for the thing being extended. He justifies an addition by what the receiver is for, and objects when a proposal argues only from another class having a method of that name.
3. `search_matz` with `kinds: ["condition"]` and the words of the area, for the conditions he attaches there: release it as a gem first and come back with the response, cut it to a minimal first subset and add the rest on demand, propose the follow-ups one at a time each with its own use case, settle the part that is not his with the maintainer of that part, write the specification in the ticket and not only in the pull request.

Weigh what comes back:

- His latest word on a feature outweighs his earlier ones. An acceptance he later put on hold is on hold.
- What he decided on the feature and its neighbors outweighs a principle he stated about other features.
- For a name, rely on `naming`, `accepted` and `rejected` statements. A name that appears inside an `opinion` or `design` statement is often a placeholder, not his choice.
- Prefer his own words to a `reported_by` record when both exist.
- Look for what his past choices in the area have in common, and expect the new one to follow it.

Then write the points, each with the quote and source it rests on, and say what the proposal would have to answer:

- A claim the proposal leans on without evidence is a point: that nobody uses what it removes, that the need is real, that nothing will break. He asks for the fact, not for a plan to find it.
- A decision the proposal leaves open is a point. He does not settle an open question on the proposer's behalf; he asks for a concrete answer to choose from.
- A gap between his reason and the proposal's is a point even when they reach the same conclusion. He often accepts the thing and rejects the argument for it, and then the next proposal built on that argument fails.
- Scope is a point of its own. A batch of methods, a syntax and its generalization, a fix and its cleanup: he cuts them apart and takes the smallest piece that stands alone.
- Leave out the process he does not use. Version targets, deprecation schedules, migration paths and compatibility surveys are points only where the record shows him asking for one; more often he leaves them to the implementer or to the branch maintainers.

A statement is evidence of what he said then, not a ruling on the new proposal. Say where the evidence is thin or points both ways, and keep his view separate from your own advice.

## Preparing a proposal

1. Run the section above to find what the proposal still needs from matz, and do the same for the maintainers who decide the rest, with `search` and `from`.
2. Answer each point in the proposal itself: adjust the name, the API shape and the edge-case behavior toward what was accepted before, and keep the alternatives with the reason each was dropped.
3. Write the use case in concrete code. Real needs come before accepting a method.
4. Split the questions by who decides. Settle the maintainers' part on the tracker, and narrow what goes to matz to what only he can decide, such as the name or whether the feature is wanted at all.
5. For the developers' meeting, draft the agenda comment for the DevMeeting ticket in its required format:

   ```
   * [Feature #NNNNN] Ticket title (your name)
     * A short summary, what changed since the last discussion, and the question for matz.
   ```

Show the draft to the user. Do not post to bugs.ruby-lang.org unless asked.
