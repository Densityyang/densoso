# `cn-food-mcp` source candidate disposition

**Reviewed:** 2026-10-28
**Disposition:** Candidate only; excluded from Densoso's production food catalog.

## Scope and evidence

This is a read-only review of the public [`ruffood/cn-food-mcp` repository](https://github.com/ruffood/cn-food-mcp). No candidate CSV, converted JSON, or package data was copied into Densoso.

- The [README](https://github.com/ruffood/cn-food-mcp/blob/main/README.md) describes approximately 1,725 foods and 25 nutrients per 100 g, and its License section says MIT.
- [`package.json`](https://github.com/ruffood/cn-food-mcp/blob/main/package.json) also declares `"license": "MIT"` for the package. The repository root listing has no standalone `LICENSE` file; in any case, these declarations identify the package/code license, not the rights to the nutrition records.
- The repository includes [`data2026.csv`](https://github.com/ruffood/cn-food-mcp/blob/main/data2026.csv), but the README does not identify the dataset publisher, original source, release, row-level source IDs, or a data license. [`DESIGN.md`](https://github.com/ruffood/cn-food-mcp/blob/main/DESIGN.md) refers to an Excel source/import but likewise supplies no provenance or redistribution terms. The checked-in converter maps CSV columns into JSON without adding source provenance.
- The Densoso food manifest at `Densoso/Resources/FoodData/sources.json` identifies the old 31-row seed as `legacy-china-food-seed`, explicitly unverified and non-redistributable. Nothing reviewed establishes that `cn-food-mcp` is that seed's origin or resolves the seed's provenance gap.

The links above point to the mutable `main` branch. No immutable upstream commit or dataset checksum is recorded in Densoso's source manifest, so this review is not a reproducible row-level data audit.

## Decision and blockers

Do not copy or bundle `data2026.csv` (or a derived catalog), mark its records verified, or use the MCP service as a production nutrition source on the evidence reviewed. MIT for the MCP package does not establish permission to redistribute its embedded third-party data. Treat the repository as a research lead only; this disposition does not change the status of the existing legacy seed.

Reconsider only after the dataset publisher/rights holder and exact source release are identified, a compatible data-redistribution license or written permission is documented (including attribution and derivative/share-alike terms), and an immutable commit plus source-file checksum can be pinned. Then perform a row-level audit of IDs, units, preparation/edible basis, and missing-value semantics before any import. If only hosted-service access is proposed, separately review its API terms, availability, and data handling; that would not authorize bundling the CSV.
