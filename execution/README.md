# Execution scripts

One line per script. Add an entry whenever you add a script — this index is how the
task loop finds tools without reading every file.

| Script | Does |
| --- | --- |
| `latest-mfa-report.ps1` | Every user who can still sign in with SMS or a phone call, in plain-English columns, flagged Legacy vs Modern. One CSV to `output/`. Reference implementation of the script contract. |

All scripts are read-only against the tenant and require
`Microsoft.Graph.Authentication`. See `.claude/rules/execution.md` for the contract.
