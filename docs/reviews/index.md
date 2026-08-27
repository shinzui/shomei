---
okf_version: "0.2"
---

# Shōmei Reviews

This bundle records commit-pinned reviews of Shōmei artifacts under the shared
[`assurance.reviews`](mori://shinzui/okf-profiles/profiles/reviews) profile. Each review is one
examination of one subject at one immutable commit. Findings that need action belong in the
owning bug-report or improvement-request bundle; the review records what was examined and its
outcome.

## Files

- [`profile.dhall`](profile.dhall) pins the published shared profile.

## Authoring a review

Allocate the next stable handle before adding a review document:

```sh
okf id list docs/reviews --profile docs/reviews/profile.dhall
okf id next docs/reviews --profile docs/reviews/profile.dhall REV
```

Use the most specific canonical `mori://` URI available for `subject`, record a full 40-character
`reviewedSha`, and state whether the review covered the full subject or only an incremental range.
An incremental review also records `baseSha` and should link `previousReview` so the review history
forms a chain.

After adding or changing a review, update [`log.md`](log.md) and run:

```sh
just reviews-validate
```

## Reviews

No reviews have been recorded yet.
