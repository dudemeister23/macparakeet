import React from 'react';
import { useCurrentFrame, useVideoConfig } from 'remotion';
import { ParakeetMark } from './ParakeetMark';
import { palette } from '../theme/tokens';

/**
 * The 12 contrast-validated Warhol pairs from
 * `brand-assets/palette/palette.json` § "tile-pairs". Each pair has been
 * eyeballed for ≥3:1 luminance contrast between ground and figure, so
 * any row composed from this list reads at any size.
 */
const TILE_PAIRS: ReadonlyArray<{ ground: string; figure: string }> = [
  { ground: palette.coral, figure: palette.ink },
  { ground: palette.aqua, figure: palette.ink },
  { ground: palette.marigold, figure: palette.ink },
  { ground: palette.magenta, figure: palette.paper },
  { ground: palette.cobalt, figure: palette.paper },
  { ground: palette.forest, figure: palette.lemon },
  { ground: palette.lemon, figure: palette.ink },
  { ground: palette.lavender, figure: palette.ink },
  { ground: palette.brick, figure: palette.paper },
  { ground: palette.ink, figure: palette.marigold },
  { ground: palette.lime, figure: palette.cobalt },
  { ground: palette.paper, figure: palette.ink },
];

interface PopGridProps {
  /** Number of visible rows; alternating row 0 →, row 1 ←, etc. */
  rows?: number;
  /** Tiles visible in a single row at any moment. */
  tilesPerRowVisible?: number;
  /** Marquee speed in pixels/second. ~120 reads as "deliberate but alive". */
  pixelsPerSecond?: number;
  /**
   * Starting pair index per row. Picking offsets that are coprime to 12
   * keeps adjacent rows' colors from echoing each other.
   */
  rowSeeds?: ReadonlyArray<number>;
}

/**
 * Andy Warhol meets a kinetic typography poster.
 *
 * Renders a full-bleed grid of parakeets in the brand's Pop palette,
 * with each row scrolling in the opposite direction from its neighbours.
 * The motion creates a weaving / op-art effect that's instantly
 * recognizable and unmistakably MacParakeet — no other voice app on Mac
 * has a parakeet to grid, let alone a Pop palette to grid in.
 *
 * The strip in each row contains 2× the visible-tile count, with the
 * second half copied from the first, so the marquee loops seamlessly
 * with no visible "snap" when the strip wraps.
 */
export const PopGrid: React.FC<PopGridProps> = ({
  rows = 4,
  tilesPerRowVisible = 6,
  pixelsPerSecond = 120,
  rowSeeds = [0, 5, 2, 7],
}) => {
  const frame = useCurrentFrame();
  const { fps, width: canvasWidth, height: canvasHeight } = useVideoConfig();

  const tileWidth = canvasWidth / tilesPerRowVisible;
  const tileHeight = canvasHeight / rows;
  const cycleWidth = tileWidth * tilesPerRowVisible;
  const tilesPerStrip = tilesPerRowVisible * 2; // first half == second half

  return (
    <div
      style={{
        position: 'absolute',
        inset: 0,
        display: 'flex',
        flexDirection: 'column',
        overflow: 'hidden',
      }}
    >
      {Array.from({ length: rows }).map((_, rowIdx) => {
        const direction = rowIdx % 2 === 0 ? 1 : -1;
        const t = (frame / fps) * pixelsPerSecond; // monotonic, positive
        const offset = t % cycleWidth;
        // direction = +1 → tiles appear to slide right (translateX from -cycle → 0)
        // direction = -1 → tiles appear to slide left  (translateX from 0 → -cycle)
        const tx = direction === 1 ? -cycleWidth + offset : -offset;
        const seed = rowSeeds[rowIdx % rowSeeds.length];

        return (
          <div
            key={rowIdx}
            style={{
              height: tileHeight,
              position: 'relative',
              overflow: 'hidden',
            }}
          >
            <div
              style={{
                position: 'absolute',
                top: 0,
                left: 0,
                height: '100%',
                display: 'flex',
                transform: `translateX(${tx}px)`,
                willChange: 'transform',
              }}
            >
              {Array.from({ length: tilesPerStrip }).map((_, tileIdx) => {
                // Repeat first half in second half for seamless loop.
                const idxInCycle = tileIdx % tilesPerRowVisible;
                const pair = TILE_PAIRS[(seed + idxInCycle) % TILE_PAIRS.length];
                return (
                  <Tile
                    key={tileIdx}
                    width={tileWidth}
                    height={tileHeight}
                    ground={pair.ground}
                    figure={pair.figure}
                  />
                );
              })}
            </div>
          </div>
        );
      })}
    </div>
  );
};

interface TileProps {
  width: number;
  height: number;
  ground: string;
  figure: string;
}

const Tile: React.FC<TileProps> = ({ width, height, ground, figure }) => {
  const markSize = Math.min(width, height) * 0.62;
  return (
    <div
      style={{
        width,
        height,
        flexShrink: 0,
        backgroundColor: ground,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
      }}
    >
      <ParakeetMark size={markSize} color={figure} />
    </div>
  );
};
