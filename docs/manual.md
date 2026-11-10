# ETAF Org Preview manual

This manual covers the workflows a reader performs. The root entry's
Commentary owns the supported API inventory; this document links to it instead
of repeating signatures.

## Opening a document

| Entry point | Use |
| --- | --- |
| `M-x etaf-org-preview-open` | Render the Org file at point, or prompt for one |
| `(etaf-org-preview-open PATH)` | Render a known file |
| `etaf-org-preview-create` + `etaf-org-preview-view` | Build a session and mount it inside your own layout |

Opening a file that already has a preview selects that buffer instead of
rendering it twice. The buffer name is `*ETAF Org: NAME*`.

`etaf-org-preview-open` also accepts a session, so an application can build
the document model first and display it later.

Closing with `q` unmounts the runtime, removes the file watch and kills the
buffer.

## Keys

| Key | Action |
| --- | --- |
| `C-c TAB` | Fold or unfold the section around point |
| `C-c f` | Switch between the outline (headlines only) and the full document |
| `C-c n` / `C-c p` | Next / previous visible headline (`n` also works) |
| `C-c j` | Choose a headline from the completion list |
| `RET` or click | Activate a link, a footnote, an image; fold a headline |
| `C-c C-o` | Activate the control at point |
| `C-c t` | Show or hide the table of contents |
| `C-c v` | Show or hide comments, properties, drawers and metadata lines |
| `t` | Switch to the next fixed palette |
| `[` / `]` | Narrow / widen the reading measure by four cells |
| `r` | Re-read and repaint the document |
| `C-c h` | Show the effective key bindings |
| `q` | Close the preview |

`TAB`, `S-TAB`, `?`, `SPC`, `DEL`, `C-v`, `M-v`, the wheel and `n`/`q` are
framework-owned keys. An application cannot rebind them, which is why folding
sits on `C-c TAB` and the outline switch on `C-c f`. Native search, marks,
windows and scrolling work unchanged.

## Folding

Every headline has three states:

| State | Shows |
| --- | --- |
| `folded` | The headline row only |
| `children` | The headline row and its child headlines, no body |
| `open` | The headline, its body and its children |

`C-c TAB` cycles `folded → children → open → folded`; a headline without
children skips `children`. Entering `children` closes the whole subtree, and
each child headline can then be opened on its own. `C-c f` switches the whole document between the
outline and the full view.

Folding is structural. A closed section is not rendered, so its images are
not prepared, its tables are not measured and its blocks are not mounted.
That is what keeps a large file fast: a 120-section document mounts in about
120 ms as an outline and about 350 ms fully expanded.

A document opened from a file follows that file. Saving the source, or
changing it on disk, repaints after the write settles (250 ms) and keeps the
reader in the section it was reading. `r` reloads on demand.

## Syntax coverage

### Document

| Org syntax | Rendering |
| --- | --- |
| `#+TITLE`, `#+SUBTITLE` | Title block |
| `#+AUTHOR`, `#+DATE` | Metadata line; a file session appends the modification time |
| `#+KEYWORDS`, `#+FILETAGS` | Tag chips under the metadata line |
| `#+TODO:`, `#+SEQ_TODO:`, `#+TYP_TODO:` | Keyword set and its state colors |
| `#+PRIORITIES:` | Priority range |
| `#+OPTIONS: toc:n` | Table-of-contents depth; `toc:nil` hides it |
| `#+OPTIONS: tags:nil todo:nil pri:nil` | Hides tags, keywords or priorities |
| `#+STARTUP: overview\|content\|folded` | Initial fold state |
| `#+MACRO:` | Inline macro expansion, including `title`, `author`, `date`, `email` and `input-file` |
| `#+LINK:` | Link abbreviations |
| `#+CAPTION:`, `#+NAME:`, `#+ATTR_*:` | Attached to the next block; the caption renders under it. `:width` and `:height` (pixels or a percentage) cap an image, `:alt` becomes its help text |
| `#+RESULTS:` | A result card |
| `#+INCLUDE:`, `#+CALL:`, dynamic blocks | Cards that name what was not executed |
| `#+TBLFM:` | A grey footnote under its table |
| Other `#+KEY:` lines | Hidden by default, shown with `C-c v` |

