# Awards mobile design workflow

Every React Native screen in the Teafair app goes through these three phases.
The architecture rules are in the root `CLAUDE.md` ("Frontend standards");
the brand tokens are in `FIGMA.md`.

## 0. References first

Before designing, read `.claude/references/<feature>/` (named after the
`src/features/` folder: `auth/`, `dashboard/`, `rtm/`, `monvelo/`, …) and any
relevant captures in `.design-refs/captured/`. Say which references were used,
or that none exist for this feature. References guide layout and feel; they
are never copied pixel for pixel, and a third party's branding is never used.

## 1. Creative direction

Propose three distinct concepts for the screen, for example:

- **Editorial minimalist:** type-led hierarchy, generous whitespace, one
  emerald accent.
- **Immersive dark:** the `teafair-black` → `teafair-darkSurfaceEnd` surface,
  lime highlights for state.
- **Kinetic:** motion-led (Reanimated), progress and state carried by
  transitions.

All three use only the `teafair-*` tokens. Each gets a sentence or two and a
rough phone and tablet layout. Pick one and say why it fits the user (a shop
owner, POS agent or field rep on a mid-range Android phone in bright light on
a weak network). The user can override the pick.

## 2. Implementation

- React Native primitives (`View`, `Text`, `ScrollView`, `Pressable`,
  `FlatList`) styled with NativeWind; shared atoms come from
  `src/shared/components/`.
- Phone portrait first, then `md:`/`lg:` layouts for tablets and foldables
  (multi-column in landscape). Safe areas via `react-native-safe-area-context`.
- Tokens only: no hex values, no stock palette classes.
- Field conditions: touch targets ≥ 48 dp, contrast ≥ 4.5:1, readable at
  large font scales, and loading, empty, offline-queued and error states.
- No generic templates: no grids of identical cards, no placeholder hero
  sections, no decorative gradients without a purpose.

## 3. The 8/10 critique loop

Score the screen out of 10 on each of these:

1. Typography and hierarchy, on phones and on tablets
2. Whitespace, padding and safe-area compliance
3. Visual impact and originality
4. React Native performance and code structure (list virtualisation, memoised
   rows, no inline closures in hot lists, feature isolation)

Score from evidence: render the screen at a phone size (~390 px) and a tablet
size (~1024 px landscape) and look at the result, not just the code. If any
score is below 8, name the flaws, fix them, and score again. Present the
screen only when every score is at least 8, with the scores and the remaining
weaknesses stated plainly.
