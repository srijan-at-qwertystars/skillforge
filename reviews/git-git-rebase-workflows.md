# Review: git-rebase-workflows

Accuracy: 4/5
Completeness: 5/5
Actionability: 5/5
Trigger quality: 4/5
Overall: 4.5/5

Issues:
- Line 119: States `--fixup=amend:<commit-hash>` requires "Git 2.32+" but the correct version is Git 2.34.0. This is a factual error.
- Negative triggers exclude "GitHub PR workflows" which is reasonable, but the skill does cover PR-adjacent workflows (cleaning up before PR). The boundary could be clearer.
- Positive triggers in the description could explicitly mention `git pull --rebase` since the skill covers it in the body.
