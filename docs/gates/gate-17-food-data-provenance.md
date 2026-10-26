# Gate 17 — Food Data Provenance and Import

Status: NOT RUN — evaluated by GitHub Actions on the implementation SHA.

The gate builds temporary development and production SQLite catalogs with the
real importer and verifies the shipped row set against pinned manifests.

Required evidence:

- every production food and recipe row has source ID, source record ID, source
  version, and verified redistribution status;
- unverified legacy food rows remain excluded from the production database;
- the verified food bundle contains exactly the pinned USDA records;
- missing, null, empty, dash, and trace energy values are rejected, while an
  explicitly recorded numeric zero remains distinct;
- IDs and production aliases are unique, and each row preserves raw source
  metadata, energy units, edible/cooked mass basis, and per-100 g basis;
- the recipe catalog has at least 100 unique canonical records from the pinned
  HowToCook Unlicense commit, with ingredient quantity evidence and an explicit
  rejection report for records the importer cannot parse;
- recipe import reports preserve excluded note/equipment lines with their source
  record path and review reason, and grouped ingredient labels are split only at
  explicit enumeration punctuation; uncertain alternatives remain source text;
- plainly positioned quantities in ingredient bullets are separated into
  source-unit evidence; compound amounts, embedded notes, or ambiguous ingredient
  labels remain verbatim as text-only evidence and are listed for review, with no
  conversion to user-consumed grams;
- multiple source quantity lines remain verbatim as text-only evidence and are
  listed for review instead of being reduced to the first numeric amount.

The validator reports evidence about the packaged data and importer behavior;
it does not establish the nutritional accuracy of USDA data for Chinese dishes.
