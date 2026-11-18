<!--
  Release label: add exactly ONE of these labels to this PR (the "Release label" check fails otherwise).
    major — breaking change (settings reset, removed feature, MCP tool renamed…)
    minor — new feature or visible behaviour change
    patch — bug fix, polish, docs, refactor, CI
  Add skip-changelog as well to leave this PR out of the release notes.
  The PR title becomes the changelog line, so write it for users.
-->

## What changed

<!-- One or two sentences on what this PR does and why. Link any issue it closes: "Closes #123". -->

## How it was tested

- [ ] `scripts/test.sh` passes
- [ ] iPhone changes: `scripts/ios-test.sh` passes
- [ ] Built and ran the app (`scripts/build.sh --run`) and tried the change
- [ ] New or changed logic in `CadenceCore` has tests

<!-- Anything else you checked by hand: calendar sources, multiple displays, presenting / on a call, light & dark mode… -->

## Screenshots

<!-- For UI changes: before / after. Delete this section if there's nothing visual. -->

## Checklist

- [ ] One release label added (`major` / `minor` / `patch`)
- [ ] README updated if the change is user-facing
- [ ] No calendar data, tokens or OAuth secrets in code, screenshots or logs
