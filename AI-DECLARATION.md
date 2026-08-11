---
version: "0.1.2"
level: auto
processes:
  design: pair
  implementation: auto
  testing: auto
  documentation: auto
  review: auto
  deployment: auto
---

This format is based on [AI-DECLARATION.md](https://ai-declaration.md/en/0.1.2).

## Notes

- Claude wrote the code, the documents, the vector art, the synthesised sound,
  and the commit messages, in Claude Code sessions. Most of those sessions run
  to completion with nobody watching, which is what `auto` means here.
- criccomini decides what the game is and rules on how it feels, which is why
  design is `pair` and not `auto`. Work Claude designed and shipped has been
  cut afterwards for playing badly, and
  [`docs/architecture/decisions.md`](docs/architecture/decisions.md) keeps both
  the decision and what it replaced.
- Tests and reviews are Claude's as well. Neither one plays the game, which is
  where nearly every real bug here has turned up.
- The physics model and the numbers under it are inherited from Subspace
  Continuum and measured in [`docs/research/`](docs/research/README.md). They
  were not invented here by anyone.
- Vendored work keeps its own authorship: the fonts in `client/ui/`, the Defold
  engine template, and the skill in `.claude/skills/`. Licenses sit beside
  them.
