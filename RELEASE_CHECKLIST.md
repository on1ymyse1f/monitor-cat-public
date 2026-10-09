# Public release checklist

This checkout contains a sanitized, single-commit release snapshot. The
original development refs are intentionally not part of the public snapshot;
they contain old local usage measurements and machine-specific paths.

Before publishing:

1. Review `THIRD_PARTY_NOTICES.md` and remove or replace character-inspired
   artwork if the intended distribution is not covered by the applicable fan
   content rules.
2. Build the macOS release and Windows package from this snapshot. Keep the
   unsigned artifacts marked as development builds until signing and
   notarization are complete.
3. Create or select the GitHub repository, push this branch as its default
   branch, and set the repository visibility explicitly.
4. Enable private vulnerability reporting if the repository will accept
   security reports through GitHub's Security tab.
5. Add release checksums and signed artifacts before calling a binary a public
   release.

The local branch can be published as the repository's `main` branch with:

```bash
git push origin open-source-release:main
```

Run that command only after reviewing the repository visibility and the
third-party notice. The command is deliberately not run by this project
checkout.
