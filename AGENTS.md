# AGENTS.md

myBrowser: native macOS browser (Swift 6, SwiftUI + AppKit, WebKit). Product + phases: `docs/PLAN.md`. Architecture: `docs/architecture.md` (keep it current).

## How work is organised
- **Summary: all code by Grok High agents (Grok xHigh ONLY for really complex tasks, e.g. CloudKit sync conflicts or extension runtime plumbing, when Grok High clearly can't do it; never Codex, never Claude). One Claude lead for the whole project, orchestration only, minimal Claude usage.**
- **HARD RULE: Claude leads do not write code or project files themselves.** A Claude lead only plans, writes task prompts, spawns **Grok High** agents via mmux, waits, reviews diffs (read-only), and sends fixes back to the Grok agent that made them. Scaffolding, project.yml, architecture.md drafts, tests, UI tweaks, bug fixes: all of it goes to Grok High agents. The lead's own edits are limited to AGENTS.md/PLAN notes of a few lines. If a Grok agent fails twice, try a fresh Grok High with a better prompt, not Claude.
- Spawn workers: `mmux new agent "Grok High" -p <project> --prompt "<self-contained task: goal, files, constraints, how to verify, commit message style>"`. The first Grok start in a folder shows a trust prompt: `mmux keys sX y`.
- Wait: `mmux wait sX -t 2h` (exit 3 = needs input: read `mmux status sX`, answer with `mmux answer`). Then `mmux last sX`. Close finished workers (`mmux close sX`).
- Parallel workers that touch overlapping files: give each its own worktree (`mmux worktree new <branch> --agent "Grok High" --prompt ...`), merge after review, then `mmux worktree rm <branch>`.
- Prompts to Grok must be self-contained: Grok does not see your context. Name exact files/types, acceptance criteria, and "build with `xcodegen && xcodebuild ...` before committing".

## Claude budget (Marvin: this project must use very little Claude)
- Only ONE Claude lead at a time for the whole project; parallel work = several Grok agents under that one lead.
- Keep the lead cheap: medium effort, no reading of large files or full diffs. Let a separate Grok High agent do code reviews (`git diff`, build, run, screenshots) and report a short verdict; the lead reads only those summaries and `git log --stat`.
- Use `mmux wait` in the foreground (no polling loops, no repeated status reads). Long-running waits are fine and cost nothing.

## Cleanup
- Keep mmux tidy at natural points (after each merge, not mid-work): close finished Grok agents (`mmux close sX`), remove their worktrees (`mmux worktree rm <branch>`), delete merged branches.

## Rules
- XcodeGen: edit `project.yml`, never hand-edit the generated project. Run `xcodegen` after adding files.
- Build must pass before every push: `xcodegen && xcodebuild -scheme myBrowser -destination 'platform=macOS' build`.
- Direct pushes to `main` are fine. `git fetch && git rebase` before pushing; check staged files (several agents share the repo).
- UI: native macOS look, Liquid Glass, subtle, minimal. Smooth spring animations. Verify UI changes with screenshots before pushing (run the app, `screencapture`). Nothing over the top.
- Agents verify UI with `scripts/snapshot.sh`.
- Never commit personal data. Marvin's real Arc data (`~/Library/Application Support/Arc/StorableSidebar.json`) may be READ locally to test the importer, but tests use small anonymised fixtures.
- No signing/notarization/App Store work: local builds only (Developer ID + iCloud entitlements come later).
- Commits: short imperative subject, no Co-Authored-By trailers.
