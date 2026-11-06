# Gate 17 — Food Data Provenance and Import

Status: NOT RUN — evaluated by GitHub Actions on the implementation SHA.

The gate builds temporary development and production SQLite catalogs with the
real importer and verifies the shipped row set against pinned manifests.
It also fetches the exact HowToCook commit from the recipe source manifest,
regenerates both `recipe_priors.json` and its import report with the production
importer, and byte-compares the generated artifacts to the shipped files. A
network/fetch/import error or any mismatch fails Gate 17 and uploads a report
with both artifact hashes.

Required evidence:

- every production food and recipe row has source ID, source record ID, source
  version, and verified redistribution status;
- unverified legacy food rows remain excluded from the production database;
- the verified food bundle contains exactly 24 pinned USDA records and 979
  Taiwan FDA records regenerated from the pinned archive;
- the Taiwan FDA archive has the pinned SHA-256 and source release metadata,
  and its OpenCC build-time dependency is installed from the vendored,
  SHA-256-pinned wheel before importer reproduction;
- Taiwan FDA canonical names and raw source records retain their Traditional
  Chinese values. The pinned OpenCC `t2s` transform adds Simplified Chinese
  search aliases; aliases that collide with a canonical name or another food
  are omitted and enumerated in the alias review report. This import attaches
  1,144 converted aliases and sends 319 conflicting converted aliases to
  review;
- the Taiwan FDA importer accepts records only when energy is numeric and
  within 0–1000 kcal/100 g, source metadata and nutrient rows do not conflict,
  a source waste rate is present in 0–100%, and the Integration number can be
  mapped to a stable catalog ID. The pinned release has 2,116 grouped foods:
  979 accepted and 1,137 excluded for missing or invalid waste rate;
- Taiwan FDA nutrients are retained as analyzed per 100 g of edible portion.
  Waste rate is kept as edible percentage and is not deducted from those
  values; it is used only when scaling an as-purchased portion. Preparation is
  kept as raw, cooked, or unknown, and unknown state is represented with an
  as-purchased mass basis;
- missing Taiwan FDA nutrient values remain null. In the pinned release,
  dietary fiber is absent for 344 accepted foods; the importer never fills
  missing energy with zero;
- missing, null, empty, dash, and trace energy values are rejected, while an
  explicitly recorded numeric zero remains distinct;
- every input row must declare an energy unit and per-100 g nutrient basis;
  verified food rows must have consistent preparation/mass-basis semantics,
  and duplicate source-record identities are rejected;
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

The Taiwan FDA archive and source rows are reproducible from the pinned release;
the USDA archives are not bundled, so the gate does not independently
recompute their nutrient values. Provenance checks do not establish that a
source sample is the best nutritional match for every user-described food.
