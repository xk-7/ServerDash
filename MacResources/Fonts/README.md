# ServerDash macOS fonts

These static TrueType fonts are bundled only with the macOS application.

- Outfit SemiBold, Bold, and ExtraBold are from the official
  [Outfitio/Outfit-Fonts](https://github.com/Outfitio/Outfit-Fonts) repository,
  commit `902773808eb372f70fb34e8946dd1ffe604efc79`. The family is licensed
  under the SIL Open Font License 1.1 in `Outfit-OFL.txt`.
- Plus Jakarta Sans Regular and Medium are from the official
  [tokotype/PlusJakartaSans](https://github.com/tokotype/PlusJakartaSans)
  repository, commit `18d1cd2f7ea10481919d2f05c1f7064b7307fc26` (2.7.1
  static TTF output). The family is licensed under the SIL Open Font License
  1.1 in `PlusJakartaSans-OFL.txt`.

The application registers these fonts for its process at runtime. Text whose
glyphs are absent from the bundled Latin families, including Chinese text,
continues through the normal macOS fallback cascade.

## SHA-256

| File | SHA-256 |
| --- | --- |
| `Outfit-SemiBold.ttf` | `bf2e1d2a6ec2a67952e8b36edd2b2bb9f340c0cdd10b0ad5145b4dbbc1339608` |
| `Outfit-Bold.ttf` | `f620b69582e06d7e1b3bbde74ed8c5876eadabb038390780db2a3414a1490197` |
| `Outfit-ExtraBold.ttf` | `0f028cbdc61a588bc44fef911e8d2bcfc0bc05b241a9b797686024d269d964b6` |
| `PlusJakartaSans-Regular.ttf` | `bd6276d4060e3b1ebc45047469e0bb86b08f301ba681cdf1ceb6245ea10478d2` |
| `PlusJakartaSans-Medium.ttf` | `c77bab757d7402ec6d9341d5f7ddaafb2474e17026792697ba4624c7dc89caf7` |
| `Outfit-OFL.txt` | `c676351bf8576b9aba743cd5eaa8c0e7ee0d51f805d720447b4df4ddb6a2e416` |
| `PlusJakartaSans-OFL.txt` | `995c7199cab65954f545996326755daee7b63cc6b42b06c13da1f9502ab08a99` |
