# Teafair Official Design Specification

Brand and interface tokens for Teafair, from the Teafair emblem
(`assets/branding/teafair-logo.png`, §0). This file is
the single source of the values. `docs/spec-b-client.md` §4 is the contract
that uses them (layouts, components, skeletons), and
`src/shared/tokens/` (Spec B) is the only code that holds them.

The app is styled with **NativeWind** in two layers:

1. **Primitives** (`teafair-*`, §1): fixed colours with no meaning.
2. **Semantic tokens** (§3): what components use. Each resolves to a
   primitive per theme.

**Components and screens use semantic classes only.** No hex, `rgb()` or
`hsl()` literals, no stock Tailwind palette classes (`emerald-500`,
`slate-900`, …), and no `teafair-*` primitive class outside
`src/shared/tokens/` and the emblem component. `tokens.guard.test.ts` and
ESLint enforce it.

## 0. The emblem

**Canonical asset:** `assets/branding/teafair-logo.png` (381 × 381 px,
32-bit RGBA, transparent outside the seal). Every use of the logo (the app's
emblem component, the splash, the app icon, TeafairWeb) derives from this
file. No one redraws it in code, and nothing recolours it.

**Vector draft:** `assets/branding/teafair-logo.svg` (382 × 383, `viewBox`
set, transparent outside the seal). It is a VTracer auto-trace, recoloured
to the emblem colours below. It is not the master yet: see "The two files"
at the end of this section.

**Its marks:**
- a scalloped outer seal in green;
- a thin green inner ring;
- a white field;
- a single leaf rising from a black `TF` monogram whose `T` sweeps into
  the leaf's stem.

**Its colours.** They are artwork colours, not UI tokens:

| Part | PNG (sampled) | SVG (set) | Note |
|---|---|---|---|
| outer scalloped seal | `#52801D` | `#52801D` | 4.70:1 on white |
| inner ring | about `#74A83A`, 3 px at radius 156 | `#70B123`, a 3 px circle at radius 156 | |
| leaf | `#70B123` | `#70B123` | 2.62:1 on white: never UI text |
| `TF` monogram | `#000000` | `#0C0C0C` | |
| field | `#FFFFFF` | `#FFFFFF` | |
| outside the seal | transparent | transparent | the scallop gaps too |

The UI primitive `teafair-leaf` (`#629E28`, §1) sits between the logo's
leaf and its seal. It is the emblem's green, darkened so it can carry ink
text (5.48:1) and pass as a 3:1 mark. The logo's own greens stay in the
artwork.

**Usage:**
- **Shape:** always the whole seal, square, never stretched, cropped,
  rotated or outlined.
- **Clear space:** at least one eighth of the seal's diameter on every side.
- **Size:** at least 32 dp; 24 dp only in the tab bar.
- **Background:** the seal sits on white, canvas, botanical or ink, never
  on leaf, amber or a photograph.
- **Where it appears:** only in brand moments (§4: sign-in, splash, empty
  states, the app icon) and the shell header. Never inside a list, a form or
  a workflow.

**The two files (2026-11-27).**

- **The PNG is transparent now.** The opaque black corners and scallop gaps
  are gone, so the emblem sits on white, canvas, botanical or ink. Two
  limits remain:
  - **A dark fringe:** a few edge pixels keep the old black background,
    most visibly at the top centre of the seal (about 100 px). They show as
    a faint dark fleck on white and canvas. A clean re-export removes them.
  - **Its size:** at 381 px it is sharp up to about 125 dp at 3× density.
    That covers every in-app size, but not the splash or the 1024 px app
    icon.
- **The SVG has the right colours but not yet the right drawing.** These
  changes were made:
  - the seal went from `#211F1F` to `#52801D`;
  - the field went from `#FDFDFD` to `#FFFFFF`;
  - the leaf went from `#71B029` to `#70B123`;
  - the monogram went from `#030303` to `#0C0C0C`;
  - a grey `#E5E5E5` bevel inside the seal became white;
  - the missing inner ring was added as one circle matching the PNG;
  - a `viewBox` and a title were added.

  The leaf and the monogram need vector cleanup. They were traced from a
  different version of the artwork than the PNG:
  - the leaf is larger, and its tip comes within 5 px of the inner ring;
  - a flat green bar stands left of the `T` in place of the PNG's stem
    swoosh;
  - the `TF` sits lower;
  - the traced curves are stepped, and the artboard is 382 × 383, not
    square.

  It becomes the master once those two marks are redrawn from the source
  artwork to match the PNG on a square artboard. Its monogram colour is
  then settled as either `#000000` or `#0C0C0C`. Recolouring alone cannot
  fix them.
- **Until then,** the PNG is the reference for the marks and the file the app
  renders. The SVG is not used anywhere.

## 1. Primitives: the emblem palette and the status colours

