import React from 'react';
import { Composition } from 'remotion';
import { BrandShow30 } from './compositions/BrandShow30';
import { Demo60 } from './compositions/Demo60';
import { HeroLoop30 } from './compositions/HeroLoop30';
import { Hook } from './compositions/Hook';

const FPS = 60;

export const Root: React.FC = () => {
  return (
    <>
      {/* 5s validation spike — pure programmatic, no screencasts required. */}
      <Composition
        id="Hook"
        component={Hook}
        durationInFrames={FPS * 5}
        fps={FPS}
        width={1920}
        height={1080}
      />

      {/* 30s Pop brand film — Warhol parakeet grid + black/white logo finale. */}
      <Composition
        id="BrandShow30"
        component={BrandShow30}
        durationInFrames={FPS * 30}
        fps={FPS}
        width={1920}
        height={1080}
      />

      {/* 30s autoplay-muted hero for macparakeet.com — silent, captions carry. */}
      <Composition
        id="HeroLoop30"
        component={HeroLoop30}
        durationInFrames={FPS * 30}
        fps={FPS}
        width={1920}
        height={1080}
      />

      {/* 60s master demo with VO — full product walkthrough. */}
      <Composition
        id="Demo60"
        component={Demo60}
        durationInFrames={FPS * 60}
        fps={FPS}
        width={1920}
        height={1080}
      />
    </>
  );
};
