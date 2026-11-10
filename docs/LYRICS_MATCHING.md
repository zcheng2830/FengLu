# Lyrics Matching Rules

The acceptance rules `LyricsOnlineResolver` applies before an online result can
be shown, cached, or saved. The offline tests under `Tests/FengluPlayerTests`
are the executable form of these rules; run them with
`./script/test_lyrics.sh`. For source configuration and what gets written to
disk, see the [README](../README.md).

## Shazam

Shazam is opt-in: its song endpoint has returned unrelated fallback pages for
valid song URLs, so it is not in the built-in source list. A source list that
names `shazam` explicitly enables it. Saved lists are preserved as written,
including copies of an older default; only an absent configuration uses the
current built-in default. Logs identify the configuration origin, note when it
enables Shazam or has no online providers, and explain that providers from
newer defaults are not added to saved lists.

Shazam requires both a declared canonical/Open Graph track ID matching the
requested iTunes ID and a matching, complete `MusicRecording` anchored through
`mainEntity`, `mainEntityOfPage`, or its own page URL. Every independently anchored
recording must agree on the title, artists, and recognized track IDs. Conflicting
response, declared, or anchored recording IDs reject the page. A response URL
that merely echoes the request cannot supply the required page declaration.

Only usable lyrics attached to those validated recordings are returned. JSON-LD
script attributes may be quoted, unquoted, or minified. MIME comparison trims only
HTML ASCII whitespace (space, tab, LF, form feed, and CR); NBSP is not a delimiter.
HTML pages use [SwiftSoup](https://github.com/scinfu/SwiftSoup) 2.14.3 instead of a
regular-expression tokenizer. Metadata, script lookup, and lyric containers share
the parsed document. Comments, raw-text elements, and escaped script data follow
the parser's HTML rules; inert template content cannot supply identity or lyrics.
Script IDs are case-sensitive. A real script that reaches end-of-input may supply
a complete JSON payload, but truncated JSON is rejected. `recordingOf` may be an
object or array; its `lyrics` may be text, a text object, or an array of either.
Separate lyric entries remain separate candidates rather than being concatenated.
A result without complete identity, a recording anchor, or usable structured
lyrics is rejected so the other configured providers can continue.
There is no visible-page scraping fallback. Page headings do not establish or
veto identity, so localization, separators, and SEO suffixes no longer affect
acceptance. A usable structured excerpt may still be returned; metadata cannot
establish whether a lyric text is complete.

### Track IDs And HTML Handling

Track IDs are recognized in `/song/` and `/track/` URLs on `shazam.com` and its
subdomains, across locale prefixes and trailing slashes. Lookalike domain suffixes
are not trusted. Canonical link relations are read as whitespace-separated tokens.
Relative references resolve against the fetched response URL.
Fragment IDs alone do not anchor recordings; an explicit `mainEntity` reference
can identify a fragment-named recording. Structured URL fields may be strings,
ID objects, or arrays. Quoted, unquoted, and adjacent quoted HTML attributes are
supported, including quoted angle brackets and slash-introduced attributes.
An unterminated quoted attribute can absorb later apparent tags under HTML rules;
the resolver does not recover hidden declarations or scripts with a regex fallback.
Serialized JSON exposed as visible text is not saved as a plain lyric document.
JSON-LD traversals are capped at 32 levels; reaching that limit
rejects the page rather than trusting partially parsed identity evidence.

### Search Hits

Search hits must match complete normalized song identities before ranking.
Configured local aliases apply to both search and page validation. Artist-less
tracks always need a unique context winner with a score of at least 7 from
album, track number, and duration, even when iTunes returns just one matching ID.
A filename-only `Hello.mp3` cannot adopt the sole returned performer without
corroborating tags. Duplicate hits for the same ID are grouped; tied or weak
context is rejected. An empty title tag uses the filename for lookup and matching.

## Version Labels

Remaster labels are tolerated on either side. A local `Deluxe`/`Deluxe Edition`
label may match an unlabelled title. Recording/version labels such as live,
acoustic, demo, clean, explicit, radio edit, single/album version, and Taylor's
Version remain part of the identity on both sides, as do `Bonus Track` and
`From ...`. A labelled recording cannot silently match a studio/plain version;
configured aliases remain available for intentional metadata equivalences.
Featured-credit extraction preserves version suffixes. Bare `feat`/`ft` can be
interpreted after the whole title agrees with an explicit credit, preserving
literal titles such as “A Feat of Strength.”

## Artist Credits

Artist separators are parsed consistently across tags and search results, while
structured artist arrays retain their individual names. Every tagged primary
performer must be present; a solo credit cannot stand in for a duo or band.
A lead-only tag may match a larger iTunes credit led by that artist. Page credits
are then matched without relying on JSON-LD array order: every tagged primary
must remain, and every returned primary must be corroborated by the local tags
or selected iTunes credit. Extra performers introduced only by the page reject
the match in either order. Alias merging, lookup, search, parser checks, and
validation share normalization for case, diacritics, punctuation, and whitespace.

## Other HTML Providers

Other HTML providers keep a more tolerant title and artist match than Shazam,
including title-only metadata, version labels, featured credits, and
provider-specific heading suffixes. The strict Shazam gate does not apply to
these providers, but the following rules do:

- A title must match as whole words. One-word titles of any length ("Halo",
  "晴天") are accepted when they appear as a whole word; "Home" does not match
  "Homecoming".
- A candidate with no title match is accepted only when artist, album, and
  track number all match. A different artist needs a title match plus the album
  or a duration within 2 seconds.
- A Genius URL must contain the whole title as consecutive words plus the
  artist; the fetched page's own title is validated when present.
- DarkLyrics sections are matched by heading equality after the track number is
  stripped, and the page is validated against the album.
- Metal-Archives needs a strong title match; an artist match alone is not enough.
- Each candidate carries its match strength into cross-provider selection, which
  compares it before the synchronized bonus, so a weakly matched synchronized
  result cannot beat a title-matched one.
- An LrcAPI result array whose entries were all rejected yields no lyrics.
Visible lyric text excludes the document title. LetrasBoom treats `#lb-lyrics`
as the lyric boundary without searching its verses for headings or footer words.
Ad slots, controls, headers, structural headings, and definition lists are excluded;
exact artist-credit lines and recognized colon-labelled metadata are removed
without truncating the remaining verses. Stanza breaks and punctuation-only lines
are preserved, including when no artist tag is present. Legacy pages without that
container still need a matching body heading and stop at metadata labels, including labels
and values rendered in separate blocks. Header headings remain usable anchors
without including other header text. Sanitized captures of two real pages under
`Tests/FengluPlayerTests/Fixtures/LetrasBoom` pin the container structure; their
source URLs, capture hashes, and substitutions are documented beside the files.

## Shared Content Filter

Metal Archives uses fragment parsing only for search cells and full-page parsing
for lyrics responses. All online providers share the same lyric content filter.
It removes whole unavailable-lyrics lines and inline markers in balanced ASCII or
full-width brackets, including nested brackets. Stray brackets do not prevent
removal of separate complete markers. At the nesting limit, a flat scan still
removes complete markers without interpreting the remaining bracket structure.
Empty leftover openers are discarded. Only whitespace touching a removed marker
is adjusted: a single space is retained if the source had whitespace on either
side, except directly before closing punctuation. No separator is invented when
the source had none. Instrumental stage notes stay intact whether inline or on
their own line.

### Placeholder Minimum

When an unavailable marker or any whole-line placeholder is present (including an
instrumental note), at least four untouched content lines are required. Placeholder
and content classification use the same text after leading timestamps and tags;
those prefixes are preserved in the saved lyrics. A line that contained a removed
marker cannot contribute its retained text to that count, even if it contains verse
words. This deliberately rejects some short partial lyrics. Standalone placeholder
notes do not count as content. Content lines must also outnumber placeholder-bearing
lines. This rejects short or mostly unavailable
excerpts, including lists with only one label per unavailable or instrumental
movement. Removed lines leave blank separators, normalized to one stanza gap.
No free-text heading detection or movement grouping is used:
numbered verses, countdowns, and orphaned movement labels are preserved. This is a
conservative content minimum, not proof that every surviving line is a lyric; it
cannot identify arbitrary banner text and may reject short valid excerpts.

### Tags And Entities

Leading bracketed tags may contain spaces but cannot contain another opening
bracket. Section headers and LRC metadata stay out of the displayed lyrics and
content count, while unmatched bracketed lyric text is preserved. HTML entities
are decoded once by the HTML parser. JSON and LRC lyric
strings retain literal entity text, and shared candidate normalization does not
decode it again. Content is counted during filtering and reused for usability
and scoring. Shazam compares structured lyric lengths after whitespace cleanup;
Metal Archives search-cell whitespace is collapsed to a single space.

## Diagnostics

HTML and selector parser failures are logged with provider or selector context,
separately from missing or mismatched song metadata. Cell diagnostics include the
search URL and row.
