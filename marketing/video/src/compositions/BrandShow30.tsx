import React from 'react';
import {
  AbsoluteFill,
  interpolate,
  Sequence,
  spring,
  useCurrentFrame,
  useVideoConfig,
} from 'remotion';
import { OfficialLogo } from '../components/OfficialLogo';
import { ParakeetMark } from '../components/ParakeetMark';
import { PopGrid } from '../components/PopGrid';
import { motion, palette } from '../theme/tokens';

/**
 * Pop Brand Film — 30s.
 *
 * Pure visual identity, no explainer copy. For launch moments, social
 * campaigns, anniversary loops. The "Warhol moment" the Pop palette
 * exists for (see brand-assets/palette/palette.json § brand-fidelity).
 *
 * Beat structure:
 *   0:00 – 0:02   Quiet intro:  single coral parakeet on paper-cream
 *   0:02 – 0:20   POP GRID:     4 rows × 6 visible tiles, alternating
 *                               row directions, brand-validated pairs
 *   0:20 – 0:23   Fade to ink:  the grid dissolves to near-black
 *   0:23 – 0:30   Official logo: white parakeet on ink + URL in coral
 *
 * Counterpart to Demo60: Demo60 explains what MacParakeet does, this
 * shows what MacParakeet *is*. Ship both; they serve different goals.
 */
export const BrandShow30: React.FC = () => {
  const { fps } = useVideoConfig();

  const INTRO_END = fps * 2;
  const GRID_START = fps * 2;
  const GRID_END = fps * 20;
  const FADE_START = fps * 20;
  const FADE_END = fps * 23;
  const LOGO_START = fps * 23;
  const TOTAL = fps * 30;

  return (
    <AbsoluteFill style={{ backgroundColor: palette.paper }}>
      <Sequence from={0} durationInFrames={INTRO_END} name="Intro">
        <QuietIntro />
      </Sequence>

      <Sequence
        from={GRID_START}
        durationInFrames={GRID_END - GRID_START}
        name="Pop Grid"
      >
        <PopGridSection />
      </Sequence>

      <Sequence
        from={FADE_START}
        durationInFrames={FADE_END - FADE_START}
        name="Fade to ink"
      >
        <FadeToInk />
      </Sequence>

      <Sequence
        from={LOGO_START}
        durationInFrames={TOTAL - LOGO_START}
        name="Official logo"
      >
        <OfficialLogo />
      </Sequence>
    </AbsoluteFill>
  );
};

/** Centered coral mark on paper, gentle scale-in. */
const QuietIntro: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const progress = spring({
    frame: frame - 6,
    fps,
    config: motion.springSoft,
    durationInFrames: 40,
  });
  const opacity = interpolate(frame, [0, 24], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });
  const scale = interpolate(progress, [0, 1], [0.92, 1]);
  const breath = Math.sin((frame / fps) * 2 * Math.PI * 0.5) * 0.015 + 1;

  return (
    <AbsoluteFill
      style={{
        backgroundColor: palette.paper,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
      }}
    >
      <div
        style={{
          opacity,
          transform: `scale(${scale * breath})`,
          willChange: 'transform, opacity',
        }}
      >
        <ParakeetMark size={200} color={palette.coral} />
      </div>
    </AbsoluteFill>
  );
};

/**
 * The grid section.
 *
 * Rows fade up in a quick stagger so the entrance feels rhythmic, then
 * runs at constant marquee speed for the rest of the section.
 */
const PopGridSection: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  // Stagger rows fading in over the first ~1.2 seconds.
  const introOpacity = interpolate(frame, [0, 24], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

  return (
    <AbsoluteFill style={{ backgroundColor: palette.paper, opacity: introOpacity }}>
      <PopGrid rows={4} tilesPerRowVisible={6} pixelsPerSecond={140} />
    </AbsoluteFill>
  );
};

/** Ink curtain that fades up over the grid, taking it to the next beat. */
const FadeToInk: React.FC = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const total = fps * 3;
  const opacity = interpolate(frame, [0, total], [0, 1], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  });

  return (
    <AbsoluteFill style={{ backgroundColor: palette.ink, opacity }} />
  );
};
