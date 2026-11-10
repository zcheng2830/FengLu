# Captured LetrasBoom structures

These fixtures come from public song pages fetched on 2026-11-03. They preserve
real page structure rather than modelling an assumed layout. The original raw
responses stay outside the repository; hashes identify the exact captures.

| Fixture | Source | Raw response SHA-256 | Verse paragraphs |
| --- | --- | --- | --- |
| `snow-on-the-beach.html` | [Snow On The Beach](https://www.letrasboom.com/letra/snow-on-the-beach-taylor-swift) | `980a0901d5f92cd88d0cdfecfe8ed48778fb11d30e0cf7a2a87c62f6169e1d8f` | 69 |
| `more-lana-version.html` | [More Lana Del Rey Version](https://www.letrasboom.com/letra/snow-on-the-beach-more-lana-del-rey-version-taylor-swift) | `0674ecc093e0fff2099732410ee900671263ab7baf4540ea5f6487db17edd67f` | 61 |

Sanitization retains each captured `main` subtree, including its headings,
controls, lyric card, ad slots, comments section, related content and Q&A layout.
All element names, IDs, classes, and their nesting/order remain unchanged from
the captured DOM. The title, title metadata, and canonical URL are retained in a
small document wrapper. Serialization normalizes attribute quoting and HTML
formatting; these are DOM captures, not byte-for-byte copies of the responses.

Every original verse is replaced with a numbered synthetic sentence. The number
and order of verse paragraphs and stanza breaks are retained. Other visible
prose is replaced with `Fixture surrounding content`; script/style bodies and
comments are removed. Resource URLs, inline handlers/styles, and payload-bearing
attributes are removed. Structural attributes (`id`, `class`, `role`, schema
attributes, `aria-hidden`, `type`, and `data-lb-lyrics`) remain. No original lyric
text or executable tracking content is committed.

Both captures place the verses in
`main.lb-main > section.lb-card.lb-lyriccard > div#lb-lyrics.lb-lyrics.lyricbody`.
The song heading is outside that div. Two ad wrappers inside it use
`.lb-adslot.lb-adslot--lyric.lb-noprint`; the page's metadata and recommendations
are outside it. The integration tests compare the complete extracted text,
including blank lines, against an expectation derived from the captured DOM
rather than the production renderer. Each verse paragraph is one line. Both
captures have nine explicit `<br>` nodes after verse paragraphs 8, 16, 20, 28,
36, 40, 45, 53, and 59, and no empty verse paragraphs. Those nodes separate ten
stanzas with one blank line between them. The final stanza ends at verse 69 or
61 respectively. The ad wrappers after verses 20 and 53 contribute neither text
nor additional stanza breaks. This exact comparison also rejects surrounding
content, lost stanza breaks, extra blank lines, and leading/trailing whitespace.