| Primitive | HEX | Role |
|---|---|---|
| `teafair-leaf` | `#629E28` | primary leaf green: actions, selection, progress, brand marks |
| `teafair-botanical` | `#1B3624` | secondary botanical dark: strong actions, headers, dark surfaces |
| `teafair-amber` | `#D97706` | accent: warnings, the one highlight on a screen |
| `teafair-canvas` | `#F4F6F9` | app background |
| `teafair-white` | `#FFFFFF` | surfaces, cards, sheets |
| `teafair-scrim` | `#111827` at 35% opacity | modal and sheet overlay |
| `teafair-ink` | `#0F172A` | primary text; the dark canvas |
| `teafair-slate` | `#64748B` | secondary text; control borders |
| `teafair-mist` | `#E2E8F0` | hairlines; muted text on dark |
| `teafair-red` | `#B91C1C` | danger on light themes |
| `teafair-red-soft` | `#F87171` | danger on the dark theme |
| `teafair-red-tint` | `#FEF2F2` | danger subtle background (light themes) |
| `teafair-blue` | `#0369A1` | info on light themes |
| `teafair-sky` | `#38BDF8` | info on the dark theme |
| `teafair-blue-tint` | `#F0F9FF` | info subtle background (light themes) |

The previous palette is retired. These names replace `teafair-emerald`,
`-lime`, `-forest`, `-black`, `-surface` and `-darkSurfaceEnd`, and nothing
may use the old names.

## 2. Contrast (WCAG 2.1, measured)

Text needs 4.5:1. Large text (18 px bold or 24 px) and non-text marks
(icons, borders, focus rings, indicators) need 3:1.

| Foreground on background | Ratio | Allowed for |
|---|---|---|
| ink on white / on canvas | 17.85 / 16.49 | all text |
| slate on white / on canvas | 4.76 / 4.40 | text on white; on canvas only 14 px semibold or larger |
| white on botanical | 13.13 | all text (the default primary button) |
| ink on leaf | 5.48 | all text on a leaf fill |
| white on leaf | 3.26 | large text and marks only |
| ink on amber | 5.60 | all text on an amber fill |
| white on amber | 3.19 | never for text |
| red on white / on canvas / on red-tint | 6.47 / 5.98 / 5.91 | all text; white on red is 6.47 |
| blue on white / on canvas / on blue-tint | 5.93 / 5.48 / 5.57 | all text; white on blue is 5.93 |
| canvas on ink / on botanical | 16.49 / 12.12 | dark theme text |
| mist on ink / on botanical | 14.48 / 10.65 | dark theme muted text and control borders |
| red-soft on ink / on botanical | 6.45 / 4.75 | dark theme danger |
| sky on ink / on botanical | 8.33 / 6.13 | dark theme info |
| leaf on botanical | 4.03 | dark theme marks and large text |
| mist on white | 1.23 | separators only, never a control boundary |
| amber on canvas | 2.94 | never: warning marks sit on white (§3) |
| slate on botanical | 2.76 | never: dark-theme neutral marks are mist (§3) |
| red / blue on ink | 2.76 / 3.01 | never: the dark theme uses red-soft and sky |

`tokens/contrast.test.ts` holds every pair a theme uses, with its minimum,
and fails on any pair below it.

## 3. Semantic tokens per theme

Three themes. The role default applies until the user chooses (Spec B
§4.2, `usePrefsStore`):

- **`standard`:** the default for operational and tenant roles: ZSM, ASM,
  DSM, DSA, LOGISTICS_MANAGER, CLIENT_SERVICE_MANAGER, TENANT_ADMIN, and
  Monvelo agent members.
- **`daylight`:** high contrast for outdoor field work. The default for
  ZSA, ASA, TM, RETAIL_SHOP_OWNER and POS_AGENT.
- **`dark`:** for analytical views (dashboards, ledgers, reconciliation),
  by the user's choice.

| Semantic token | `standard` | `daylight` | `dark` |
|---|---|---|---|
| `canvas` | canvas | white | ink |
| `surface` | white | white | botanical |
| `scrim` | scrim | scrim | scrim |
| `ink` | ink | ink | canvas |
| `ink-muted` | slate | ink | mist |
| `hairline` | mist | slate | mist |
| `control` (input borders, checkboxes) | slate | ink | mist |
| `focus` | botanical (2 px ring) | ink (3 px ring) | leaf (2 px ring) |
| `action` (fill) / `on-action` | leaf / ink | botanical / white | leaf / ink |
| `action-strong` / `on-action-strong` | botanical / white | ink / white | canvas / ink |
| `skeleton` / `skeleton-highlight` | mist / canvas | mist / white | ink / botanical |

**Tones.** `SemanticTone` is `neutral | brand | success | warning | danger |
info | pending`. Each tone has a mark colour (icon, border, indicator), a
text colour, and a subtle background:

