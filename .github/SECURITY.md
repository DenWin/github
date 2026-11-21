# Security policy

Only the latest version on the default branch receives security fixes.

Please report vulnerabilities privately using this repository's **Security >
Report a vulnerability** option. If it is unavailable, contact the maintainer
through a private channel; do not disclose secrets or exploit details in a public
issue.

Never attach tokens, private repository data, or full credential-bearing logs.
Include the affected revision, impact, and minimal reproduction instructions.

## Trust boundaries

These scripts can change global Git settings, create worktrees, and (only with
explicit `-Apply`) change supported GitHub security settings. Review changes and
use preview modes first. Run against repositories and workflow files you trust.

Action commit pins and exact module versions improve reproducibility; they do not
prove that a dependency is safe. Review dependency updates, including transitive
and runtime downloads. Local hooks are optional and bypassable. CI checks require
a GitHub ruleset or branch protection to prevent merging around them.
