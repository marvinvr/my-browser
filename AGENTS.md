# AGENTS.md

myBrowser: native macOS browser (Swift 6, SwiftUI + AppKit, WebKit). Product + phases: `docs/PLAN.md`. Architecture: `docs/architecture.md` (keep it current).

## How work is organised
- A **Claude lead** owns a phase/workstream. It plans, splits work into small, clearly specified tasks, and delegates the coding to **Grok High** agents via mmux. The lead reviews every diff, integrates, builds, runs and verifies. The lead codes itself only for glue, UI/feel decisions, or when a Grok agent failed twice on the same task.
- Spawn workers: `mmux new agent "Grok High" -p <project> --prompt "<self-contained task: goal, files, constraints, how to verify, commit message style>"`. The first Grok start in a folder shows a trust prompt: `mmux keys sX y`.
- Wait: `mmux wait sX -t 2h` (exit 3 = needs input: read `mmux status sX`, answer with `mmux answer`). Then `mmux last sX`. Close finished workers (`mmux close sX`).
- Parallel workers that touch overlapping files: give each its own worktree (`mmux worktree new <branch> --agent "Grok High" --prompt ...`), merge after review, then `mmux worktree rm <branch>`.
- Prompts to Grok must be self-contained: Grok does not see your context. Name exact files/types, acceptance criteria, and "build with `xcodegen && xcodebuild ...` before committing".
- Use `Grok xHigh` for harder backend tasks (sync, extension plumbing) if Grok High struggles.

## Rules
- XcodeGen: edit `project.yml`, never hand-edit the generated project. Run `xcodegen` after adding files.
- Build must pass before every push: `xcodegen && xcodebuild -scheme myBrowser -destination 'platform=macOS' build`.
- Direct pushes to `main` are fine. `git fetch && git rebase` before pushing; check staged files (several agents share the repo).
- UI: native macOS look, Liquid Glass, subtle, minimal. Smooth spring animations. Verify UI changes with screenshots before pushing (run the app, `screencapture`). Nothing over the top.
- Never commit personal data. Marvin's real Arc data (`~/Library/Application Support/Arc/StorableSidebar.json`) may be READ locally to test the importer, but tests use small anonymised fixtures.
- No signing/notarization/App Store work: local builds only (Developer ID + iCloud entitlements come later).
- Commits: short imperative subject, no Co-Authored-By trailers.