| Tone | Mark (light / dark) | Text (light / dark) | Subtle background (light / dark) |
|---|---|---|---|
| `neutral` | slate / mist | ink / mist | canvas / ink |
| `brand` | leaf | botanical / canvas | canvas / ink |
| `success` | leaf | botanical / canvas | canvas / ink |
| `warning` | amber | ink / canvas | white / ink |
| `danger` | red / red-soft | red / red-soft | red-tint / ink |
| `info` | blue / sky | blue / sky | blue-tint / ink |
| `pending` | slate / mist | ink / canvas | canvas / ink |

Success and brand text is botanical, not leaf (leaf is 3.26:1 on white), and
warning text is ink, not amber (3.19:1). The colour of those tones is
carried by the mark.

**Three corrections from measurement (B1, 2026-11-28),** made here and in
`src/shared/tokens/` together:

- **Neutral text is ink on light themes, not ink-muted.** Slate on its
  canvas subtle background is 4.40:1, below 4.5:1 for badge-sized text.
- **The warning subtle background is white on light themes, not canvas.**
  The amber mark on canvas is 2.94:1, below the 3:1 rule for marks.
- **Neutral and pending marks are mist on dark, not slate.** Slate on
  botanical is 2.76:1.

Tone marks sit on a surface or on their own subtle background, never on the
bare canvas. `contrast.test.ts` checks every pair.

**Status is never colour alone.** Every `Badge` and `Banner` takes a tone,
a label in words and an icon. The props are required, and there is no
colour-only variant. Each tone has a fixed icon:

| Tone | Icon |
|---|---|
| `neutral` | dot |
| `brand` | leaf |
| `success` | check |
| `warning` | triangle with an exclamation mark |
| `danger` | octagon with an exclamation mark |
| `info` | "i" in a circle |
| `pending` | clock |

The daylight theme draws every tone mark at full strength and gives badges a
1.5 px border.

## 4. Brand gradients (brand moments only)

Gradients appear only on the sign-in screen, the splash and empty states.
They never appear in a list, a form, a queue, a ledger or a workflow (Spec B
§4.1).

**Emblem Gradient** (sign-in hero, splash)

```css
linear-gradient(135deg, #1B3624 0%, #629E28 100%)
```

Tailwind: `bg-gradient-to-br from-teafair-botanical to-teafair-leaf` (brand components only)

**Leaf Glow** (empty states)

```css
linear-gradient(180deg, rgba(98, 158, 40, 0.12) 0%, rgba(98, 158, 40, 0) 100%)
```

Tailwind: `bg-gradient-to-b from-teafair-leaf/10 to-transparent`

**Dark Brand Surface** (dark-theme splash)

```css
linear-gradient(145deg, #0F172A 0%, #1B3624 100%)
```

Tailwind: `bg-gradient-to-br from-teafair-ink to-teafair-botanical`

## 5. Tailwind / NativeWind configuration

The primitives are plain colours. The semantic tokens are CSS variables that
each theme sets, so switching theme swaps variables and no class changes.
The real file lives in `src/shared/tokens/` and is exported as the NativeWind
preset (Spec B §4.2); this is its shape.

```javascript
// src/shared/tokens/preset.js (shape)
module.exports = {
  theme: {
    extend: {
      colors: {
        teafair: {
          leaf: '#629E28',
          botanical: '#1B3624',
          amber: '#D97706',
          canvas: '#F4F6F9',
          white: '#FFFFFF',
          scrim: 'rgba(17, 24, 39, 0.35)', // #111827 at 35%
          ink: '#0F172A',
          slate: '#64748B',
          mist: '#E2E8F0',
          red: '#B91C1C',
          'red-soft': '#F87171',
          'red-tint': '#FEF2F2',
          blue: '#0369A1',
          sky: '#38BDF8',
          'blue-tint': '#F0F9FF',
        },
        // semantic: every component class uses these
        canvas: 'var(--canvas)',
        surface: 'var(--surface)',
        scrim: 'var(--scrim)',
        ink: { DEFAULT: 'var(--ink)', muted: 'var(--ink-muted)' },
        hairline: 'var(--hairline)',
        control: 'var(--control)',
        focus: 'var(--focus)',
        action: { DEFAULT: 'var(--action)', on: 'var(--on-action)',
                  strong: 'var(--action-strong)', 'on-strong': 'var(--on-action-strong)' },
        skeleton: { DEFAULT: 'var(--skeleton)', highlight: 'var(--skeleton-highlight)' },
        // per tone (neutral, brand, success, warning, danger, info, pending):
        // bg-tone-<tone> / border-tone-<tone> is the mark, bg-tone-<tone>-subtle the background
        'tone-danger': 'var(--tone-danger-mark)',
        'tone-danger-subtle': 'var(--tone-danger-subtle)',
        // …
      },
      // text-tone-<tone> is the tone's text colour, not its mark
      textColor: { 'tone-danger': 'var(--tone-danger-text)' /* … */ },
    },
  },
};
```
