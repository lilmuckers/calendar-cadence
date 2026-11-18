<!--
  Release notes template, filled in by scripts/release-notes.sh in the Release workflow.
  Placeholders: {{VERSION}} {{TAG}} {{PREVIOUS_TAG}} {{DATE}} {{BUMP}} {{CHANGELOG}} {{SIGNING_NOTE}} {{CHECKSUMS}}
  {{CHANGELOG}} is GitHub's generated list of merged PRs, grouped by .github/release.yml.
-->
## Cadence {{VERSION}}

_Released {{DATE}} · {{BUMP}} release_

{{SIGNING_NOTE}}

{{CHANGELOG}}

## 📥 Install

1. Download **Cadence-{{VERSION}}.dmg** below.
2. Open it and drag **Cadence** into **Applications**.
3. Launch Cadence from Applications and allow calendar access when asked.

Requires macOS 14 or later on Apple Silicon.

<details>
<summary>Downloads and checksums</summary>

| File | What it is |
|---|---|
| `Cadence-{{VERSION}}.dmg` | Disk image, drag to Applications |
| `Cadence-{{VERSION}}.zip` | The same app, zipped (for scripted installs) |
| `SHA256SUMS.txt` | Checksums for both |

```text
{{CHECKSUMS}}
```

Check a download with `shasum -a 256 -c SHA256SUMS.txt`.
</details>
