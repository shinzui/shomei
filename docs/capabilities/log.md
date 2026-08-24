# Bundle Update Log

## 2026-08-24

* **Addition**: Establish the capability bundle — CAP-1 through CAP-24 describe what Shōmei
  provides today across its eight packages, each with its compatibility promise, the packages a
  consumer depends on, evidence a reader can open, and a truthful `Limits` section.
* **Model**: Adopt the shared `coordination.capabilities` profile from
  [okf-profiles v0.9.0](https://github.com/shinzui/okf-profiles), pinned by Dhall semantic hash
  to match every other capability catalog in the portfolio. Provision claims only: absent
  capabilities stay in the improvement-request bundle, the two-tier authorization story with
  **en** is excluded as a composition claim, and there is deliberately no `planned` status.
* **Note**: Every record carries `since: unreleased` and `stability: experimental`, because the
  repository has never cut a tagged release. Both fields become informative at the first tag.