A document without `#+TITLE` uses its file name, then the session title.

### Headlines

| Org syntax | Rendering |
| --- | --- |
| `*` … `********` | Four heading sizes, then bold with a small indent |
| `TODO`/`DONE`-style keywords | A chip; `NEXT`/`STARTED` read as in progress, `WAIT`/`HOLD` as waiting, `CANCELLED` as dropped |
| `[#A]` priority | A thin outlined chip |
| `:tag:list:` | Right-aligned chips |
| `[2/5]`, `[50%]` cookie | A monospace pill |
| `COMMENT` | A “注释” chip and a folded start |
| `:ARCHIVE:` tag or property | An “归档” chip and a folded start |
| `SCHEDULED:`, `DEADLINE:`, `CLOSED:` | A planning line with written labels and dates |
| `:PROPERTIES:` | A chip with the entry count; `C-c v` shows the properties grid |
| `LOGBOOK` clock entries | A chip with the entry count and total time; `C-c v` also shows the recorded lines |
| Other drawers | A named chip; `C-c v` shows the drawer text, so no content disappears |

### Body

| Org syntax | Rendering |
| --- | --- |
| Paragraph | One wrapped paragraph; adjacent CJK lines join without a space |
| `-`, `+`, `*` lists | Bullets, nested with two extra cells per level |
| `1.`, `1)` lists | The original numbers, right-aligned |
| `[@3]` | Overrides the displayed number |
| `[ ]`, `[-]`, `[X]` | Three marks: an empty box, a dashed box for a task in progress, and a check |
| `- term :: description` | Term, a faint `::`, then the description |
| Tables | Full grid, so rows and columns both carry rules; header rule, alignment and width cookies, `<n>` minimum widths; a wide cell wraps inside its column instead of overflowing |
| Multi-rule tables `|---` | One separator per rule row |
| `#+BEGIN_SRC` | A code card with its language; the `-n` and `-n 20` switches add a line-number gutter |
| `#+BEGIN_EXAMPLE` | A code card without a language |
| `#+BEGIN_QUOTE` | An indented quote with a trailing `-- author` line |
| `NOTE`, `TIP`, `IMPORTANT`, `WARNING`, `CAUTION` | A callout with a written label and its semantic color |
| Other special blocks | A card with the block name |
| `#+BEGIN_CENTER` | Centered content capped at 80% of the measure |
| `#+BEGIN_VERSE` | Line breaks kept |
| `#+BEGIN_COMMENT` | Hidden by default |
| `#+BEGIN_EXPORT` | A card labeled with its backend |
| `# comment` lines | Hidden by default |
| `: fixed width` | Monospace text |
| `-----` | A hairline divider |
| LaTeX environments and `\[ … \]` / `$$ … $$` | Centered monospace source with entities substituted |

### Inline

| Org syntax | Rendering |
| --- | --- |
| `*bold*`, `/italic/`, `_underline_`, `+strike+` | The matching face |
| `=verbatim=`, `~code~` | Monospace with a soft background |
| Entities (`\alpha`, `\to`) | Unicode spelling from Org's own table |
| `H_2`, `x^2` | Unicode sub- and superscripts; an unmappable value keeps its marker |
| `[[target][description]]` | An underlined accent link inside the paragraph |
| Bare URLs | Links |
| Timestamps | Date, Chinese weekday and time; active and inactive differ in color |
| `[fn:1]`, `[fn::text]` | A numbered reference set smaller than the paragraph; the footnote is listed at the end |
| `[cite:@key]`, `[@key]` | Monospace citation text |
| `{{{macro}}}`, `{{{title}}}` | Expanded |
| `src_py{…}` | Monospace with a soft background |
| `@@html:…@@` | Its payload in source style; the backend marker is removed and the payload is never interpreted |
| `<<target>>`, `<<<radio>>>` | The definition is a quiet anchor; a reference is link text that jumps to it |
| `\\` | A line break |

