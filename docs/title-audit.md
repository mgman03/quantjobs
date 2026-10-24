# Title audit (24 October 2026)

`title-audit-2026-10-24.tsv` is a snapshot of every cached posting available for this review. It contains 11,620 rows (10,326 distinct company/title pairs) with the original title alongside the rendered role, detail, level, intake, and location. Regenerate it from current cache with `QuantJobs --check --dump-titles`.

I read the 1,004 distinct titles labeled Intern or New Grad, then scanned the entire 11,620-row export for empty roles, leftover intake years, lone Intern subtitles, generic roles, and broken parentheses. The full set of experienced titles was scanned but not individually adjudicated.

The review found several recurring patterns, including Databricks `(2027 Start)` in the main role, xAI seasons in the main role, occupational titles buried under generic programme prefixes, Intern badges appearing only in the subtitle, and campus recruiting staff labeled New Grad. The parser and level matching now handle those patterns. The TSV preserves the original titles so each rendered row can be checked against its source.

After the changes, the export has no empty roles, no `Intern` appearing only in a subtitle, and no empty parentheses. Two early-career roles still show a year in the main title: a Google Q3 2027 fixed-term contract and a Tower Research 2027 internship targeting 2028 graduates. Those years carry distinct information, so they remain visible. Two source postings are simply titled `Intern` or `Internships`; there is no discipline to promote into their main role.
