# How comparable agent tools reached many developers

Research on how comparable agent tools reached many developers, 2026-11-06. Star counts from the GitHub API on that day. It drives the repo itself: name, README, demo, install.

## The projects

| Project | Stars | Created | First line of the README | Install | Where it took off |
|---|---|---|---|---|---|
| [JuliusBrussee/caveman](https://github.com/JuliusBrussee/caveman) | 117,984 | 2026-04-04 | "why many token when few do trick" / "Caveman make your AI agent say less and read less." Then four number tiles (33.2% fewer input tokens, 54% cheaper, 397 to 76 tokens, Adobe Research citation) and a side-by-side "Normal agent, 63 tokens / Caveman agent, 20 tokens". | `claude plugin marketplace add JuliusBrussee/caveman` | Hacker News, one day after the repo: [Caveman: Why use many token when few token do trick](https://news.ycombinator.com/item?id=47647455), 904 points, 2026-04-05. Then GitHub Trending #1 and a ThePrimeagen video. 4.1K stars in 3 days by word of mouth ([36Kr](https://eu.36kr.com/en/p/3756573503963912)). |
| [rtk-ai/rtk](https://github.com/rtk-ai/rtk) | 85,740 | 2026-01-22 | "CLI proxy that reduces LLM token consumption by 60-90% on common dev commands. Single Rust binary, zero dependencies." | `brew install rtk`, then `rtk init -g` installs the hook | r/ClaudeAI thread with the author's own numbers: 10.2M tokens saved (89.2%) over two weeks, `cargo test` 155 lines to 3 ([snapshot](https://reddit.sentinel-team.org/posts/1r2tt7q/snapshots/2026-02-12T20%3A01%3A24.200376Z)). Discord badge in the README. |
| [thedotmack/claude-mem](https://github.com/thedotmack/claude-mem) | 113,935 | 2025-08-31 | Logo, sponsor logos, 30 README translations. Description: "Persistent Context Across Sessions for Every Agent". | `/plugin marketplace add thedotmack/claude-mem` | About 46K stars within two days in April 2026 ([Crypto Briefing](https://cryptobriefing.com/claude-mem-permanent-memory-46k-stars/)): one pain (Claude forgets between sessions), one command, no account. |
| [obra/superpowers](https://github.com/obra/superpowers) | 313,532 | 2025-10-09 | "Superpowers is a complete software development methodology for your coding agents". No numbers, a story of how a session goes. | Official Claude plugin marketplace | Author's blog post on HN: [Superpowers: How I'm using coding agents in October 2025](https://news.ycombinator.com/item?id=45547344), 435 points. Follow-up [Superpowers 6](https://news.ycombinator.com/item?id=48739459), 196 points. |
| [upstash/context7](https://github.com/upstash/context7) | 64,285 | 2025-03-26 | "Up-to-date Docs for AI Agents", then a "Without Context7 / With Context7" block. | `npx ctx7 setup`, or the "Add to Claude" button | Company launch, Claude directory listing. |
| [ccusage/ccusage](https://github.com/ccusage/ccusage) | 19,345 | 2025-05-29 | Logo, "Mentioned in Awesome Claude Code" badge, Trendshift badge, then a terminal screenshot. Description is only `npx ccusage`. | `npx ccusage` | HN: [Ccusage: A CLI tool for analyzing Claude Code usage from local JSONL files](https://news.ycombinator.com/item?id=44610925), 75 points; awesome-claude-code. |
| [smtg-ai/claude-squad](https://github.com/smtg-ai/claude-squad) | 8,741 | 2025-03-09 | "Claude Squad is a terminal app that manages multiple Claude Code, Codex, Gemini ... agents", then a screenshot and a video. | `brew install claude-squad` | GitHub Trending, awesome lists. |
| [htdt/godogen](https://github.com/htdt/godogen) | 7,296 | 2026-02-06 | "Autonomous game development for Godot ... with Claude Code and Codex", a YouTube thumbnail as the demo. | Clone and publish script | [Show HN: Claude Code skills that build complete Godot games](https://news.ycombinator.com/item?id=47400868), 337 points. Proof that game engines plus coding agents land on HN. |
| [musistudio/claude-code-router](https://github.com/musistudio/claude-code-router) | 38,021 | 2025-02-25 | "One local control plane for every AI agent: route across models" | `npm install -g @musistudio/claude-code-router` | HN: [Claude Code Router](https://news.ycombinator.com/item?id=44705958), 160 points. |

## What they have in common

1. **One pain, one number, above the fold.** caveman shows four number tiles and a 63-token vs 20-token side-by-side before any explanation. context7 shows "Without / With". Readers decide in the first screen.
2. **Install is one line, inside the agent.** caveman, claude-mem and superpowers all install through the Claude Code plugin marketplace (`/plugin marketplace add owner/repo`). rtk and ccusage are one `brew` or `npx` line. Nobody needs a second step to see value.
3. **The launch post title is the tagline.** caveman's HN title is word for word its README heading. Show HN titles that won name the concrete result ("skills that build complete Godot games").
4. **The author's own numbers on Reddit.** rtk's r/ClaudeAI post quoted two weeks of its own token savings, not a benchmark.
5. **Burst, then Trending.** caveman went HN (day 1), GitHub Trending #1, then press and video. Trending needs many stars inside 24 hours, so channels should go out on the same day, not spread over a week.

## What gets punished

Token claims that count bytes instead of the bill get taken apart on HN:

- [RTK reports token savings, but our cost benchmarks disagree](https://news.ycombinator.com/item?id=49656471) (170 points, [Quesma](https://quesma.com/blog/does-rtk-make-ai-coding-cheaper/)): `rtk gain` reported 89% saved, the measured bill rose 5% on one model, per-task cost up 17%. Cause: removed bytes are not billed tokens, and extra agent turns cost more.
- [The Token Compression Illusion: Why I'm Skeptical of RTK](https://news.ycombinator.com/item?id=48588755) (121 points).
- [I benchmarked Claude Code's caveman plugin against "be brief."](https://news.ycombinator.com/item?id=47954745) (89 points, [article](https://www.maxtaylor.me/articles/i-benchmarked-caveman-against-two-words)): a two-word prompt matched caveman's token savings at equal quality.

For warmd this is the opening: its [A/B](../ab.md) measures billed tokens and dollars from `claude -p` JSON, reports the spread, and says where it does not help (task time on small projects, Python tokens within the spread). Lead with time on game engines and billed cost, keep the byte numbers second.

## Gaps in warmd compared with them

- **No plugin-marketplace install.** The three biggest tools install with `/plugin marketplace add`. warmd needs `curl | bash` plus `warmd init`. A `.claude-plugin/marketplace.json` that runs the install and `warmd init` would remove the second step. Not done in this branch, it is a code change.
- **Windows only.** Many readers are on macOS and Linux. The README says it in the first screen so nobody feels tricked, and presents the Unity and Godot editors on Windows as the focus.
- **Demo shows a small Node test.** The hero image is a real session, but the strongest number (Unity 56 s to 3 s) has no moving picture. A screen recording of one Unity test class, cold vs warm, would be the best launch asset.
- **No social proof yet.** awesome-claude-code accepts warmd from 2026-11-16 (14 days after the first commit) or at 100 stars. Its "Mentioned in Awesome Claude Code" badge is what ccusage shows at the top.
- **awesome-claude-code requires a human submission** through its web issue form; agents and `gh` submissions are refused.