## Links

| Target | Activation |
| --- | --- |
| `https:`, `http:`, `mailto:` | System browser or mail client |
| `file:path` | `.org` files open a preview, images and videos open outside Emacs, other files use `find-file` |
| `file:path::*Headline`, `::#custom-id` | Reveal and jump to the anchor in this document |
| `*Headline` | Jump to the headline |
| `#custom-id` | Jump to the section with that `CUSTOM_ID` |
| `id:uuid` | Resolved through Org when it is loaded |
| `attachment:file` | Treated as a file relative to the document |
| `elisp:`, `shell:` and unknown schemes | Reported as not activatable; nothing runs |

Folded ancestors are opened before a jump, and the target is centered.

## Media

A paragraph that holds a single link to a local image becomes an image card:
the picture is centered, sized from its own pixels and the reading measure,
capped by `etaf-org-preview-image-max-height`, with its `#+CAPTION:` below.
`RET` opens the file.

A local video link becomes a card that names the file and opens it with the
system player. A missing file, or a remote URL, keeps a placeholder card that
shows the path or URL instead of failing.

## Display controls

| Control | Effect |
| --- | --- |
| Palette | `t` cycles `light`, `sepia`, `dark`; `etaf-org-preview-set-theme` accepts `auto` to follow the frame's faces again |
| Reading measure | `[` and `]` change the maximum; a resize refits the measure, a narrower window fills the available columns, and below the preferred minimum the page keeps reflowing instead of scrolling sideways |
| Table of contents | `C-c t`; depth comes from `#+OPTIONS: toc` (default 2) |
| Hidden content | `C-c v` reveals comment lines, comment blocks, property drawers, other drawers, logbook lines and metadata keywords |

`auto` paints no page background, so the preview uses the Emacs theme's own
background. A fixed palette paints its own page, and every surface — chips,
tables, callouts, code cards — comes from the same palette.

## Degraded content and recovery

Parsing never signals on malformed input. An unclosed block ends at the end of
its container, an unknown construct keeps its source text, and every
degradation is counted. When the count is not zero, the title block shows a
“N 处已降级” chip.

Unsupported constructs are shown as source rather than as an error:

- `#+INCLUDE:` is not expanded; the card names the file.
- `#+CALL:` and dynamic blocks are not evaluated; the card says so.
- `#+TBLFM:` is not computed; the formula is a footnote.
- `elisp:` and `shell:` links never run.

## Sessions and scripting

```elisp
(let* ((session (etaf-org-preview-create :file "~/notes.org"
                                         :theme 'dark
                                         :startup 'overview))
       (state (etaf-org-preview-state session)))
  (plist-get state :counts)   ; (:todo 3 :done 8 :deadline 2 :overdue 1)
  (etaf-org-preview-fold-all session 'open)
  (etaf-org-preview-refresh session))
```

`etaf-org-preview-create` takes `:file` or `:text`, plus optional `:title`,
`:theme`, `:startup` and `:toc`. A read failure signals
`etaf-org-preview-error`; `etaf-org-preview-refresh` keeps the last good
document when a reload fails.

Mount a session yourself with `etaf-org-preview-view`:

```elisp
(etaf-mount buffer (etaf-org-preview-view session)
            '(:viewport-width 900 :viewport-height 50))
```

`etaf-org-preview-locate` jumps to an outline entry, `etaf-org-preview-outline`
returns `(LEVEL TITLE ID TODO TAGS)` rows, and `etaf-org-preview-state` reports
the whole session as detached data.

## Diagnostics

`M-x etaf-org-preview-doctor` reports whether Org and ffmpeg are available.
Neither is required: Org improves `id:` links and keyword defaults, ffmpeg
only matters for video previews.
