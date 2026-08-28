import React from 'react';
import {Composition} from 'remotion';
import {BrowserFilm} from './BrowserFilm';

export const RemotionRoot: React.FC = () => (
  <Composition
    id="BrowserLaunchFilm"
    component={BrowserFilm}
    durationInFrames={900}
    fps={30}
    width={1920}
    height={1080}
  />
);
