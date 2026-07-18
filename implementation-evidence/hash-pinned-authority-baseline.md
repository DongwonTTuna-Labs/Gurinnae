# Hash-pinned authority baseline

## 2026-07-15 independent re-verification

The sole archive was freshly extracted again and verified without consulting an
older Gurinnae package. The archive SHA-256 was
`960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`.

- Validator image manifest:
  `sha256:0d1da2e7bca152ed01024b010dd7f580c42517275cd3ffe7f4927d5fc16023c3`
- Validator runtime: CPython `3.13.5`, `pglast 7.11`, Poppler
  `pdftotext/pdftoppm 25.06.0`, and Tesseract `5.5.0`.
- English traineddata SHA-256:
  `7d4322bd2a7749724879683fc3912cb542f19906c83bcc1a52132556427170b2`.
- Korean traineddata SHA-256:
  `6b85e11d9bbf07863b97b3523b1b112844c43e713df8b66418a081fd1060b3b2`.
- `requirements-spec.txt` SHA-256:
  `dc8b86f52473533e33e00c9f5456d3996537d9a1f6cc6a9e29256dbbbff273dc`;
  `pip check` returned no broken requirements.
- Strict validator: `warnings: 0`, `errors: 0`, `RESULT: PASS`.
- `MANIFEST.sha256`: `1,230/1,230` entries PASS, with no symlinks.
- Authority tree before and after validation:
  `3136450c3d01f950e123ab52813c3992cd7239f1e691166e6694669cffe13f98 1230`.

The PostgreSQL verifier used Node `24.16.0` from the immutable image
`sha256:2c87ef9bd3c6a3bd4b472b4bec2ce9d16354b0c574f736c476489d09f560a203`.
It ran in an ephemeral root-capable container because the authority's
`embedded-postgres` configuration creates an isolated `postgres` OS user.
The pinned CPython validator performed the baseline comparison.

- PostgreSQL `18.4`; migrations `24/24`.
- Tables `107`, functions `72`, triggers `37`, RLS policies `5`.
- Optimistic-concurrency contracts `64/64`.
- Named canaries `69/69`; expanded assertions `133/133`.
- Baseline comparator: `result: PASS`.
- Captured runtime evidence:
  `implementation-evidence/authority-postgres-runtime-v13-20260715.json`,
  SHA-256
  `15d765e4281fd0719c84fb97d970bcb2b447a671b91aecf902f2a50a4a32fde6`.

This re-verification proves only the immutable authority baseline. It does not
prove that the additive product design or the current implementation tree is
complete.

Verified at 2026-07-14 UTC from a fresh extraction of the sole authority archive.

## Immutable inputs

- Authority archive SHA-256: `960687b445edee3b8fbf7186152cc9a53d835ca8ba55eb49dd957424142802e5`
- Authority validator image ID: `sha256:980bff769dffbe82263682ff4f0b23c7a5cbd8d59205b6817d596ef608e1a10f`
- Validator runtime: CPython `3.13.5`; the image installs `requirements-spec.txt` with `pip --require-hashes`.
- PostgreSQL verifier image ID: `sha256:2c87ef9bd3c6a3bd4b472b4bec2ce9d16354b0c574f736c476489d09f560a203` (Node `24.16.0`).
- PostgreSQL verifier lock SHA-256: `1b955a86fd2e954fecacf0e7a1c5bea8f6824112b76e21cf885f831596d0da1c`.
- Installed PostgreSQL 18.4 binary SHA-256: `de0a4a7646c51f032e0088ae6fe9d0833fa280b78d4455681574a32937b32838`.

Images were invoked by immutable image ID, not a mutable tag. PostgreSQL verification ran in the root-capable pinned Node container because the authority verifier intentionally creates an isolated `postgres` OS user. Static validation and comparison ran in the pinned CPython image.

## Authority integrity result

- Strict authority validator: `warnings: 0`, `errors: 0`, `RESULT: PASS`.
- `MANIFEST.sha256`: 1,230/1,230 entries PASS.
- Authority tree digest before and after verification: `3136450c3d01f950e123ab52813c3992cd7239f1e691166e6694669cffe13f98 1230`.

## PostgreSQL runtime baseline

- PostgreSQL version: `18.4`.
- Clean migrations: 24/24.
- Active tables: 107.
- Active first-party functions: 72.
- Triggers: 37.
- RLS policies: 5.
- Optimistic-concurrency contracts resolved: 64/64.
- Named runtime canaries: 69/69 PASS.
- Expanded runtime assertions: 133/133 PASS.
- Baseline comparator: `result: PASS`.

This proves only the immutable v13 authority baseline. The owner-addendum application, five additive migrations, final 187-table runtime, and complete source-tree hard gates require separate final evidence.
