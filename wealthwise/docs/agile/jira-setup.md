# Jira and Confluence setup (free tier)

Both products have a free plan on Atlassian Cloud (up to 10 users each at the time of writing; check the pricing page before relying on that). They are SaaS, so they are the one part of this project that does not run in WSL. Everything else in the repo ties back to them through naming conventions.

## 1. Create the sites
1. Sign up at atlassian.com and choose **Jira** and **Confluence** Free. Both live on one `yourname.atlassian.net` site.
2. In Jira create a **Scrum** project, key `WW`, using the *team-managed* template (simplest on the free plan).
3. In Confluence create a space with key `WW` and paste the pages from `docs/confluence/` (Confluence accepts Markdown paste; use Insert > Markup > Markdown if headings do not convert).

## 2. Import the starting backlog
1. Jira > Settings > System > **External system import > CSV** and upload `docs/agile/backlog.csv`.
2. Map: `Summary`, `Issue Type`, `Priority`, `Labels`, `Description`, `Status`, `Issue Id` (as Issue Id), `Parent` (as Parent), and `Story Points` to *Story point estimate*.
3. Create Sprint 1 and drag in the highest-priority `To Do` stories (S10, S13, S15 are good first picks).

## 3. Workflow and board
- Columns: `To Do` > `In Progress` > `In Review` > `Done`. Add `In Review` under Board > Columns.
- WIP limit of 3 on `In Progress` and 2 on `In Review` to surface bottlenecks.
- Quick filters: `Only my issues`, `Blocked` (label), `Bugs`.

## 4. Connect GitHub (free)
1. Install the **GitHub for Jira** app from the Atlassian Marketplace and connect your repository.
2. Branch names `feature/WW-12-rebalance-basket`, commit messages `WW-12 add basket model`, PR titles `WW-12: ...`. Jira then shows branches, PRs and builds on the issue.
3. Smart commits: `WW-12 #time 2h #comment spiked lot selection` and `WW-12 #done`.

## 5. Ceremonies (two-week sprints)
| Ceremony | Cadence | Output |
| --- | --- | --- |
| Backlog refinement | Weekly, 45 min | Stories sized, acceptance criteria written, spikes identified |
| Sprint planning | Day 1, 60 min | Sprint goal, committed stories |
| Daily stand-up | 10 min | Blockers visible on the board |
| Review and demo | Last day | Working software against the sprint goal |
| Retrospective | Last day | Two actions, each with an owner, logged in Confluence |

Use the retro template in `docs/confluence/06-retrospective-template.md`.
